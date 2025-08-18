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
                        .foregroundColor(.brandAccent)
                }
            }
            .padding(.vertical, 8)
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    BodyMText(algorithm.localizedTitle, textColor: .textPrimary)
                    Spacer()
                    if isSelected {
                        Image("checkmark")
                            .foregroundColor(.brandAccent)
                            .frame(width: 23, height: 16)
                    }
                }

                Divider()

                BodySText(
                    algorithm.localizedDescription,
                    textColor: .textSecondary
                )
                .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct CoinSelectionSettingsView: View {
    @StateObject private var settingsViewModel = SettingsViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // COIN SELECTION METHOD Section
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        BodyMText(
                            t("settings__adv__cs_method"),
                            textColor: .textSecondary
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                        .padding(.bottom, 8)
                        Spacer()
                    }

                    VStack(spacing: 0) {
                        ForEach(CoinSelectionMethod.allCases, id: \.self) { method in
                            VStack {
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
                            .padding(.horizontal, 16)
                        }
                    }
                }

                // AUTOPILOT MODE Section (only show if Autopilot is selected)
                if settingsViewModel.coinSelectionMethod == .autopilot {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            BodyMText(
                                t("settings__adv__cs_auto_mode"),
                                textColor: .textSecondary
                            )
                            .padding(.horizontal, 16)
                            .padding(.top, 24)
                            .padding(.bottom, 8)
                            Spacer()
                        }

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
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                }

                // Add spacing at the bottom
                Spacer()
                    .frame(height: 32)
            }
        }
        .navigationTitle(t("settings__adv__coin_selection"))
    }
}

#Preview {
    NavigationStack {
        CoinSelectionSettingsView()
    }
    .preferredColorScheme(.dark)
}
