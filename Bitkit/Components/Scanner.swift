import AVFoundation
import PhotosUI
import SwiftUI
import Vision

// MARK: - Scanner Camera Component

private struct ScannerCamera: UIViewControllerRepresentable {
    let isTorchOn: Bool
    let onScan: (QRCodePayload) async -> Void

    func makeUIViewController(context _: Context) -> QRCodeScannerViewController {
        QRCodeScannerViewController { payload in
            Task {
                await onScan(payload)
            }
        }
    }

    func updateUIViewController(_ controller: QRCodeScannerViewController, context _: Context) {
        controller.setTorch(isOn: isTorchOn)
    }
}

private final class QRCodeScannerViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "to.bitkit.qr-scanner.session")
    private let videoQueue = DispatchQueue(label: "to.bitkit.qr-scanner.video")
    private let onScan: (QRCodePayload) -> Void
    private var captureDevice: AVCaptureDevice?
    private var isTorchRequested = false
    private var framesWithoutQRCode = 0
    private var isProcessingFrame = false
    private var lastPayloadData: Data?
    private var lastPayloadString: String?
    private lazy var previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)

    init(onScan: @escaping (QRCodePayload) -> Void) {
        self.onScan = onScan
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        configureCaptureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [weak self] in
            guard let self, !captureSession.isRunning else { return }
            captureSession.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self, captureSession.isRunning else { return }
            captureSession.stopRunning()
        }
    }

    func setTorch(isOn: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            isTorchRequested = isOn
            applyTorchState()
        }
    }

    private func applyTorchState() {
        guard let captureDevice, captureDevice.hasTorch else { return }

        do {
            try captureDevice.lockForConfiguration()
            captureDevice.torchMode = isTorchRequested ? .on : .off
            captureDevice.unlockForConfiguration()
        } catch {
            Logger.error(error, context: "QR scanner torch")
        }
    }

    private func configureCaptureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            captureSession.beginConfiguration()
            defer { captureSession.commitConfiguration() }
            captureSession.sessionPreset = .high

            guard let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ) else {
                Logger.error("Failed to find QR scanner camera")
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard captureSession.canAddInput(input) else {
                    Logger.error("Failed to add QR scanner camera input")
                    return
                }
                captureSession.addInput(input)
                captureDevice = device
                applyTorchState()
            } catch {
                Logger.error(error, context: "QR scanner camera input")
                return
            }

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            guard captureSession.canAddOutput(output) else {
                Logger.error("Failed to add QR scanner video output")
                return
            }
            captureSession.addOutput(output)
        }
    }

    func captureOutput(
        _: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from _: AVCaptureConnection
    ) {
        guard !isProcessingFrame else { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        do {
            let handler = VNImageRequestHandler(
                cmSampleBuffer: sampleBuffer,
                orientation: .right,
                options: [:]
            )
            try handler.perform([request])
        } catch {
            Logger.error(error, context: "QR scanner frame detection")
            return
        }

        guard let observation = request.results?.first else {
            framesWithoutQRCode += 1
            if framesWithoutQRCode >= 10 {
                lastPayloadData = nil
                lastPayloadString = nil
            }
            return
        }

        framesWithoutQRCode = 0
        let payload = QRCodePayload(
            string: observation.payloadStringValue,
            data: observation.payloadData
        )
        guard payload.data != lastPayloadData || payload.string != lastPayloadString else { return }

        lastPayloadData = payload.data
        lastPayloadString = payload.string
        DispatchQueue.main.async { [onScan] in
            onScan(payload)
        }
    }
}

// MARK: - Scanner Corner Buttons Component

private struct ScannerCornerButtons: View {
    @Binding var isTorchOn: Bool
    let onImageSelection: (PhotosPickerItem?) async -> Void

    @State private var selectedItem: PhotosPickerItem?

    var body: some View {
        GeometryReader { _ in
            HStack {
                PhotosPicker(selection: $selectedItem, matching: .images) {
                    Image("picture")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white16)
                        .clipShape(Circle())
                }
                .onChange(of: selectedItem) { _, item in
                    Task { await onImageSelection(item) }
                }

                Spacer()

                IconButton(icon: Image("flashlight"), size: 40) {
                    isTorchOn.toggle()
                }
                .background(isTorchOn ? Color.white32 : Color.clear)
                .clipShape(Circle())
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Scanner Component

struct Scanner: View {
    @Environment(CameraManager.self) private var cameraManager

    let onScan: (QRCodePayload) async -> Void
    let onImageSelection: (PhotosPickerItem?) async -> Void

    @State private var isTorchOn = false

    var body: some View {
        ZStack {
            if cameraManager.hasPermission {
                #if targetEnvironment(simulator)
                    Color.black
                #else
                    ScannerCamera(
                        isTorchOn: isTorchOn,
                        onScan: { payload in
                            await onScan(payload)
                        }
                    )
                #endif

                ScannerCornerButtons(
                    isTorchOn: $isTorchOn,
                    onImageSelection: { item in
                        await onImageSelection(item)
                    }
                )
            } else {
                ScannerPermissionRequest(onRequestPermission: cameraManager.requestPermission)
            }
        }
        .cornerRadius(16)
        .onAppear {
            guard !cameraManager.hasPermission else { return }
            cameraManager.requestPermissionIfNeeded()
        }
    }
}

struct ScannerPermissionRequest: View {
    let onRequestPermission: () -> Void

    var body: some View {
        Color.black
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                VStack(spacing: 0) {
                    DisplayText(t("other__camera_no_title"), accentColor: .brandAccent)
                        .padding(.bottom, 8)
                    BodyMText(t("other__camera_no_text"))
                        .padding(.bottom, 32)
                    CustomButton(
                        title: t("other__camera_no_button"),
                        icon: Image("camera").foregroundColor(.textPrimary)
                    ) {
                        onRequestPermission()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
            }
    }
}
