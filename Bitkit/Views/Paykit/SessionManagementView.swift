//
//  SessionManagementView.swift
//  Bitkit
//
//  View for managing Pubky sessions - viewing, exporting, and removing sessions
//

import SwiftUI

struct SessionManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SessionManagementViewModel()
    @State private var showExportSheet = false
    @State private var showImportSheet = false
    @State private var showDeleteConfirmation = false
    @State private var selectedSession: PubkySession?
    @State private var importText = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: "Session Management",
                showBackButton: true,
                action: AnyView(menuButton),
                onBack: { dismiss() }
            )
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    // Device Info Section
                    deviceInfoSection
                    
                    // Active Sessions Section
                    sessionsSection
                    
                    // Backup Section
                    backupSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadSessions()
        }
        .sheet(isPresented: $showExportSheet) {
            ExportBackupSheet(
                backupJSON: viewModel.exportBackupJSON(),
                onDismiss: { showExportSheet = false }
            )
        }
        .sheet(isPresented: $showImportSheet) {
            ImportBackupSheet(
                importText: $importText,
                onImport: { overwriteDeviceId in
                    viewModel.importBackup(jsonString: importText, overwriteDeviceId: overwriteDeviceId)
                    showImportSheet = false
                    importText = ""
                },
                onDismiss: { showImportSheet = false }
            )
        }
        .alert("Remove Session", isPresented: $showDeleteConfirmation, presenting: selectedSession) { session in
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                viewModel.removeSession(pubkey: session.pubkey)
            }
        } message: { session in
            Text("Are you sure you want to remove this session for \(session.pubkey.prefix(12))...?")
        }
    }
    
    private var menuButton: some View {
        Menu {
            Button {
                showImportSheet = true
            } label: {
                Label("Import Backup", systemImage: "square.and.arrow.down")
            }
            
            Button {
                viewModel.clearAllSessions()
            } label: {
                Label("Clear All Sessions", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundColor(.white)
                .font(.title3)
        }
    }
    
    private var deviceInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyLText("Device Info")
                .foregroundColor(.textSecondary)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    BodyMText("Device ID")
                        .foregroundColor(.textSecondary)
                    Spacer()
                    BodyMText(viewModel.deviceId.prefix(8) + "...")
                        .foregroundColor(.white)
                }
                
                HStack {
                    BodyMText("Current Epoch")
                        .foregroundColor(.textSecondary)
                    Spacer()
                    BodyMText("\(viewModel.currentEpoch)")
                        .foregroundColor(.white)
                }
                
                HStack {
                    BodyMText("Cached Keys")
                        .foregroundColor(.textSecondary)
                    Spacer()
                    BodyMText("\(viewModel.cachedKeyCount)")
                        .foregroundColor(.white)
                }
            }
            .padding(16)
            .background(Color.gray6)
            .cornerRadius(8)
        }
    }
    
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BodyLText("Active Sessions")
                    .foregroundColor(.textSecondary)
                
                Spacer()
                
                BodySText("\(viewModel.sessions.count) session(s)")
                    .foregroundColor(.textSecondary)
            }
            
            if viewModel.sessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundColor(.textSecondary)
                    
                    BodyMText("No active sessions")
                        .foregroundColor(.textSecondary)
                    
                    BodySText("Connect to Pubky-ring to create a session")
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(Color.gray6)
                .cornerRadius(8)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.sessions, id: \.pubkey) { session in
                        SessionRow(session: session, onRemove: {
                            selectedSession = session
                            showDeleteConfirmation = true
                        })
                        
                        if session.pubkey != viewModel.sessions.last?.pubkey {
                            Divider()
                                .background(Color.white16)
                        }
                    }
                }
                .background(Color.gray6)
                .cornerRadius(8)
            }
        }
    }
    
    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyLText("Backup & Restore")
                .foregroundColor(.textSecondary)
            
            Button {
                showExportSheet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.brandAccent)
                        .font(.title3)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        BodyMBoldText("Export Backup")
                            .foregroundColor(.white)
                        
                        BodySText("Save sessions and keys to restore later")
                            .foregroundColor(.textSecondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .foregroundColor(.textSecondary)
                        .font(.caption)
                }
                .padding(16)
                .background(Color.gray6)
                .cornerRadius(8)
            }
            
            Button {
                showImportSheet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundColor(.blue)
                        .font(.title3)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        BodyMBoldText("Import Backup")
                            .foregroundColor(.white)
                        
                        BodySText("Restore sessions and keys from backup")
                            .foregroundColor(.textSecondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .foregroundColor(.textSecondary)
                        .font(.caption)
                }
                .padding(16)
                .background(Color.gray6)
                .cornerRadius(8)
            }
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: PubkySession
    let onRemove: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    BodyMBoldText("Pubkey")
                        .foregroundColor(.textSecondary)
                    
                    BodyMText(session.pubkey.prefix(20) + "...")
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red.opacity(0.7))
                        .font(.title2)
                }
            }
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    BodySText("Created")
                        .foregroundColor(.textSecondary)
                    
                    BodySText(formatDate(session.createdAt))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    BodySText("Capabilities")
                        .foregroundColor(.textSecondary)
                    
                    BodySText(session.capabilities.isEmpty ? "None" : session.capabilities.joined(separator: ", "))
                        .foregroundColor(.white)
                }
            }
            
            if let expiresAt = session.expiresAt {
                HStack {
                    BodySText("Expires")
                        .foregroundColor(.textSecondary)
                    
                    BodySText(formatDate(expiresAt))
                        .foregroundColor(session.isExpired ? .red : .orange)
                }
            }
        }
        .padding(16)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Export Backup Sheet

