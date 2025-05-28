//
//  SettingsListLabel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

enum SettingsListRightIcon {
    case rightArrow
    case checkmark
}

struct SettingsListIcon: View {
    let imageName: String
    let iconColor: Color

    init(_ imageName: String, iconColor: Color = .white) {
        self.imageName = imageName
        self.iconColor = iconColor
    }

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .foregroundColor(iconColor)
            .frame(width: 14, height: 14)
            .background(
                Circle()
                    .fill(Color.white10)
                    .frame(width: 32, height: 32)
            )
    }
}

struct SettingsListLabel: View {
    let title: String
    let iconName: String?
    let iconColor: Color
    let rightText: String?
    let rightIcon: SettingsListRightIcon?

    init(
        title: String, iconName: String? = nil, iconColor: Color = .white,
        rightText: String? = nil, rightIcon: SettingsListRightIcon? = .rightArrow
    ) {
        self.title = title
        self.iconName = iconName
        self.iconColor = iconColor
        self.rightText = rightText
        self.rightIcon = rightIcon
    }

    var body: some View {
        VStack {
            HStack {
                if let iconName = iconName {
                    Label {
                        BodyMText(title, textColor: .textPrimary)
                    } icon: {
                        SettingsListIcon(iconName, iconColor: iconColor)
                            .padding(.trailing, 12)
                    }
                } else {
                    BodyMText(title, textColor: .textPrimary)
                }

                Spacer()

                if let rightText = rightText {
                    BodyMText(rightText, textColor: .textPrimary, textAlignment: .right)
                        .padding(.trailing, 8)
                }

                if let rightIcon = rightIcon {
                    switch rightIcon {
                    case .rightArrow:
                        Image("arrow-right")
                            .foregroundColor(.textSecondary)
                    case .checkmark:
                        Image("checkmark")
                            .foregroundColor(.brandAccent)
                    }
                }
            }
            .padding(.vertical, 8)
            Divider()
        }
        .padding(.horizontal, 16)
    }
}
