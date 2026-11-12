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

// MARK: - Scanner Sources

/// Which nearby sources a payment scanner is listening to, for its status pill.
struct ScannerSources: Equatable {
    var nfc: Bool
    var bluetooth: Bool

    var statusKey: String {
        switch (nfc, bluetooth) {
        case (true, true): "other__scan_status_qr_nfc_bluetooth"
        case (true, false): "other__scan_status_qr_nfc"
        case (false, true): "other__scan_status_qr_bluetooth"
        case (false, false): "other__scan_status_qr"
        }
    }
}

// MARK: - Scanner Status Overlay Component

/// Status pill at the bottom of the camera preview, with buttons for sources that still need the user.
///
/// iOS cannot detect NFC tags passively, so the NFC button (or the pill, when no buttons are shown) starts
/// an NFC read through the system sheet. The Bluetooth button asks for Bluetooth permission.
private struct ScannerStatusOverlay: View {
    let isNfcAvailable: Bool
    let showsBluetoothButton: Bool
    let isBluetoothScanning: Bool
    let onNfcRead: (() async -> Void)?
    let onBluetooth: () -> Void

    private var showsButtons: Bool {
        showsBluetoothButton
    }

    private var sources: ScannerSources {
        ScannerSources(nfc: isNfcAvailable && !showsButtons, bluetooth: isBluetoothScanning)
    }

    var body: some View {
        VStack(spacing: 8) {
            if showsButtons {
                HStack(spacing: 8) {
                    ScannerSourceButton(icon: "bluetooth-connected", testID: "ScannerBluetoothButton") {
                        onBluetooth()
                    }
                    if isNfcAvailable, let onNfcRead {
                        ScannerSourceButton(icon: "broadcast", testID: "ScannerNfcButton") {
                            Task { await onNfcRead() }
                        }
                    }
                }
            }

            Button {
                guard sources.nfc, let onNfcRead else { return }
                Task { await onNfcRead() }
            } label: {
                HStack(spacing: 8) {
                    Image(sources.nfc || sources.bluetooth ? "broadcast" : "scan")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .foregroundColor(.white64)
                    CaptionMText(t(sources.statusKey), textColor: .white64)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black50)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ScannerStatus")
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

private struct ScannerSourceButton: View {
    let icon: String
    let testID: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .foregroundColor(.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(Color.gray5)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(testID)
    }
}

// MARK: - Scanner Component

struct Scanner: View {
    var accentColor: Color = .brandAccent
    var permissionDescription: String = t("other__camera_no_text")
    @Environment(CameraManager.self) private var cameraManager
    @Environment(\.scenePhase) private var scenePhase

    let onScan: (QRCodePayload) async -> Void
    let onImageSelection: (PhotosPickerItem?) async -> Void
    /// Starts an NFC read; nil hides the NFC control (non-payment scanners, devices without NFC).
    var onNfcRead: (() async -> Void)?
    /// Receives a request read over Bluetooth from a nearby phone and returns whether it was taken; nil turns
    /// Bluetooth scanning off.
    var onNearbyRequest: ((String) async -> Bool)?
    /// Pauses Bluetooth scanning while something covers the scanner (for example the payment sheet it opened).
    var isNearbyPaused = false

    @State private var isTorchOn = false
    @State private var nearby = NearbyPaymentScanner()

    private var isPaymentScanner: Bool {
        onNfcRead != nil || onNearbyRequest != nil
    }

    private var needsBluetoothPermission: Bool {
        onNearbyRequest != nil && !nearby.isAuthorized
    }

    private var bluetoothPermissionAction: (() -> Void)? {
        guard needsBluetoothPermission else { return nil }
        let nearby = nearby
        return { nearby.requestAuthorization() }
    }

    var body: some View {
        ZStack {
            if cameraManager.hasPermission {
                #if targetEnvironment(simulator)
                    Color.black.allowsHitTesting(false)
                #else
                    ScannerCamera(
                        isTorchOn: isTorchOn,
                        onScan: { payload in
                            await onScan(payload)
                        }
                    )
                    .allowsHitTesting(false)
                #endif

                ScannerCornerButtons(
                    isTorchOn: $isTorchOn,
                    onImageSelection: { item in
                        await onImageSelection(item)
                    }
                )

                if isPaymentScanner {
                    ScannerStatusOverlay(
                        isNfcAvailable: onNfcRead != nil,
                        showsBluetoothButton: needsBluetoothPermission,
                        isBluetoothScanning: nearby.isScanning,
                        onNfcRead: onNfcRead,
                        onBluetooth: { nearby.requestAuthorization() }
                    )
                }
            } else if isPaymentScanner {
                ScannerPermissionRequest(
                    accentColor: accentColor,
                    title: t("other__scan_to_pay_title"),
                    description: t("other__scan_to_pay_text"),
                    onRequestPermission: cameraManager.requestPermission,
                    onBluetooth: bluetoothPermissionAction,
                    onNfcRead: onNfcRead
                )
            } else {
                ScannerPermissionRequest(
                    accentColor: accentColor,
                    description: permissionDescription,
                    onRequestPermission: cameraManager.requestPermission
                )
            }
        }
        .cornerRadius(16)
        .contentShape(Rectangle())
        .onAppear {
            startNearbyScanning()
            guard !cameraManager.hasPermission else { return }
            cameraManager.requestPermissionIfNeeded()
        }
        .onDisappear {
            nearby.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                startNearbyScanning()
            } else {
                nearby.stop()
            }
        }
        .onChange(of: isNearbyPaused) { _, isPaused in
            if isPaused {
                nearby.stop()
            } else {
                startNearbyScanning()
            }
        }
    }

    private func startNearbyScanning() {
        guard let onNearbyRequest, !isNearbyPaused, scenePhase == .active else { return }
        nearby.start(onRequest: onNearbyRequest)
    }
}

struct ScannerPermissionRequest: View {
    var accentColor: Color = .brandAccent
    var title: String = t("other__camera_no_title")
    var description: String = t("other__camera_no_text")
    let onRequestPermission: () -> Void
    /// Payment scanners also offer Bluetooth and NFC, which work without the camera.
    var onBluetooth: (() -> Void)?
    var onNfcRead: (() async -> Void)?

    private var showsSourceButtons: Bool {
        onBluetooth != nil || onNfcRead != nil
    }

    var body: some View {
        VStack(alignment: showsSourceButtons ? .leading : .center, spacing: 0) {
            DisplayText(title, accentColor: accentColor)
                .padding(.bottom, 8)
            BodyMText(description)
                .padding(.bottom, 32)
            if showsSourceButtons {
                HStack(spacing: 8) {
                    ScannerSourceButton(icon: "camera", testID: "ScannerCameraButton", action: onRequestPermission)
                    if let onBluetooth {
                        ScannerSourceButton(icon: "bluetooth-connected", testID: "ScannerBluetoothButton", action: onBluetooth)
                    }
                    if let onNfcRead {
                        ScannerSourceButton(icon: "broadcast", testID: "ScannerNfcButton") {
                            Task { await onNfcRead() }
                        }
                    }
                }
            } else {
                CustomButton(
                    title: t("other__camera_no_button"),
                    icon: Image("camera").foregroundColor(.textPrimary)
                ) {
                    onRequestPermission()
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
