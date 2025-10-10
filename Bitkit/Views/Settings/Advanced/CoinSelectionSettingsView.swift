import LDKNode
import SwiftUI

extension CoinSelectionMethod {
    var localizedTitle: String {
        switch self {
        case .manual:
            return t("settings__adv__cs_manual")
        case .autopilot:
            return t("settings__adv__cs_auto")
        }
    }
}

extension CoinSelectionAlgorithm {
    var localizedTitle: String {
        switch self {
        case .branchAndBound:
            return "Branch and Bound" // TODO: add missing localized text
        case .largestFirst:
            return t("settings__adv__cs_min")
        case .oldestFirst:
            return t("settings__adv__cs_first_in_first_out")
        case .singleRandomDraw:
            return "Single Random Draw" // TODO: add missing localized text
            // Commented out unsupported algorithms
            // case .smallestFirst:
            //     return t("settings__adv__cs_max")
            // case .consolidate:
            //     return t("settings__adv__cs_consolidate")
        }
    }

    var localizedDescription: String {
        switch self {
        case .branchAndBound:
            return "Finds exact amount matches to minimize change" // TODO: add missing localized text
        case .largestFirst:
            return t("settings__adv__cs_min_description")
        case .oldestFirst:
            return t("settings__adv__cs_first_in_first_out_description")
        case .singleRandomDraw:
            return "Random selection for privacy" // TODO: add missing localized text
            // Commented out unsupported algorithms
            // case .smallestFirst:
            //     return t("settings__adv__cs_max_description")
            // case .consolidate:
            //     return t("settings__adv__cs_consolidate_description")
        }
    }

    // Only return supported algorithms from the test
    static var supportedAlgorithms: [CoinSelectionAlgorithm] {
        return [.branchAndBound, .largestFirst, .oldestFirst, .singleRandomDraw]
    }
}

struct CoinSelectionMethodOption: View {
    let method: CoinSelectionMethod
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                BodyMText(method.localizedTitle, textColor: .textPrimary)
                Spacer()
                if isSelected {
                    Image("checkmark")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .foregroundColor(.brandAccent)
                }
            }
            .frame(height: 51)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct CoinSelectionAlgorithmOption: View {
    let algorithm: CoinSelectionAlgorithm
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    BodyMText(algorithm.localizedTitle, textColor: .textPrimary)
                    Spacer()
                    if isSelected {
                        Image("checkmark")
                            .resizable()
                            .frame(width: 32, height: 32)
                            .foregroundColor(.brandAccent)
                    }
                }
                .frame(height: 51)

                BodySText(algorithm.localizedDescription)
                    .multilineTextAlignment(.leading)
                    .padding(.bottom, 16)

                Divider()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct CoinSelectionSettingsView: View {
    @StateObject private var settingsViewModel = SettingsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__adv__coin_selection"))
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // COIN SELECTION METHOD Section
                    VStack(alignment: .leading, spacing: 0) {
                        CaptionMText(t("settings__adv__cs_method"))
                            .padding(.bottom, 8)

                        VStack(spacing: 0) {
                            ForEach(CoinSelectionMethod.allCases, id: \.self) { method in
                                VStack(spacing: 0) {
                                    CoinSelectionMethodOption(
                                        method: method,
                                        isSelected: settingsViewModel.coinSelectionMethod == method
                                    ) {
                                        settingsViewModel.coinSelectionMethod = method
                                    }

                                    if method != CoinSelectionMethod.allCases.last {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }

                    // AUTOPILOT MODE Section (only show if Autopilot is selected)
                    if settingsViewModel.coinSelectionMethod == .autopilot {
                        VStack(alignment: .leading, spacing: 0) {
                            CaptionMText(t("settings__adv__cs_auto_mode"))
                                .padding(.top, 24)
                                .padding(.bottom, 8)

                            VStack(spacing: 0) {
                                ForEach(CoinSelectionAlgorithm.supportedAlgorithms, id: \.self) { algorithm in
                                    VStack {
                                        CoinSelectionAlgorithmOption(
                                            algorithm: algorithm,
                                            isSelected: settingsViewModel.coinSelectionAlgorithm == algorithm
                                        ) {
                                            settingsViewModel.coinSelectionAlgorithm = algorithm
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Add spacing at the bottom
                    Spacer()
                        .frame(height: 32)
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationStack {
        CoinSelectionSettingsView()
    }
    .preferredColorScheme(.dark)
}
