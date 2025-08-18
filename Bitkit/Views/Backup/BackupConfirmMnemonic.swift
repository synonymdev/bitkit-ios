import SwiftUI

struct BackupConfirmMnemonic: View {
    @Binding var navigationPath: [BackupRoute]
    let mnemonic: [String]
    let passphrase: String?

    @State private var shuffledWords: [String] = []
    @State private var selectedWords: [String] = []
    @State private var pressedIndices: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: localizedString("security__mnemonic_confirm"), showBackButton: true)

            VStack(spacing: 0) {
                BodyMText(localizedString("security__mnemonic_confirm_tap"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 16)

                Spacer()

                WrappingHStack(spacing: 5) {
                    ForEach(0 ..< shuffledWords.count, id: \.self) { index in
                        WordButton(
                            word: shuffledWords[index],
                            isPressed: pressedIndices.contains(index),
                            onTap: {
                                handleWordPress(word: shuffledWords[index], index: index)
                            }
                        )
                    }
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(0 ..< mnemonic.count / 2, id: \.self) { index in
                            ConfirmWordView(
                                number: index + 1,
                                word: selectedWords.count > index ? selectedWords[index] : "",
                                correct: selectedWords.count > index && selectedWords[index] == mnemonic[index]
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(mnemonic.count / 2 ..< mnemonic.count, id: \.self) { index in
                            ConfirmWordView(
                                number: index + 1,
                                word: selectedWords.count > index ? selectedWords[index] : "",
                                correct: selectedWords.count > index && selectedWords[index] == mnemonic[index]
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical)
                .frame(maxWidth: .infinity)

                Spacer()

                HStack(alignment: .center, spacing: 16) {
                    CustomButton(
                        title: localizedString("common__continue"),
                        isDisabled: selectedWords != mnemonic,
                    ) {
                        if let passphrase, !passphrase.isEmpty {
                            navigationPath.append(.confirmPassphrase(passphrase: passphrase))
                        } else {
                            navigationPath.append(.reminder)
                        }
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
            if shuffledWords.isEmpty {
                shuffledWords = mnemonic.shuffled()
            }
        }
    }

    private func handleWordPress(word: String, index: Int) {
        if pressedIndices.contains(index) {
            // Only allow unselecting if it's the last incorrect word
            if let wordIndex = selectedWords.firstIndex(of: word),
               wordIndex == selectedWords.count - 1, // Must be the last word
               selectedWords[wordIndex] != mnemonic[wordIndex]
            {
                selectedWords.removeLast()
                pressedIndices.remove(index)
            }
        } else {
            // Only allow selecting if previous words are correct
            let nextPosition = selectedWords.count

            // Don't allow selection if we already have a wrong word
            if nextPosition > 0 && selectedWords[nextPosition - 1] != mnemonic[nextPosition - 1] {
                return
            }

            // Don't allow selection beyond mnemonic length
            if nextPosition >= mnemonic.count {
                return
            }

            // Add word to selection
            selectedWords.append(word)
            pressedIndices.insert(index)
        }
    }
}

struct WordButton: View {
    let word: String
    let isPressed: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(word)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(minWidth: 50)
                .background(isPressed ? Color.white32 : Color.white16)
                .cornerRadius(54)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ConfirmWordView: View {
    let number: Int
    let word: String
    let correct: Bool

    var body: some View {
        HStack(spacing: 0) {
            BodyMSBText("\(number).", textColor: .textSecondary)
            BodyMSBText(" \(word.isEmpty ? "" : word)", textColor: word.isEmpty ? .textSecondary : (correct ? .greenAccent : .redAccent))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
