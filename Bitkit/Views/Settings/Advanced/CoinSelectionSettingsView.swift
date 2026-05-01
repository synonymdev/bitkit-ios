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
            return t("settings__adv__cs_branch_and_bound")
        case .largestFirst:
            return t("settings__adv__cs_min")
        case .oldestFirst:
            return t("settings__adv__cs_first_in_first_out")
        case .singleRandomDraw:
            return t("settings__adv__cs_single_random_draw")
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
            return t("settings__adv__cs_branch_and_bound_description")
        case .largestFirst:
            return t("settings__adv__cs_min_description")
        case .oldestFirst:
            return t("settings__adv__cs_first_in_first_out_description")
        case .singleRandomDraw:
            return t("settings__adv__cs_single_random_draw_description")
            // Commented out unsupported algorithms
            // case .smallestFirst:
            //     return t("settings__adv__cs_max_description")
            // case .consolidate:
            //     return t("settings__adv__cs_consolidate_description")
        }
    }

    /// Only return supported algorithms from the test
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
                    Image("check-mark")
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
                        Image("check-mark")
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
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__adv__coin_selection"))

            ScrollView(showsIndicators: false) {
                VStack(spacing: 32) {
                    // COIN SELECTION METHOD Section
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsSectionHeader(t("settings__adv__cs_method"))

                        VStack(spacing: 0) {
                            ForEach(CoinSelectionMethod.allCases, id: \.self) { method in
                                VStack(spacing: 0) {
                                    CoinSelectionMethodOption(
                                        method: method,
                                        isSelected: settingsViewModel.coinSelectionMethod == method
                                    ) {
                                        settingsViewModel.coinSelectionMethod = method
                                    }

                                    CustomDivider()
                                }
                            }
                        }
                    }

                    // AUTOPILOT MODE Section (only show if Autopilot is selected)
                    if settingsViewModel.coinSelectionMethod == .autopilot {
                        VStack(alignment: .leading, spacing: 0) {
                            SettingsSectionHeader(t("settings__adv__cs_auto_mode"))

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
                }
                .padding(.horizontal, 16)
                .bottomSafeAreaPadding()
            }
        }
        .navigationBarHidden(true)
    }
}

#Preview {
    NavigationStack {
        CoinSelectionSettingsView()
    }
    .preferredColorScheme(.dark)
}
