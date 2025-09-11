import SwiftUI

struct RecoveryMnemonicScreen: View {
    @EnvironmentObject private var app: AppViewModel

    @Binding var navigationPath: [RecoveryRoute]

    @State private var mnemonic: [String] = []
    @State private var passphrase: String = ""
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: t("security__mnemonic_phrase"),
                showMenuButton: false,
                onBack: {
                    navigationPath.removeLast()
                }
            )
            .padding(.bottom, 16)

            if isLoading {
                Spacer()
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .textPrimary))
                    .scaleEffect(1.5)
                Spacer()
            } else {
                GeometryReader { geometry in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            BodyMText(t("security__mnemonic_write", variables: ["length": "\(mnemonic.count)"]))
                                .padding(.bottom, 16)

                            // Mnemonic words
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
                            .cornerRadius(16)
                            .privacySensitive()

                            // Passphrase section (if available)
                            if !passphrase.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    BodyMText(t("security__pass_text"))
                                        .padding(.bottom, 16)

                                    BodyMSBText(
                                        t("security__pass_recovery", variables: ["passphrase": passphrase]),
                                        accentColor: .textSecondary
                                    )
                                }
                                .padding(.top, 32)
                            }

                            Spacer()

                            CustomButton(title: t("common__back")) {
                                navigationPath.removeLast()
                            }
                        }
                        .frame(minHeight: geometry.size.height)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
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
                    title: "Mnemonic Error",
                    description: "Unable to load mnemonic phrase"
                )
            }

            passphrase = try Keychain.loadString(key: .bip39Passphrase(index: 0)) ?? ""
        } catch {
            app.toast(
                type: .error,
                title: "Mnemonic Error",
                description: "Unable to load mnemonic phrase"
            )
        }

        isLoading = false
    }
}
