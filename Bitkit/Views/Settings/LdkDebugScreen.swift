import SwiftUI
import UIKit
import VssRustClientFfi

struct LdkDebugScreen: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var nodeUri: String = ""
    @State private var showDeleteConfirmation = false
    @State private var isRestartingNode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "LDK Debug")
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    // Add Peer
                    VStack(alignment: .leading, spacing: 8) {
                        CaptionMText("Add Peer")

                        TextField("039b8d4d...a8f3eae3@127.0.0.1:9735", text: $nodeUri)

                        HStack(spacing: 8) {
                            CustomButton(title: "Add Peer", size: .small) {
                                Task {
                                    try await addPeer()
                                }
                            }
                            CustomButton(title: "Paste & Add", size: .small) {
                                Task {
                                    try await pasteAndAddPeer()
                                }
                            }
                        }
                    }

                    // Network Graph Storage
                    VStack(alignment: .leading, spacing: 8) {
                        CaptionMText("Network Graph Storage")

                        HStack(spacing: 8) {
                            CustomButton(title: "Log Graph Info", size: .small) {
                                Task {
                                    // await logAllNodesToFile()
                                    await logNetworkGraphInfo()
                                }
                            }

                            CustomButton(title: "Delete Graph Data", size: .small, isDisabled: true) {
                                Task {
                                    await deleteNetworkGraphFromVss()
                                }
                            }
                        }
                    }

                    // VSS
                    VStack(alignment: .leading, spacing: 8) {
                        CaptionMText("VSS")

                        HStack(spacing: 8) {
                            CustomButton(title: "List Keys", size: .small) {
                                Task {
                                    await listVssKeys()
                                }
                            }

                            CustomButton(title: "Delete All", size: .small) {
                                Task {
                                    await deleteAllVssKeys()
                                }
                            }
                        }
                    }

                    // Node
                    VStack(alignment: .leading, spacing: 8) {
                        CaptionMText("Node")

                        HStack(spacing: 8) {
                            CustomButton(title: "Restart", size: .small, isLoading: isRestartingNode) {
                                Task {
                                    await restartNode()
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }

    func addPeer() async throws {
        do {
            let lnPeer = try LnPeer(connection: nodeUri)
            try await wallet.connectPeer(lnPeer)
            app.toast(type: .success, title: "Peer added", description: "Peer added successfully")
        } catch {
            Logger.error(error, context: "LdkDebugScreen")
            app.toast(type: .error, title: "Error", description: "Failed to add peer: \(error.localizedDescription)")
        }
    }

    func pasteAndAddPeer() async throws {
        guard let pastedText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            app.toast(type: .error, title: "Error", description: "Failed to paste text")
            return
        }
        nodeUri = pastedText
        try await addPeer()
    }

    func deleteNetworkGraphFromVss() async {
        do {
            Logger.info("Deleting network graph data from VSS...")
            app.toast(type: .info, title: "Deleting...", description: "Removing network graph data from VSS store")

            let lightningService = LightningService.shared

            // Stop the node first to ensure VSS isn't being accessed
            try await lightningService.stop()

            // Setup VSS client
            let vssClient = VssBackupClient.shared
            let walletIndex = lightningService.currentWalletIndex
            try await vssClient.setup(walletIndex: walletIndex)

            // LDK Node stores network graph data in VSS using namespaces.
            // The network graph persistence uses:
            // - NETWORK_GRAPH_PERSISTENCE_PRIMARY_NAMESPACE
            // - NETWORK_GRAPH_PERSISTENCE_SECONDARY_NAMESPACE
            // - NETWORK_GRAPH_PERSISTENCE_KEY
            // VSS keys are stored as: "{primary_namespace}/{secondary_namespace}/{key}"

            // First, list all keys to see what's actually stored
            Logger.info("Listing all keys in VSS store to find network graph keys...")

            let allKeys = try await vssClient.listKeys(prefix: nil)
            Logger.info("Total keys in VSS store: \(allKeys.count)")

            // Log all keys for debugging
            print("\n📋 All VSS Keys:")
            if !allKeys.isEmpty {
                for keyVersion in allKeys {
                    print("  - \(keyVersion.key) (version: \(keyVersion.version))")
                    Logger.debug("VSS key: \(keyVersion.key) (version: \(keyVersion.version))")
                }
            } else {
                print("  (empty)")
            }

            // let deletedMetadata = try await vssClient.deleteObject(key: "METADATA")
            // Logger.info("Deleted metadata key: \(deletedMetadata)")

            // if deletedMetadata {
            //     Logger.info("Deleted network graph key")
            //     app.toast(type: .success, title: "Network Graph Deleted", description: "Deleted network graph key")
            // } else {
            //     Logger.warn("Failed to delete network graph key")
            //     app.toast(type: .error, title: "Error", description: "Failed to delete network graph key")
            // }
        } catch {
            Logger.error(error, context: "LdkDebugScreen - deleteNetworkGraphFromVss")
            app.toast(
                type: .error,
                title: "Error",
                description: "Failed to delete network graph from VSS: \(error.localizedDescription)"
            )
        }
    }

    // Legacy function - kept for reference
    func deleteNetworkGraphDatabase() async {
        do {
            let lightningService = LightningService.shared
            let walletIndex = lightningService.currentWalletIndex
            let ldkStoragePath = Env.ldkStorage(walletIndex: walletIndex)
            let sqlitePath = ldkStoragePath.appendingPathComponent("ldk_node_data.sqlite")

            let fileManager = FileManager.default

            // Check if directory exists
            var isDirectory: ObjCBool = false
            let directoryExists = fileManager.fileExists(atPath: ldkStoragePath.path, isDirectory: &isDirectory)

            Logger.debug("Checking storage directory: \(ldkStoragePath.path)")
            Logger.debug("Directory exists: \(directoryExists), isDirectory: \(isDirectory.boolValue)")

            // Check parent directories to see if they exist
            let parentPath = ldkStoragePath.deletingLastPathComponent()
            var parentIsDirectory: ObjCBool = false
            let parentExists = fileManager.fileExists(atPath: parentPath.path, isDirectory: &parentIsDirectory)
            Logger.debug("Parent directory exists: \(parentExists), path: \(parentPath.path)")

            if !directoryExists {
                // Try to create the directory if parent exists (LDK Node might create it lazily)
                if parentExists {
                    do {
                        try fileManager.createDirectory(at: ldkStoragePath, withIntermediateDirectories: true, attributes: nil)
                        Logger.info("Created storage directory: \(ldkStoragePath.path)")
                    } catch {
                        Logger.error(error, context: "Failed to create storage directory")
                    }
                } else {
                    Logger.warn("Parent directory also doesn't exist: \(parentPath.path)")
                }

                // Check if the file exists anyway (maybe LDK created it in a different location)
                // Even if directory doesn't exist, the file might exist
                if fileManager.fileExists(atPath: sqlitePath.path) {
                    Logger.info("Database file exists even though directory check failed, proceeding with deletion")
                    // Continue to deletion logic below
                } else {
                    // Search in parent directory for any SQLite files
                    if parentExists {
                        do {
                            let parentFiles = try fileManager.contentsOfDirectory(atPath: parentPath.path)
                            Logger.debug("All files in parent directory: \(parentFiles.joined(separator: ", "))")

                            let sqliteFiles = parentFiles.filter { $0.hasSuffix(".sqlite") }
                            if sqliteFiles.isEmpty {
                                Logger.debug("No SQLite files found in parent directory")
                            } else {
                                Logger.info("Found SQLite files in parent directory: \(sqliteFiles.joined(separator: ", "))")

                                // Check if any of these SQLite files might be the LDK database
                                for sqliteFile in sqliteFiles {
                                    let fullPath = parentPath.appendingPathComponent(sqliteFile)
                                    Logger.debug("Found SQLite file: \(fullPath.path)")
                                }
                            }
                        } catch {
                            Logger.error(error, context: "Could not list parent directory")
                        }
                    }

                    app.toast(
                        type: .info,
                        title: "No Database Found",
                        description: "The storage directory doesn't exist yet. LDK Node may create it when it first writes data. The database file will be created when the node syncs."
                    )
                    return
                }
            }

            // List all files in the directory for debugging
            do {
                let files = try fileManager.contentsOfDirectory(atPath: ldkStoragePath.path)
                Logger.debug("Files in storage directory: \(files.isEmpty ? "(empty)" : files.joined(separator: ", "))")

                if files.isEmpty {
                    Logger.info("Storage directory exists but is empty - database file hasn't been created yet")
                    Logger.info("LDK Node creates the database file lazily when it first writes data (e.g., network graph sync)")
                    app.toast(
                        type: .info,
                        title: "Directory Empty",
                        description: "The storage directory exists but is empty. The database file will be created when LDK Node first writes data (e.g., during network graph sync from RGS)."
                    )
                    return
                }
            } catch {
                Logger.error(error, context: "Failed to list directory contents")
            }

            if fileManager.fileExists(atPath: sqlitePath.path) {
                // Stop the node first to ensure the database isn't locked
                try await lightningService.stop()

                // Delete the database file
                try fileManager.removeItem(at: sqlitePath)

                Logger.info("Deleted network graph database at: \(sqlitePath.path)")
                app.toast(
                    type: .success,
                    title: "Database Deleted",
                    description: "Network graph database has been deleted. Restart the node to re-sync."
                )
            } else {
                // List files to help debug
                let files = (try? fileManager.contentsOfDirectory(atPath: ldkStoragePath.path)) ?? []
                let fileList = files.isEmpty ? "No files found" : files.joined(separator: ", ")

                Logger.warn("SQLite file not found. Expected: \(sqlitePath.path)")
                Logger.warn("Files in directory: \(fileList)")

                app.toast(
                    type: .warning,
                    title: "File Not Found",
                    description: "Database file not found at: \(sqlitePath.lastPathComponent)\nDirectory contains: \(fileList)"
                )
            }
        } catch {
            Logger.error(error, context: "LdkDebugScreen - deleteNetworkGraphDatabase")
            app.toast(
                type: .error,
                title: "Error",
                description: "Failed to delete network graph database: \(error.localizedDescription)"
            )
        }
    }

    func logAllNodesToFile() async {
        do {
            app.toast(type: .info, title: "Logging nodes...", description: "Writing all nodes to file")

            let lightningService = LightningService.shared
            let filePath = try await lightningService.logAllNodesToFile()

            Logger.info("Successfully logged all nodes to: \(filePath)")

            // Present share sheet so user can save to Files app or share
            await MainActor.run {
                let fileURL = URL(fileURLWithPath: filePath)
                let activityViewController = UIActivityViewController(
                    activityItems: [fileURL],
                    applicationActivities: nil
                )

                // For iPad support
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first,
                   let rootViewController = window.rootViewController
                {
                    if let popover = activityViewController.popoverPresentationController {
                        // This will be set by the presenting view controller
                        popover.sourceView = window
                        popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
                        popover.permittedArrowDirections = []
                    }

                    rootViewController.present(activityViewController, animated: true)
                }
            }
        } catch {
            Logger.error("Failed to log nodes to file: \(error)")
            app.toast(
                type: .error,
                title: "Error",
                description: "Failed to log nodes: \(error.localizedDescription)"
            )
        }
    }

    func listVssKeys() async {
        do {
            let vssClient = VssBackupClient.shared
            let keys = try await vssClient.listKeys()
            Logger.info("VSS keys: \(keys)")

            await deobfuscateAndListKeys(obfuscatedKeys: keys)

            app.toast(type: .info, title: "VSS Keys", description: "\(keys.count) keys: \(keys)")
        } catch {
            Logger.error("Failed to list VSS keys: \(error)")
            app.toast(type: .error, title: "Error", description: "Failed to list VSS keys: \(error.localizedDescription)")
        }
    }

    func deleteAllVssKeys() async {
        do {
            Logger.info("Deleting all VSS keys...")
            app.toast(type: .info, title: "Deleting...", description: "Removing all key-values from VSS store")

            let lightningService = LightningService.shared

            // Stop the node first to ensure VSS isn't being accessed
            try await lightningService.stop()

            // Setup VSS client
            let vssClient = VssBackupClient.shared
            let walletIndex = lightningService.currentWalletIndex
            try await vssClient.setup(walletIndex: walletIndex)

            // Get all keys
            let allKeys = try await vssClient.listKeys(prefix: nil)
            Logger.info("Found \(allKeys.count) keys to delete")

            if allKeys.isEmpty {
                app.toast(type: .info, title: "No Keys", description: "VSS store is already empty")
                return
            }

            // Delete each key
            var deletedCount = 0
            var failedCount = 0
            var failedKeys: [String] = []

            print("\n🗑️  Deleting all VSS keys...\n")

            for keyVersion in allKeys {
                do {
                    let wasDeleted = try await vssClient.deleteObject(key: keyVersion.key)
                    if wasDeleted {
                        deletedCount += 1
                        print("  ✅ Deleted: \(keyVersion.key) (v\(keyVersion.version))")
                        Logger.debug("Deleted VSS key: \(keyVersion.key)")
                    } else {
                        // Key didn't exist (shouldn't happen if we just listed it)
                        print("  ⚠️  Key not found: \(keyVersion.key)")
                    }
                } catch {
                    failedCount += 1
                    failedKeys.append(keyVersion.key)
                    print("  ❌ Failed to delete: \(keyVersion.key) - \(error)")
                    Logger.error("Failed to delete VSS key '\(keyVersion.key)': \(error)")
                }
            }

            // Summary
            print("\n📊 Deletion Summary:")
            print("   Total keys: \(allKeys.count)")
            print("   Deleted: \(deletedCount)")
            if failedCount > 0 {
                print("   Failed: \(failedCount)")
                print("   Failed keys:")
                for key in failedKeys {
                    print("     - \(key)")
                }
            }

            if failedCount == 0 {
                Logger.info("Successfully deleted all \(deletedCount) VSS keys")
                app.toast(
                    type: .success,
                    title: "All Keys Deleted",
                    description: "Successfully deleted \(deletedCount) key(s) from VSS"
                )
            } else {
                Logger.warn("Deleted \(deletedCount) keys, but \(failedCount) failed")
                app.toast(
                    type: .warning,
                    title: "Partial Deletion",
                    description: "Deleted \(deletedCount) of \(allKeys.count) keys\n\(failedCount) failed"
                )
            }

        } catch {
            Logger.error("Failed to delete all VSS keys: \(error)")
            app.toast(
                type: .error,
                title: "Error",
                description: "Failed to delete VSS keys: \(error.localizedDescription)"
            )
        }
    }

    func deobfuscateAndListKeys(obfuscatedKeys: [KeyVersion]) async {
        do {
            let vssClient = VssBackupClient.shared
            let lightningService = LightningService.shared
            let walletIndex = lightningService.currentWalletIndex
            try await vssClient.setup(walletIndex: walletIndex)

            print("\n🔓 Deobfuscating VSS keys...")
            print("   Total keys: \(obfuscatedKeys.count)\n")

            // Deobfuscate each key
            for (index, keyVersion) in obfuscatedKeys.enumerated() {
                do {
                    let deobfuscated = try await vssClient.deobfuscateKey(key: keyVersion.key)
                    print("   \(index + 1).")
                    print("      Obfuscated: \(keyVersion.key)")
                    print("      Deobfuscated: \(deobfuscated)")
                    print("      Version: \(keyVersion.version)\n")
                } catch {
                    print("   \(index + 1).")
                    print("      Obfuscated: \(keyVersion.key)")
                    print("      Deobfuscated: ❌ Failed - \(error)")
                    print("      Version: \(keyVersion.version)\n")
                    Logger.debug("Failed to deobfuscate key '\(keyVersion.key)': \(error)")
                }
            }

            print("   ✅ Finished deobfuscating \(obfuscatedKeys.count) key(s)\n")

        } catch {
            Logger.error("Failed to deobfuscate keys: \(error)")
            print("\n❌ Error deobfuscating keys: \(error)")
        }
    }

    func logNetworkGraphInfo() async {
        do {
            let lightningService = LightningService.shared
            let info = try await lightningService.logNetworkGraphInfo()
            app.toast(type: .info, title: "Network Graph Info", description: info)
        } catch {
            Logger.error("Failed to log network graph info: \(error)")
        }
    }

    func restartNode() async {
        do {
            isRestartingNode = true
            let lightningService = LightningService.shared
            try await lightningService.restart()
            app.toast(type: .success, title: "Node Restarted", description: "Node restarted successfully")
        } catch {
            Logger.error("Failed to restart node: \(error)")
            app.toast(type: .error, title: "Error", description: "Failed to restart node: \(error.localizedDescription)")
        }

        isRestartingNode = false
    }
}
