import SwiftUI

struct NfcIntroSheetItem: SheetItem {
    let id: SheetID = .nfcIntro
    let size: SheetSize = .large
}

/// Announces NFC payments once, after updating to a version that supports them.
struct NfcIntroSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    let config: NfcIntroSheetItem

    var body: some View {
        Sheet(id: .nfcIntro, data: config) {
            NfcIntroContent(
                isQuickpayEnabled: $settings.enableQuickpay,
                onSettings: onSettings,
                onContinue: onContinue
            )
        }
    }

    private func onSettings() {
        app.hasSeenNfcIntro = true
        sheets.hideSheet()
        navigation.navigate(app.hasSeenQuickpayIntro ? .quickpay : .quickpayIntro)
    }

    private func onContinue() {
        app.hasSeenNfcIntro = true
        sheets.hideSheet()
    }
}

struct NfcIntroContent: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var isQuickpayEnabled: Bool
    let onSettings: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("other__nfc_intro__nav_title"))

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Image("nfc")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 256, maxHeight: 256)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 32)

                        DisplayText(t("other__nfc_intro__title"), accentColor: .purpleAccent)
                            .padding(.bottom, 8)

                        BodyMText(t("other__nfc_intro__description"), textColor: .textSecondary)
                            .padding(.bottom, 16)

                        SettingsRow(
                            title: t("other__nfc_intro__quickpay_toggle"),
                            toggle: $isQuickpayEnabled,
                            testIdentifier: "NfcIntroQuickpayToggle"
                        )
                    }
                    .frame(minHeight: geometry.size.height, alignment: .bottom)
                }
            }

            let buttonLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 16))
                : AnyLayout(HStackLayout(spacing: 16))
            buttonLayout {
                CustomButton(title: t("other__nfc_intro__settings"), variant: .secondary, shouldExpand: true, action: onSettings)
                    .accessibilityIdentifier("NfcIntroSettings")
                CustomButton(title: t("other__nfc_intro__continue"), shouldExpand: true, action: onContinue)
                    .accessibilityIdentifier("NfcIntroContinue")
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NfcIntro")
    }
}

#Preview {
    NfcIntroContent(isQuickpayEnabled: .constant(true), onSettings: {}, onContinue: {})
        .preferredColorScheme(.dark)
}
