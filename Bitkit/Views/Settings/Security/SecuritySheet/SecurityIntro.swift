import SwiftUI

struct SecurityIntro: View {
    @EnvironmentObject private var sheets: SheetViewModel
    @Binding var navigationPath: [SecurityRoute]
    let showLaterButton: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetIntro(
                navTitle: localizedString("security__pin_security_header"),
                title: localizedString("security__pin_security_title"),
                description: localizedString("security__pin_security_text"),
                image: "shield",
                continueText: localizedString("security__pin_security_button"),
                cancelText: showLaterButton ? localizedString("common__later") : nil,
                accentColor: .greenAccent,
                testID: "SecureWallet",
                onCancel: {
                    sheets.hideSheet()
                },
                onContinue: {
                    navigationPath.append(.pin)
                }
            )
        }
    }
}

#Preview {
    SecurityIntro(navigationPath: .constant([.intro]), showLaterButton: true)
        .environmentObject(SheetViewModel())
}
