import SwiftUI

struct SecurityIntro: View {
    @EnvironmentObject private var sheets: SheetViewModel
    @Binding var navigationPath: [SecurityRoute]
    let showLaterButton: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetIntro(
                navTitle: t("security__pin_security_header"),
                title: t("security__pin_security_title"),
                description: t("security__pin_security_text"),
                image: "shield-figure",
                continueText: t("security__pin_security_button"),
                cancelText: showLaterButton ? t("common__later") : nil,
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
