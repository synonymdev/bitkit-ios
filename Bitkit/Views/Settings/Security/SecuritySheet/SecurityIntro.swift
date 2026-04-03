import SwiftUI

struct SecurityIntro: View {
    @EnvironmentObject private var sheets: SheetViewModel
    @Binding var navigationPath: [SecurityRoute]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetIntro(
                navTitle: t("security__pin_security_header"),
                title: t("security__pin_security_title"),
                description: t("security__pin_security_text"),
                image: "shield-figure",
                continueText: t("security__pin_security_button"),
                cancelText: t("common__later"),
                accentColor: .greenAccent,
                testID: "SecureWallet",
                onCancel: {
                    sheets.hideSheet()
                },
                onContinue: {
                    navigationPath.append(.setupPin)
                }
            )
        }
    }
}

#Preview {
    SecurityIntro(navigationPath: .constant([.intro]))
        .environmentObject(SheetViewModel())
}
