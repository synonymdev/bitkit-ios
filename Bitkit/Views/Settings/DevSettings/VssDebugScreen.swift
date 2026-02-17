import SwiftUI
import VssRustClientFfi

private enum VssTab: String, CaseIterable, CustomStringConvertible {
    case app
    case ldk

    var description: String {
        switch self {
        case .app: return "App"
        case .ldk: return "LDK"
        }
    }
}

struct VssLdkKeyItem: Identifiable {
    let id = UUID()
    let keyVersion: KeyVersion
    let namespace: LdkNamespace
}

private struct ShareableFileList: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct VssDebugScreen: View {
    @EnvironmentObject var app: AppViewModel

    @State private var selectedTab: VssTab = .app
    @State private var appKeys: [KeyVersion] = []
    @State private var ldkKeys: [VssLdkKeyItem] = []
    @State private var isLoading = false
    @State private var showDeleteAllConfirmation = false
    @State private var shareableFileList: ShareableFileList?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: "VSS Debug",
                action: AnyView(Button(action: {
                    Task { await loadKeysForCurrentTab() }
                }) {
                    Image("arrows-clockwise")
                        .resizable()
                        .foregroundColor(isLoading ? .secondary : .textPrimary)
                        .frame(width: 24, height: 24)
                })
            )
            .padding(.bottom, 16)

            SegmentedControl(selectedTab: $selectedTab, tabs: VssTab.allCases)
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    switch selectedTab {
                    case .app:
                        appSection
                    case .ldk:
                        ldkSection
                    }
                }
            }
            .refreshable {
                await loadKeysForCurrentTab()
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .alert(
            "Delete all keys?",
            isPresented: $showDeleteAllConfirmation,
            actions: {
                Button(t("common__cancel"), role: .cancel) {
                    showDeleteAllConfirmation = false
                }
                Button(t("common__delete_yes"), role: .destructive) {
                    Task { await deleteAllAppKeys() }
                    showDeleteAllConfirmation = false
                }
            },
            message: {
                Text("This will remove all app-level VSS keys. LDK keys are not affected.")
            }
        )
        .task(id: selectedTab) {
            await loadKeysForCurrentTab()
        }
        .sheet(item: $shareableFileList, onDismiss: {
            if let list = shareableFileList {
                for url in list.urls {
                    try? FileManager.default.removeItem(at: url)
                }
                if let dir = list.urls.first?.deletingLastPathComponent() {
                    try? FileManager.default.removeItem(at: dir)
                }
            }
            shareableFileList = nil
        }) { item in
            ShareSheet(activityItems: item.urls)
        }
    }

    /// Loads keys for the currently selected tab (used on appear, tab change, and refresh).
    @MainActor
    private func loadKeysForCurrentTab() async {
        switch selectedTab {
        case .app:
            await listAppKeys()
        case .ldk:
            await listLdkKeys()
        }
    }

    // MARK: - App tab

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !appKeys.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(appKeys, id: \.key) { keyVersion in
                        appKeyRow(keyVersion: keyVersion)
                    }
                }

                HStack(spacing: 8) {
                    CustomButton(
                        title: "Export",
                        variant: .secondary,
                        size: .small,
                        icon: Image(systemName: "square.and.arrow.up"),
                        isDisabled: isLoading
                    ) {
                        Task { await exportAllAppKeys() }
                    }
                    CustomButton(
                        title: "Delete All",
                        variant: .secondary,
                        size: .small,
                        icon: Image("trash")
                            .resizable()
                            .frame(width: 16, height: 16),
                        isLoading: isLoading
                    ) {
                        showDeleteAllConfirmation = true
                    }
                }
            }
        }
    }

    private func appKeyRow(keyVersion: KeyVersion) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SubtitleText(keyVersion.key)
                    .lineLimit(1)
                    .truncationMode(.middle)
                FootnoteText("v\(keyVersion.version)")
            }
            Spacer(minLength: 8)
            Button {
                Task { await deleteAppKey(keyVersion.key) }
            } label: {
                Image("trash")
                    .foregroundColor(.redAccent)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isLoading)
            .accessibilityLabel("Delete key \(keyVersion.key)")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(Color.white08)
        .cornerRadius(8)
    }

    // MARK: - LDK tab

    private var ldkSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !ldkKeys.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ldkKeys) { item in
                        ldkKeyRow(item: item)
                    }
                }

                CustomButton(
                    title: "Export",
                    variant: .secondary,
                    size: .small,
                    icon: Image(systemName: "square.and.arrow.up"),
                    isDisabled: isLoading
                ) {
                    Task { await exportAllLdkKeys() }
                }
            }
        }
    }

    private func ldkKeyRow(item: VssLdkKeyItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SubtitleText(item.keyVersion.key)
                    .lineLimit(1)
                    .truncationMode(.middle)
                FootnoteText(ldkNamespaceLabel(item.namespace) + " (v\(item.keyVersion.version))")
            }
            Spacer(minLength: 8)
            Button {
                Task { await deleteLdkKey(item) }
            } label: {
                Image("trash")
                    .foregroundColor(.redAccent)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isLoading)
            .accessibilityLabel("Delete key \(item.keyVersion.key)")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(Color.white08)
        .cornerRadius(8)
    }

    private func ldkNamespaceLabel(_ namespace: LdkNamespace) -> String {
        switch namespace {
        case .default: return "default"
        case .monitors: return "monitors"
        case let .monitorUpdates(monitorId): return "monitorUpdates(\(monitorId))"
        case .archivedMonitors: return "archivedMonitors"
        }
    }

    private func sanitizedFilename(from key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// Writes export files to a temp directory and returns their URLs.
    private func writeExportFiles(_ files: [(name: String, data: Data)], subdirectory: String = "vss_exports") throws -> [URL] {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(subdirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return try files.map { name, data in
            let url = tempDir.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
    }

    // MARK: - Actions

    @MainActor
    private func listAppKeys() async {
        isLoading = true
        defer { isLoading = false }
        do {
            appKeys = try await VssBackupClient.shared.listKeyVersions()
        } catch {
            Logger.error("VSS list app keys failed: \(error)", context: "VssDebugScreen")
            app.toast(type: .error, title: "Failed to list keys", description: error.localizedDescription)
        }
    }

    @MainActor
    private func deleteAppKey(_ key: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let wasDeleted = try await VssBackupClient.shared.deleteKey(key)
            if wasDeleted {
                appKeys.removeAll { $0.key == key }
                app.toast(type: .success, title: "Deleted key: \(key)", description: "The app key was removed from VSS.")
            } else {
                app.toast(type: .warning, title: "Key not found: \(key)", description: "The key may have been deleted already.")
            }
        } catch {
            Logger.error("VSS delete app key failed: \(error)", context: "VssDebugScreen")
            app.toast(type: .error, title: "Failed to delete key", description: error.localizedDescription)
        }
    }

    @MainActor
    private func deleteAllAppKeys() async {
        showDeleteAllConfirmation = false
        isLoading = true
        defer { isLoading = false }
        do {
            try await VssBackupClient.shared.deleteAllKeys()
            appKeys = []
            app.toast(type: .success, title: "All app keys deleted", description: "All app-level keys were removed from VSS.")
        } catch {
            Logger.error("VSS delete all app keys failed: \(error)", context: "VssDebugScreen")
            app.toast(type: .error, title: "Failed to delete all keys", description: error.localizedDescription)
        }
    }

    @MainActor
    private func listLdkKeys() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let tagged = try await VssBackupClient.shared.listAllKeysTaggedLdk()
            ldkKeys = tagged.map { VssLdkKeyItem(keyVersion: $0.1, namespace: $0.0) }
        } catch {
            Logger.error("VSS list LDK keys failed: \(error)", context: "VssDebugScreen")
            app.toast(type: .error, title: "Failed to list LDK keys", description: error.localizedDescription)
        }
    }

    @MainActor
    private func deleteLdkKey(_ item: VssLdkKeyItem) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let wasDeleted = try await VssBackupClient.shared.deleteObjectLdk(key: item.keyVersion.key, namespace: item.namespace)
            if wasDeleted {
                ldkKeys.removeAll { $0.id == item.id }
                app.toast(type: .success, title: "Deleted LDK key: \(item.keyVersion.key)", description: "The LDK key was removed from VSS.")
            } else {
                app.toast(type: .warning, title: "Key not found: \(item.keyVersion.key)", description: "The key may have been deleted already.")
            }
        } catch {
            Logger.error("VSS delete LDK key failed: \(error)", context: "VssDebugScreen")
            app.toast(type: .error, title: "Failed to delete LDK key", description: error.localizedDescription)
        }
    }

    @MainActor
    private func exportAllAppKeys() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let keys = try await VssBackupClient.shared.listKeyVersions()
            if keys.isEmpty {
                app.toast(type: .info, title: "No keys to export", description: "There are no app keys to export.")
                return
            }
            var files: [(name: String, data: Data)] = []
            for kv in keys {
                guard let item = try await VssBackupClient.shared.getObject(key: kv.key) else { continue }
                files.append(("vss_app_\(sanitizedFilename(from: kv.key))", item.value))
            }
            if files.isEmpty {
                app.toast(type: .warning, title: "No key data", description: "No key values could be read.")
                return
            }
            let urls = try writeExportFiles(files)
            shareableFileList = ShareableFileList(urls: urls)
        } catch {
            Logger.error("VSS export all app keys failed: \(error)", context: "VssDebugScreen")
            app.toast(type: .error, title: "Failed to export keys", description: error.localizedDescription)
        }
    }

    @MainActor
    private func exportAllLdkKeys() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if ldkKeys.isEmpty {
                app.toast(type: .info, title: "No keys to export", description: "List keys first, then export all.")
                return
            }
            var files: [(name: String, data: Data)] = []
            for item in ldkKeys {
                guard let vssItem = try await VssBackupClient.shared.getObjectLdk(key: item.keyVersion.key, namespace: item.namespace)
                else { continue }
                let namespaceLabel = sanitizedFilename(from: ldkNamespaceLabel(item.namespace))
                files.append(("vss_ldk_\(namespaceLabel)_\(sanitizedFilename(from: item.keyVersion.key))", vssItem.value))
            }
            if files.isEmpty {
                app.toast(type: .warning, title: "No key data", description: "No LDK key values could be read.")
                return
            }
            let urls = try writeExportFiles(files)
            shareableFileList = ShareableFileList(urls: urls)
        } catch {
            Logger.error("VSS export all LDK keys failed: \(error)", context: "VssDebugScreen")
            app.toast(type: .error, title: "Failed to export LDK keys", description: error.localizedDescription)
        }
    }
}
