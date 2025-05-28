//
//  SettingsListLabel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct SettingsListIcon: View {
    let imageName: String
    let isSystemImage: Bool

    init(_ imageName: String, isSystemImage: Bool = false) {
        self.imageName = imageName
        self.isSystemImage = isSystemImage
    }

    var body: some View {
        Group {
            if isSystemImage {
                Image(systemName: imageName)
                    .padding(8)
            } else {
                Image(imageName)
            }
        }
        .foregroundColor(.white)
        .frame(width: 20, height: 20)
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
    let isSystemIcon: Bool

    init(title: String, iconName: String? = nil, isSystemIcon: Bool = false) {
        self.title = title
        self.iconName = iconName
        self.isSystemIcon = isSystemIcon
    }

    var body: some View {
        VStack {
            HStack {
                if let iconName = iconName {
                    Label {
                        BodyMText(title, textColor: .textPrimary)
                    } icon: {
                        SettingsListIcon(iconName, isSystemImage: isSystemIcon)
                            .padding(.trailing, 12)
                    }
                } else {
                    BodyMText(title, textColor: .textPrimary)
                }

                Spacer()

                Image("arrow-right")
                    .foregroundColor(.textSecondary)
            }
            .padding(.vertical, 8)
            Divider()
        }
        .padding(.horizontal, 16)
    }
}
