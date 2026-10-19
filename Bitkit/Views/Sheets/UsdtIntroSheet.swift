import SwiftUI

struct UsdtIntroSheetItem: SheetItem {
    let id: SheetID = .usdtIntro
    let size: SheetSize = .large
}

struct UsdtIntroSheet: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(UsdtWalletManager.self) private var usdt
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    let config: UsdtIntroSheetItem

    var body: some View {
        Sheet(id: .usdtIntro, data: config, backgroundColor: .gray7, applyGradient: false) {
            UsdtIntroContent(onDecline: {
                if !usdt.hasProtectedFunds { settings.usdtPreference = .disabled }
                sheets.hideSheet()
            }, onEnable: {
                settings.usdtPreference = .enabled
                sheets.hideSheet()
            })
        }
        .task(id: scenePhase) {
            if scenePhase == .active { settings.hasSeenUsdtIntro = true }
        }
    }
}

struct UsdtIntroContent: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var isEnablePrompt = false
    let onDecline: () -> Void
    let onEnable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t(isEnablePrompt ? "usdt__enable" : "usdt__intro_title"), topPadding: 28, bottomPadding: 22,
                        dragIndicatorTopPadding: 8, titleKerning: 0)
            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 32) {
                        UsdtCoinIllustration().frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 8) {
                            DisplayText(t("usdt__intro_headline"), accentColor: .usdtAccent, kerning: -2)
                            BodyMText(t("usdt__intro_description"), textColor: .textSecondary, kerning: 0, lineHeight: 22)
                        }
                    }
                    .frame(minHeight: geometry.size.height, alignment: .bottom)
                }
            }
            let buttonLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 16))
                : AnyLayout(HStackLayout(spacing: 16))
            buttonLayout {
                CustomButton(title: t(isEnablePrompt ? "common__cancel" : "usdt__no_thanks"), variant: .secondary, shouldExpand: true,
                             titleKerning: 0, titleLineHeight: 20, action: onDecline)
                    .accessibilityIdentifier(isEnablePrompt ? "UsdtEnablePromptCancel" : "UsdtIntroDecline")
                CustomButton(title: t("usdt__enable"), shouldExpand: true, titleKerning: 0, titleLineHeight: 20, action: onEnable)
                    .accessibilityIdentifier(isEnablePrompt ? "UsdtEnablePromptContinue" : "UsdtIntroEnable")
            }
            .padding(.top, 32)
        }
        .padding(.horizontal, 16)
        .background(Color.gray7)
        .preference(key: SheetBackgroundPreferenceKey.self, value: .gray7)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isEnablePrompt ? "UsdtEnablePrompt" : "UsdtIntro")
    }
}
