import SwiftUI

struct BackupMnemonicView: View {
    @EnvironmentObject private var app: AppViewModel
    @Binding var navigationPath: [BackupRoute]
    @State private var mnemonic: [String] = []
    @State private var passphrase: String = ""
    @State private var showMnemonic: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: localizedString("security__mnemonic_your"))

            VStack(spacing: 0) {
                BodyMText(localizedString("security__mnemonic_write", variables: ["length": "\(mnemonic.count)"]))
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
                    .background(Color.white10)
                    .blur(radius: showMnemonic ? 0 : 5)
                    .privacySensitive()

                    if !showMnemonic {
                        Button(action: {
                            showMnemonic = true
                        }) {
                            BodySSBText(localizedString("security__mnemonic_reveal"))
                                .frame(width: 154, height: 56)
                                .background(Color.black50)
                                .cornerRadius(64)
                        }
                        .shadow(
                            color: Color.black.opacity(0.25),
                            radius: 50,
                            x: 0,
                            y: 25
                        )
                    }
                }
                .cornerRadius(16)
                .padding(.top, 16)
                .padding(.bottom, 32)
                .onLongPressGesture(minimumDuration: 1.0) {
                    if Env.isDebug || Env.isTestFlight {
                        let mnemonicString = mnemonic.joined(separator: " ")
                        UIPasteboard.general.string = mnemonicString
                        app.toast(type: .success, title: localizedString("common__copied"), description: "Mnemonic copied to clipboard")
                    }
                }

                BodySText(localizedString("security__mnemonic_never_share"), accentColor: .brandAccent)

                Spacer()

                HStack(alignment: .center, spacing: 16) {
                    CustomButton(
                        title: localizedString("common__continue"),
                        isDisabled: !showMnemonic,
                    ) {
                        let route =
                            passphrase.isEmpty
                                ? BackupRoute.confirmMnemonic(mnemonic: mnemonic, passphrase: passphrase)
                                : BackupRoute.passphrase(mnemonic: mnemonic, passphrase: passphrase)
                        navigationPath.append(route)
                    }
                }
                .padding(.top, 32)
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
                    title: localizedString("security__mnemonic_error"),
                    description: localizedString("security__mnemonic_error_description")
                )
            }

            passphrase = try Keychain.loadString(key: .bip39Passphrase(index: 0)) ?? ""
        } catch {
            app.toast(
                type: .error,
                title: localizedString("security__mnemonic_error"),
                description: localizedString("security__mnemonic_error_description")
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
