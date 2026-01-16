import Foundation

/// Utility to manage an installation marker file that helps detect orphaned keychain entries.
///
/// The marker is placed in the app sandbox Documents directory (NOT the app group container)
/// because this directory is deleted when the app is uninstalled, while the keychain persists.
///
/// By checking if the marker exists at app startup, we can detect if:
/// - The marker exists: App was installed before, keychain is valid
/// - The marker doesn't exist but keychain has data: Orphaned keychain from previous install
///
/// This helps prevent security issues where a reinstalled app might find old keychain data
/// without corresponding wallet data (LDK, CoreDB, UserDefaults).
enum InstallationMarker {
    private static let markerFileName = ".bitkit_installed"

    /// App sandbox Documents directory (NOT app group) - gets deleted on uninstall
    private static var sandboxDocumentsUrl: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var markerPath: URL {
        sandboxDocumentsUrl.appendingPathComponent(markerFileName)
    }

    /// Check if the installation marker exists
    static func exists() -> Bool {
        FileManager.default.fileExists(atPath: markerPath.path)
    }

    /// Create the installation marker file
    /// Should be called after handling any orphaned keychain detection
    static func create() throws {
        let data = UUID().uuidString.data(using: .utf8)!
        try data.write(to: markerPath)
        Logger.info("Installation marker created", context: "InstallationMarker")
    }

    /// Delete the installation marker file
    /// Should be called during app reset/wipe to ensure clean state on next install
    static func delete() throws {
        if exists() {
            try FileManager.default.removeItem(at: markerPath)
            Logger.info("Installation marker deleted", context: "InstallationMarker")
        }
    }
}
