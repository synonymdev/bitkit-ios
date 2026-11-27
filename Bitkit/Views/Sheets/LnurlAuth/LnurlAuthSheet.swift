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
}

/// LUD-04 `action` of an LNURL-auth request; bitkit-core reports every LNURL-auth with tag `login`.
enum LnurlAuthAction {
    case login, register, link, auth

    init(uri: String) {
        let action = URLComponents(string: uri)?.queryItems?.first { $0.name == "action" }?.value?.lowercased()
        switch action {
        case "login": self = .login
        case "register": self = .register
        case "link": self = .link
        default: self = .auth
        }
    }

    var titleKey: String {
        switch self {
        case .login: "other__lnurl_auth_login_title"
        case .register: "other__lnurl_auth_register_title"
        case .link: "other__lnurl_auth_link_title"
        case .auth: "other__lnurl_auth_auth_title"
        }
    }

    var promptKey: String {
        switch self {
        case .login: "other__lnurl_auth_login_prompt"
        case .register: "other__lnurl_auth_register_prompt"
        case .link: "other__lnurl_auth_link_prompt"
        case .auth: "other__lnurl_auth_auth_prompt"
        }
    }

    var buttonKey: String {
        self == .login ? "other__lnurl_auth_login_button" : titleKey
    }
}

struct LnurlAuthSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    let config: LnurlAuthSheetItem

    private var action: LnurlAuthAction {
        LnurlAuthAction(uri: config.authData.uri)
    }

    private var actionText: String {
        t(action.titleKey)
    }

    private var text: String {
        t(action.promptKey, variables: ["domain": extractedDomain])
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

                    CustomButton(title: t(action.buttonKey)) {
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
            return t("other__lnurl_auth_unknown_domain")
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
