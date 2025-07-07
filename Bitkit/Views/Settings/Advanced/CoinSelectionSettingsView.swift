//
//  CoinSelectionSettingsView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2025/06/27.
//

import LDKNode
import SwiftUI

extension CoinSelectionMethod {
    var localizedTitle: String {
        switch self {
        case .manual:
            return NSLocalizedString("settings__adv__cs_manual", comment: "")
        case .autopilot:
            return NSLocalizedString("settings__adv__cs_auto", comment: "")
        }
    }
}

extension CoinSelectionAlgorithm {
    var localizedTitle: String {
        switch self {
        case .branchAndBound:
            return "Branch and Bound" // TODO: add missing localized text
        case .largestFirst:
            return NSLocalizedString("settings__adv__cs_min", comment: "")
        case .oldestFirst:
            return NSLocalizedString("settings__adv__cs_first_in_first_out", comment: "")
        case .singleRandomDraw:
            return "Single Random Draw" // TODO: add missing localized text
        // Commented out unsupported algorithms
        // case .smallestFirst:
        //     return NSLocalizedString("settings__adv__cs_max", comment: "")
        // case .consolidate:
        //     return NSLocalizedString("settings__adv__cs_consolidate", comment: "")
        }
    }

    var localizedDescription: String {
        switch self {
        case .branchAndBound:
            return "Finds exact amount matches to minimize change" // TODO: add missing localized text
        case .largestFirst:
            return NSLocalizedString("settings__adv__cs_min_description", comment: "")
        case .oldestFirst:
            return NSLocalizedString("settings__adv__cs_first_in_first_out_description", comment: "")
        case .singleRandomDraw:
            return "Random selection for privacy" // TODO: add missing localized text
        // Commented out unsupported algorithms
        // case .smallestFirst:
        //     return NSLocalizedString("settings__adv__cs_max_description", comment: "")
        // case .consolidate:
        //     return NSLocalizedString("settings__adv__cs_consolidate_description", comment: "")
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
                            NSLocalizedString("settings__adv__cs_method", comment: ""),
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
                                NSLocalizedString("settings__adv__cs_auto_mode", comment: ""),
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
        .navigationTitle(NSLocalizedString("settings__adv__coin_selection", comment: ""))
    }
}

#Preview {
    NavigationStack {
        CoinSelectionSettingsView()
    }
    .preferredColorScheme(.dark)
}
