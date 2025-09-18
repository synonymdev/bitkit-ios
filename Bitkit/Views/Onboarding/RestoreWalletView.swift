import SwiftUI

struct RestoreWalletView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var words: [String] = Array(repeating: "", count: 12)
    @State private var bip39Passphrase = ""
    @State private var showingPassphrase = false
    @State private var firstFieldText: String = ""
    @FocusState private var focusedField: Int?
    @FocusState private var isPassphraseFocused: Bool

    private let wordCount = 12
    private let wordsPerColumn = 6

    private var isValidMnemonic: Bool {
        let currentWords = words[..<wordCount]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Check if we have the correct number of words
        guard currentWords.count == wordCount else {
            return false
        }

        return BIP39.isValid(phrase: currentWords)
    }

    private var bip39Mnemonic: String {
        return words[..<wordCount]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private var validationError: BIP39.Error? {
        let currentWords = words[..<wordCount]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Check if we have the correct number of words
        guard currentWords.count == wordCount else {
            return nil
        }

        // Check if all words are valid first
        let invalidWords = currentWords.filter { !BIP39.isValidWord($0) }
        if !invalidWords.isEmpty {
            return .invalidMnemonic
        }

        // Now validate the full phrase
        switch BIP39.validate(phrase: currentWords) {
        case .success:
            return nil
        case let .failure(error):
            return error
        }
    }

    private var validationInfo: (message: String, color: Color)? {
        guard let error = validationError else { return nil }

        switch error {
        case .invalidMnemonic:
            // Check if it's invalid words or checksum
            let currentWords = words[..<wordCount]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            let invalidWords = currentWords.filter { !BIP39.isValidWord($0) }
            if !invalidWords.isEmpty {
                return (t("onboarding__restore_red_explain"), .textSecondary)
            } else {
                return (t("onboarding__restore_inv_checksum"), .redAccent)
            }
        case .invalidEntropy:
            return (t("onboarding__restore_inv_checksum"), .redAccent)
        }
    }

    private var currentFocusedWord: String {
        guard let focusedField else { return "" }
        if focusedField == 0 {
            return firstFieldText
        }
        return words[focusedField]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        headerSection
                        wordInputSection
                        passphraseSection
                        validationSection
                        Spacer(minLength: 16)
                        buttonSection
                    }
                    .frame(minHeight: geometry.size.height)
                    .padding(.horizontal, 32)
                    .bottomSafeAreaPadding()
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            keyboardAccessory
        }
    }

    private var headerSection: some View {
        VStack(spacing: 0) {
            DisplayText(t("onboarding__restore_header"), accentColor: .blueAccent)
                .padding(.top, 40)
                .padding(.bottom, 14)

            BodyMText(t("onboarding__restore_phrase"))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var wordInputSection: some View {
        HStack(alignment: .top, spacing: 4) {
            // First column (1-6 or 1-12)
            VStack(spacing: 4) {
                ForEach(0 ..< wordsPerColumn) { index in
                    SeedTextField(
                        index: index,
                        text: index == 0 ? $firstFieldText : $words[index],
                        isLastField: index == (wordsPerColumn * 2 - 1),
                        focusedField: $focusedField
                    )
                    .onChange(of: firstFieldText) { newValue in
                        if index == 0 && newValue.contains(" ") {
                            handlePastedWords(newValue)
                        } else if index == 0 {
                            words[index] = newValue
                        }
                    }
                }
            }

            // Second column (7-12 or 13-24)
            VStack(spacing: 4) {
                ForEach(wordsPerColumn ..< (wordsPerColumn * 2)) { index in
                    SeedTextField(
                        index: index,
                        text: $words[index],
                        isLastField: index == (wordsPerColumn * 2 - 1),
                        focusedField: $focusedField
                    )
                }
            }
        }
        .padding(.top, 44)
    }

    private var passphraseSection: some View {
        Group {
            if showingPassphrase {
                VStack(spacing: 16) {
                    TextField(t("onboarding__restore_passphrase_placeholder"), text: $bip39Passphrase)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .focused($isPassphraseFocused)
                        .padding(.top, 4)

                    BodySText(t("onboarding__restore_passphrase_meaning"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var validationSection: some View {
        Group {
            if let info = validationInfo {
                BodyMText(info.message, textColor: info.color, accentColor: .redAccent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
            }
        }
    }

    private var buttonSection: some View {
        HStack(spacing: 16) {
            if !showingPassphrase {
                CustomButton(
                    title: t("onboarding__advanced"),
                    variant: .secondary,
                    isDisabled: !isValidMnemonic
                ) {
                    showingPassphrase.toggle()
                    isPassphraseFocused = true
                }
            }

            CustomButton(
                title: showingPassphrase ? t("onboarding__restore_wallet") : t("onboarding__restore"),
                isDisabled: !isValidMnemonic
            ) {
                restoreWallet()
            }
        }
    }

    private var keyboardAccessory: some View {
        Group {
            if focusedField != nil {
                SeedInputAccessory(currentWord: currentFocusedWord) { selectedWord in
                    if let focusedField {
                        if focusedField == 0 {
                            firstFieldText = selectedWord
                        } else {
                            words[focusedField] = selectedWord
                        }

                        // Move to next field
                        if focusedField < words.count - 1 {
                            self.focusedField = focusedField + 1
                        } else {
                            self.focusedField = nil
                        }
                    }
                }
            }
        }
    }

    private func restoreWallet() {
        do {
            wallet.nodeLifecycleState = .initializing
            wallet.isRestoringWallet = true
            app.showAllEmptyStates(false)
            _ = try StartupHandler.restoreWallet(mnemonic: bip39Mnemonic, bip39Passphrase: bip39Passphrase)
            try wallet.setWalletExistsState()
        } catch {
            app.toast(error)
        }
    }

    private func handlePastedWords(_ pastedText: String) {
        let pastedWords =
            pastedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }

        // Check if word count is valid
        guard pastedWords.count == wordCount else { return }

        // Update all fields
        for (index, word) in pastedWords.enumerated() {
            words[index] = word.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Clear the first field's temporary text
        firstFieldText = words[0]

        // Close the keyboard
        focusedField = nil
    }
}

#Preview {
    NavigationStack {
        RestoreWalletView()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
    }
    .preferredColorScheme(.dark)
}