struct ExportBackupSheet: View {
    let backupJSON: String
    let onDismiss: () -> Void
    
    @State private var copied = false
    
    var body: some View {
        VStack(spacing: 24) {
            HStack {
                TitleText("Export Backup", textColor: .white)
                
                Spacer()
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.textSecondary)
                        .font(.title2)
                }
            }
            
            ScrollView {
                Text(backupJSON)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.gray6)
                    .cornerRadius(8)
            }
            .frame(maxHeight: 300)
            
            Button {
                UIPasteboard.general.string = backupJSON
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copied = false
                }
            } label: {
                HStack {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "Copied!" : "Copy to Clipboard")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.brandAccent)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            
            BodySText("Save this backup in a secure location. It contains your session secrets and keys.")
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(Color.gray4)
    }
}

// MARK: - Import Backup Sheet

struct ImportBackupSheet: View {
    @Binding var importText: String
    let onImport: (_ overwriteDeviceId: Bool) -> Void
    let onDismiss: () -> Void
    
    @State private var overwriteDeviceId = false
    
    var body: some View {
        VStack(spacing: 24) {
            HStack {
                TitleText("Import Backup", textColor: .white)
                
                Spacer()
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.textSecondary)
                        .font(.title2)
                }
            }
            
            TextEditor(text: $importText)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.white)
                .frame(maxHeight: 200)
                .padding(12)
                .background(Color.gray6)
                .cornerRadius(8)
            
            Toggle(isOn: $overwriteDeviceId) {
                VStack(alignment: .leading, spacing: 4) {
                    BodyMText("Restore Device ID")
                        .foregroundColor(.white)
                    
                    BodySText("Use the device ID from the backup")
                        .foregroundColor(.textSecondary)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
            
            Button {
                onImport(overwriteDeviceId)
            } label: {
                Text("Import Backup")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(importText.isEmpty ? Color.gray : Color.brandAccent)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .disabled(importText.isEmpty)
            
            BodySText("Paste your backup JSON to restore sessions and keys.")
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(Color.gray4)
    }
}

// MARK: - ViewModel

class SessionManagementViewModel: ObservableObject {
    @Published var sessions: [PubkySession] = []
    @Published var deviceId: String = ""
    @Published var currentEpoch: UInt64 = 0
    @Published var cachedKeyCount: Int = 0
    
    private let pubkyRingBridge = PubkyRingBridge.shared
    
    func loadSessions() {
        sessions = pubkyRingBridge.getAllSessions()
        deviceId = pubkyRingBridge.deviceId
        // Epoch would typically come from a service, simplified for now
        currentEpoch = UInt64(Date().timeIntervalSince1970 / 86400) // Daily epochs
        cachedKeyCount = pubkyRingBridge.getCachedKeypairCount()
    }
    
    func removeSession(pubkey: String) {
        pubkyRingBridge.clearSession(pubkey: pubkey)
        loadSessions()
    }
    
    func clearAllSessions() {
        pubkyRingBridge.clearAllSessions()
        loadSessions()
    }
    
    func exportBackupJSON() -> String {
        do {
            let data = try pubkyRingBridge.exportBackupAsJSON()
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"error\": \"Failed to export backup\"}"
        }
    }
    
    func importBackup(jsonString: String, overwriteDeviceId: Bool) {
        guard let data = jsonString.data(using: .utf8) else { return }
        do {
            try pubkyRingBridge.importBackup(from: data, overwriteDeviceId: overwriteDeviceId)
            loadSessions()
        } catch {
            Logger.error("Failed to import backup: \(error)", context: "SessionManagementViewModel")
        }
    }
}

// MARK: - Preview

#Preview {
    SessionManagementView()
        .preferredColorScheme(.dark)
}

