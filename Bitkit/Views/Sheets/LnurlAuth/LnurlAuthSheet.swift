import BitkitCore
import LDKNode
import SwiftUI

struct LnurlAuthConfig {
    let authData: LnurlAuthData
    let lnurl: String

    init(lnurl: String, authData: LnurlAuthData) {
        self.lnurl = lnurl
        self.authData = authData
    }
}

struct LnurlAuthSheetItem: SheetItem {
    let id: SheetID = .lnurlAuth
    let size: SheetSize = .large
    let lnurl: String
    let authData: LnurlAuthData

    init(lnurl: String, authData: LnurlAuthData) {
        self.lnurl = lnurl
        self.authData = authData
    }
}

struct LnurlAuthSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    let config: LnurlAuthSheetItem

    var actionText: String {
        switch config.authData.tag {
        case "login":
            return "Log In"
        case "register":
            return "Register"
        case "link":
            return "Link"
        default:
            return "Authenticate"
        }
    }

    var text: String {
        switch config.authData.tag {
        case "login":
            return "Log in to \(extractedDomain)?"
        case "register":
            return "Register at \(extractedDomain)?"
        case "link":
            return "Link account to \(extractedDomain)?"
        default:
            return "Authenticate at \(extractedDomain)?"
        }
    }

    var body: some View {
        Sheet(id: .lnurlAuth, data: config) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: actionText)

                TitleText(extractedDomain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 16)

                BodyMText(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 16)

                Spacer()

                Image("keyring")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 256)
                    .padding(.bottom, 32)

                Spacer()

                HStack(alignment: .center, spacing: 16) {
                    CustomButton(
                        title: t("common__cancel"),
                        variant: .secondary
                    ) {
                        onCancel()
                    }
                    .accessibilityIdentifier("LnurlAuthCancel")

                    CustomButton(title: actionText) {
                        Task {
                            await onContinue()
                        }
                    }
                    .accessibilityIdentifier("LnurlAuthContinue")
                }
                .padding(.top, 32)
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("LnurlAuth")
        }
    }

    private var extractedDomain: String {
        guard let url = URL(string: config.authData.uri),
              let host = url.host
        else {
            return "Unknown Domain"
        }

        var domain = host.trimmingCharacters(in: .whitespacesAndNewlines)

        // For localhost, include the port
        if domain == "localhost", let port = url.port {
            domain = "\(domain):\(port)"
        }

        return domain
    }

    private func onCancel() {
        sheets.hideSheet()
    }

    private func onContinue() async {
        do {
            let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: 0)) ?? ""
            let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: 0)) ?? ""

            let response = try await lnurlAuth(
                domain: extractedDomain,
                k1: config.authData.k1,
                callback: config.authData.uri,
                bip32Mnemonic: mnemonic,
                network: Env.bitkitCoreNetwork,
                bip39Passphrase: passphrase.isEmpty ? nil : passphrase
            )

            Logger.debug("LNURL auth response: \(response)")

            // Close the sheet on success
            app.toast(
                type: .success,
                title: t("other__lnurl_auth_success_title"),
                description: t("other__lnurl_auth_success_msg_no_domain")
            )
            sheets.hideSheet()
        } catch {
            Logger.error("Failed to handle LNURL auth: \(error)")

            let errorMsg = (error as NSError).localizedDescription
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = errorMsg.isEmpty ? String(describing: type(of: error)) : errorMsg

            app.toast(
                type: .error,
                title: t("other__lnurl_auth_error"),
                description: t("other__lnurl_auth_error_msg", variables: ["raw": raw])
            )
        }
    }
}
