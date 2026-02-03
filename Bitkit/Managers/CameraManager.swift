import AVFoundation
import SwiftUI

final class CameraManager: ObservableObject {
    static let shared = CameraManager()
    @Published var hasPermission: Bool = false

    init() {
        refreshPermission()
    }

    func refreshPermission() {
        let granted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        DispatchQueue.main.async {
            self.hasPermission = granted
        }
    }

    /// Call when the scanner appears; shows the system permission dialog only when status is .notDetermined (fresh install).
    func requestPermissionIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                self.hasPermission = granted
            }
        }
    }

    func requestPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .notDetermined:
            requestPermissionIfNeeded()
        case .denied, .restricted:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                DispatchQueue.main.async {
                    UIApplication.shared.open(url)
                }
            }
        case .authorized:
            DispatchQueue.main.async {
                self.hasPermission = true
            }
        @unknown default:
            break
        }
    }
}
