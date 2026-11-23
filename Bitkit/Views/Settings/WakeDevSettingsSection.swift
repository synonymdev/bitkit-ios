import BitkitCore
import SwiftUI

/// The wake gateway in use, what it stored for this device, and actions to register and send the self-test.
struct WakeDevSettingsSection: View {
    @EnvironmentObject private var app: AppViewModel

    @State private var deviceRows: [(title: String, value: String)] = []
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("WAKE")
                .padding(.top, 16)

            SettingsRow(title: "Gateway", subtitle: Env.wakeGatewayUrl ?? "Not configured (WAKE_GATEWAY_URL)", rightIcon: nil)

            ForEach(deviceRows, id: \.title) { row in
                SettingsRow(title: row.title, subtitle: row.value, rightIcon: nil)
            }

            Button {
                Task { await refreshDevice() }
            } label: {
                SettingsRow(title: "Refresh Device Status", rightIcon: nil)
            }
            .accessibilityIdentifier("WakeRefreshDevice")

            Button {
                Task { await register() }
            } label: {
                SettingsRow(title: "Register Now", rightIcon: nil)
            }
            .accessibilityIdentifier("WakeRegister")

            Button {
                Task { await sendTestWake() }
            } label: {
                SettingsRow(title: "Send Test Wake", rightIcon: nil)
            }
            .accessibilityIdentifier("WakeSendTest")
        }
        .disabled(isWorking || Env.wakeGatewayUrl == nil)
        .task { await refreshDevice() }
    }

    private func refreshDevice() async {
        guard Env.wakeGatewayUrl != nil else { return }
        do {
            deviceRows = try await Self.rows(for: WakeManager.shared.device())
        } catch {
            deviceRows = [("Device", error.localizedDescription)]
        }
    }

    private func register() async {
        isWorking = true
        defer { isWorking = false }
        switch await WakeManager.shared.registerNow() {
        case let .registered(deviceId, unknownTopics):
            let unknown = unknownTopics.isEmpty ? "" : ", unknown topics: \(unknownTopics.joined(separator: ", "))"
            app.toast(type: .success, title: "Registered for wakes", description: "\(deviceId)\(unknown)")
        case .unchanged:
            app.toast(type: .info, title: "Already registered", description: nil)
        case let .failed(message):
            app.toast(type: .error, title: "Wake registration failed", description: message)
        case let other:
            app.toast(type: .warning, title: "Not registered", description: "\(other)")
        }
        await refreshDevice()
    }

    private func sendTestWake() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let wakeId = try await WakeManager.shared.sendTestWake()
            app.toast(type: .success, title: "Test wake sent", description: wakeId)
        } catch {
            app.toast(type: .error, title: "Test wake failed", description: error.localizedDescription)
        }
    }

    private static func rows(for device: WakeDevice) -> [(title: String, value: String)] {
        let presence = device.presenceExpiresAt.map {
            "Until \(Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .omitted, time: .standard))"
        }
        return [
            ("Device", device.deviceId),
            ("Environment", "\(device.environment)"),
            ("Identities", device.identities.joined(separator: ", ")),
            ("Topics", device.topics.joined(separator: ", ")),
            ("Presence", presence ?? "None"),
        ]
    }
}
