import Foundation
import SwiftUI

struct ReportIssue: View {
    @State private var email: String = ""
    @State private var message: String = ""
    @State private var isLoading: Bool = false
    @State private var showingSuccess: Bool = false
    @State private var showingError: Bool = false

    private func validateEmail(_ emailText: String) -> Bool {
        if emailText.contains("@") {
            let parts = emailText.split(separator: "@")
            if parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty {
                return true
            }
        }
        return false
    }

    private var isFormValid: Bool {
        validateEmail(email) && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendRequest() async {
        isLoading = true

        do {
            // Get app version info
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
            let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"

            // Get LDK info
            var logs = ""
            var logsFileName = ""

            // Try to get LDK information
            let nodeId = LightningService.shared.nodeId

            // Get logs
            if let logData = LogService.shared.zipLogsForSupport() {
                logs = logData.logs
                logsFileName = logData.fileName
            }

            // Create the support request
            let supportRequest = [
                "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
                "message": message.trimmingCharacters(in: .whitespacesAndNewlines),
                "platform": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                "version": "\(appVersion) (\(buildNumber))",
                "ldkNodeId": nodeId ?? "",
                "logs": logs,
                "logsFileName": logsFileName,
            ]

            // Create URL request
            guard let url = URL(string: Env.supportApiUrl) else {
                throw URLError(.badURL)
            }

            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("Bitkit-iOS", forHTTPHeaderField: "User-Agent")
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: supportRequest)

            // Send request
            let (_, response) = try await URLSession.shared.data(for: urlRequest)

            // Check response
            if let httpResponse = response as? HTTPURLResponse,
                (200 ... 299).contains(httpResponse.statusCode)
            {
                // Success - reset form and show success screen
                email = ""
                message = ""
                showingSuccess = true
                Logger.info("Support request submitted successfully")
            } else {
                // Error response
                showingError = true
                Logger.error("Support request failed with HTTP response: \(response)")
            }

        } catch {
            // Handle any errors
            Logger.error("Support request failed: \(error)")
            showingError = true
        }

        isLoading = false
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    BodyMText(localizedString("settings__support__report_text"))
                        .padding(.top, 16)
                        .padding(.bottom, 32)

                    VStack(alignment: .leading, spacing: 26) {
                        VStack(alignment: .leading, spacing: 8) {
                            CaptionText(localizedString("settings__support__label_address").uppercased())

                            TextField(
                                localizedString("settings__support__placeholder_address"),
                                text: $email
                            )
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            CaptionText(
                                localizedString("settings__support__label_message").uppercased(),
                                textColor: .textSecondary
                            )

                            ZStack(alignment: .topLeading) {
                                if message.isEmpty {
                                    Text(localizedString("settings__support__placeholder_message"))
                                        .foregroundColor(.textSecondary)
                                        .font(.custom(Fonts.semiBold, size: 15))
                                        .padding(4)
                                }

                                TextEditor(text: $message)
                                    .font(.custom(Fonts.semiBold, size: 15))
                                    .foregroundColor(.textPrimary)
                                    .accentColor(.brandAccent)
                                    .scrollContentBackground(.hidden)
                                    .padding(EdgeInsets(top: -8, leading: -5, bottom: -5, trailing: -5))
                                    .padding(4)
                                    .frame(minHeight: 200, maxHeight: .infinity)
                            }
                            .frame(minHeight: 120)
                            .padding()
                            .background(Color.white10)
                            .cornerRadius(8)
                        }
                    }

                    Spacer(minLength: 16)

                    CustomButton(
                        title: localizedString("settings__support__text_button"),
                        isDisabled: !isFormValid,
                        isLoading: isLoading
                    ) {
                        await sendRequest()
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: geometry.size.height)
            }
            .navigationTitle(localizedString("settings__support__report"))
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .navigationDestination(isPresented: $showingSuccess) {
                ReportSuccess()
            }
            .navigationDestination(isPresented: $showingError) {
                ReportError()
            }
        }
    }
}
