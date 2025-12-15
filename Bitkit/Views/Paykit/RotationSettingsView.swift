//
//  RotationSettingsView.swift
//  Bitkit
//
//  Endpoint rotation settings view
//

import SwiftUI

struct RotationSettingsView: View {
    @StateObject private var viewModel = RotationSettingsViewModel()
    @EnvironmentObject private var app: AppViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Rotation Settings")
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    // Global Settings
                    globalSettingsSection
                    
                    // Method Settings
                    methodSettingsSection
                    
                    // Rotation History
                    historySection
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadSettings()
        }
    }
    
    private var globalSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyLText("Global Settings")
                .foregroundColor(.textPrimary)
            
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        BodyMText("Auto-Rotate")
                            .foregroundColor(.white)
                        
                        BodySText("Automatically rotate endpoints based on policy")
                            .foregroundColor(.textSecondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: Binding(
                        get: { viewModel.settings.autoRotateEnabled },
                        set: { newValue in
                            viewModel.settings.autoRotateEnabled = newValue
                            do {
                                try viewModel.saveSettings()
                            } catch {
                                app.toast(error)
                            }
                        }
                    ))
                    .labelsHidden()
                }
                
                Picker("Default Policy", selection: Binding(
                    get: { viewModel.settings.defaultPolicy },
                    set: { newValue in
                        viewModel.settings.defaultPolicy = newValue
                        do {
                            try viewModel.saveSettings()
                        } catch {
                            app.toast(error)
                        }
                    }
                )) {
                    ForEach(RotationPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                
                if viewModel.settings.defaultPolicy == .afterUses {
                    HStack {
                        BodyMText("Threshold:")
                            .foregroundColor(.textSecondary)
                        Spacer()
                        TextField("uses", value: Binding(
                            get: { viewModel.settings.defaultThreshold },
                            set: { newValue in
                                viewModel.settings.defaultThreshold = newValue
                                do {
                                    try viewModel.saveSettings()
                                } catch {
                                    app.toast(error)
                                }
                            }
                        ), format: .number)
                            .foregroundColor(.white)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .padding(12)
                            .background(Color.gray900)
                            .cornerRadius(8)
                            .frame(width: 100)
                    }
                }
            }
            .padding(16)
            .background(Color.gray900)
            .cornerRadius(8)
        }
    }
    
    private var methodSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyLText("Method Settings")
                .foregroundColor(.textPrimary)
            
            if viewModel.methodSettings.isEmpty {
                BodyMText("No method-specific settings")
                    .foregroundColor(.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(Color.gray900)
                    .cornerRadius(8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.methodSettings.keys.sorted()), id: \.self) { methodId in
                        if let methodSettings = viewModel.methodSettings[methodId] {
                            MethodSettingsRow(
                                methodId: methodId,
                                settings: methodSettings,
                                viewModel: viewModel
                            )
                            
                            if methodId != viewModel.methodSettings.keys.sorted().last {
                                Divider()
                                    .background(Color.white16)
                            }
                        }
                    }
                }
                .background(Color.gray900)
                .cornerRadius(8)
            }
        }
    }
    
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BodyLText("Rotation History")
                    .foregroundColor(.textPrimary)
                
                Spacer()
                
                Button {
                    do {
                        try viewModel.clearHistory()
                        viewModel.loadSettings()
                        app.toast(type: .success, title: "History cleared")
                    } catch {
                        app.toast(error)
                    }
                } label: {
                    BodySText("Clear")
                        .foregroundColor(.brandAccent)
                }
            }
            
            if viewModel.history.isEmpty {
                BodyMText("No rotation history")
                    .foregroundColor(.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(Color.gray900)
                    .cornerRadius(8)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.history) { event in
                        HistoryRow(event: event)
                        
                        if event.id != viewModel.history.last?.id {
                            Divider()
                                .background(Color.white16)
                        }
                    }
                }
                .background(Color.gray900)
                .cornerRadius(8)
            }
        }
    }
}

struct MethodSettingsRow: View {
    let methodId: String
    let settings: MethodRotationSettings
    @ObservedObject var viewModel: RotationSettingsViewModel
    @EnvironmentObject private var app: AppViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText(methodId)
                .foregroundColor(.white)
            
            Picker("Policy", selection: Binding(
                get: { settings.policy },
                set: { newValue in
                    var updated = settings
                    updated.policy = newValue
                    do {
                        try viewModel.updateMethodSettings(methodId, updated)
                    } catch {
                        app.toast(error)
                    }
                }
            )) {
                ForEach(RotationPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.segmented)
            
            if settings.policy == .afterUses {
                HStack {
                    BodyMText("Threshold:")
                        .foregroundColor(.textSecondary)
                    Spacer()
                    TextField("uses", value: Binding(
                        get: { settings.threshold },
                        set: { newValue in
                            var updated = settings
                            updated.threshold = newValue
                            do {
                                try viewModel.updateMethodSettings(methodId, updated)
                            } catch {
                                app.toast(error)
                            }
                        }
                    ), format: .number)
                        .foregroundColor(.white)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .padding(12)
                        .background(Color.gray900)
                        .cornerRadius(8)
                        .frame(width: 100)
                }
            }
            
            BodySText("Uses: \(settings.useCount) | Rotations: \(settings.rotationCount)")
                .foregroundColor(.textSecondary)
        }
        .padding(16)
    }
}

struct HistoryRow: View {
    let event: RotationEvent
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                BodyMText(event.methodId)
                    .foregroundColor(.white)
                
                BodySText(event.reason)
                    .foregroundColor(.textSecondary)
            }
            
            Spacer()
            
            BodySText(formatDate(event.timestamp))
                .foregroundColor(.textSecondary)
        }
        .padding(16)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

@MainActor
class RotationSettingsViewModel: ObservableObject {
    @Published var settings: RotationSettings
    @Published var methodSettings: [String: MethodRotationSettings] = [:]
    @Published var history: [RotationEvent] = []
    
    private let storage: RotationSettingsStorage
    private let identityName: String
    
    init(identityName: String = "default") {
        self.identityName = identityName
        self.storage = RotationSettingsStorage(identityName: identityName)
        self.settings = storage.loadSettings()
    }
    
    func loadSettings() {
        settings = storage.loadSettings()
        methodSettings = settings.methodSettings
        history = storage.loadHistory()
    }
    
    func saveSettings() throws {
        try storage.saveSettings(settings)
    }
    
    func updateMethodSettings(_ methodId: String, _ methodSettings: MethodRotationSettings) throws {
        try storage.updateMethodSettings(methodId, methodSettings)
        loadSettings()
    }
    
    func clearHistory() throws {
        try storage.clearHistory()
    }
}

