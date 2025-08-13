//
//  SettingsListLabel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

enum SettingsListRightIcon {
    case chevron
    case checkmark
}

struct SettingsListLabel: View {
    let title: String
    let iconName: String?
    let rightText: String?
    let rightIcon: SettingsListRightIcon?
    let toggle: Binding<Bool>?
    let disabled: Bool?

    init(
        title: String,
        iconName: String? = nil,
        rightText: String? = nil,
        rightIcon: SettingsListRightIcon? = .chevron,
        toggle: Binding<Bool>? = nil,
        disabled: Bool? = nil
    ) {
        self.title = title
        self.iconName = iconName
        self.rightText = rightText
        self.rightIcon = rightIcon
        self.toggle = toggle
        self.disabled = disabled
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                if let iconName = iconName {
                    Label {
                        BodyMText(title, textColor: .textPrimary)
                    } icon: {
                        CircularIcon(icon: iconName, iconColor: .textPrimary)
                            .padding(.trailing, 8)
                    }
                } else {
                    BodyMText(title, textColor: .textPrimary)
                }

                Spacer()

                if let toggle = toggle {
                    Toggle("", isOn: toggle)
                        .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
                        .labelsHidden()
                        .disabled(disabled ?? false)
                } else {
                    if let rightText = rightText {
                        BodyMText(rightText, textColor: .textPrimary)
                            .padding(.trailing, 5)
                    }

                    if let rightIcon = rightIcon {
                        switch rightIcon {
                        case .chevron:
                            Image("chevron")
                                .resizable()
                                .foregroundColor(.textSecondary)
                                .frame(width: 24, height: 24)
                        case .checkmark:
                            Image("checkmark")
                                .resizable()
                                .foregroundColor(.brandAccent)
                                .frame(width: 32, height: 32)
                        }
                    }
                }
            }
            .frame(height: 50)

            // Bottom border
            Rectangle()
                .fill(Color.white10)
                .frame(height: 1)
        }
    }
}
