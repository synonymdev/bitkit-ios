import SwiftUI

struct BackupMnemonicView: View {
    @EnvironmentObject private var app: AppViewModel
    @Binding var navigationPath: [BackupRoute]
    @State private var mnemonic: [String] = []
    @State private var passphrase: String = ""
    @State private var showMnemonic: Bool = false

    private var text: String {
        showMnemonic
            ? t("security__mnemonic_write", variables: ["length": "\(mnemonic.count)"])
            : t("security__mnemonic_use")
    }

    private var note: String {
        showMnemonic
            ? t("security__mnemonic_note_revealed")
            : t("security__mnemonic_note_hidden")
    }

    private var mnemonicAccessibilityLabel: String {
        mnemonic.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("security__mnemonic_your"))

            VStack(spacing: 0) {
                BodyMText(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 16)

                ZStack {
                    HStack(spacing: 16) {
                        // First column - first half of words
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(0 ..< mnemonic.count / 2, id: \.self) { index in
                                WordView(number: index + 1, word: mnemonic[index])
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Second column - second half of words
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(mnemonic.count / 2 ..< mnemonic.count, id: \.self) { index in
                                WordView(number: index + 1, word: mnemonic[index])
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(32)
                    .background(Color.gray6)
                    .blur(radius: showMnemonic ? 0 : 5)
                    .screenshotPreventMask(true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("SeedContainer")
                    .accessibilityLabel(mnemonicAccessibilityLabel)
                    .accessibilityHidden(!showMnemonic)

                    if !showMnemonic {
                        CustomButton(
                            title: t("security__mnemonic_reveal"),
                            icon: Image("eye").resizable().frame(width: 16, height: 16)
                        ) {
                            showMnemonic = true
                        }
                        .frame(maxWidth: 180)
                        .accessibilityIdentifier("TapToReveal")
                    }
                }
                .cornerRadius(16)
                .padding(.top, 16)
                .padding(.bottom, 32)
                .onLongPressGesture(minimumDuration: 1.0) {
                    if Env.isDebug || Env.isTestFlight {
                        let mnemonicString = mnemonic.joined(separator: " ")
                        UIPasteboard.general.string = mnemonicString
                        app.toast(type: .success, title: t("common__copied"), description: "Mnemonic copied to clipboard")
                    }
                }

                BodySText(note, textColor: .brandAccent, accentFont: Fonts.bold)

                Spacer()

                HStack(alignment: .center, spacing: 16) {
                    CustomButton(title: t("common__continue"), isDisabled: !showMnemonic) {
                        let route =
                            passphrase.isEmpty
                                ? BackupRoute.confirmMnemonic(mnemonic: mnemonic, passphrase: passphrase)
                                : BackupRoute.passphrase(mnemonic: mnemonic, passphrase: passphrase)
                        navigationPath.append(route)
                    }
                    .accessibilityIdentifier("ContinueShowMnemonic")
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadMnemonic()
        }
    }

    private func loadMnemonic() {
        do {
            // Get mnemonic for wallet index 0
            if let words = try Keychain.loadString(key: .bip39Mnemonic(index: 0)) {
                mnemonic = words.split(separator: " ").map { String($0) }
            } else {
                app.toast(
                    type: .error,
                    title: t("security__mnemonic_error"),
                    description: t("security__mnemonic_error_description")
                )
            }

            passphrase = try Keychain.loadString(key: .bip39Passphrase(index: 0)) ?? ""
        } catch {
            app.toast(
                type: .error,
                title: t("security__mnemonic_error"),
                description: t("security__mnemonic_error_description")
            )
        }
    }
}

struct WordView: View {
    let number: Int
    let word: String

    var body: some View {
        HStack(spacing: 0) {
            BodyMSBText("\(number).", textColor: .textSecondary)
            BodyMSBText(" \(word)")
        }
    }
}
