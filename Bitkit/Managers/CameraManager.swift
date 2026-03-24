import AVFoundation
import SwiftUI

@MainActor
@Observable
final class CameraManager {
    static let shared = CameraManager()

    var hasPermission: Bool = false

    init() {
        refreshPermission()
    }

    func refreshPermission() {
        hasPermission = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Call when the scanner appears; shows the system permission dialog only when status is `.notDetermined` (fresh install).
    func requestPermissionIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
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
                UIApplication.shared.open(url)
            }
        case .authorized:
            hasPermission = true
        @unknown default:
            break
        }
    }
}
