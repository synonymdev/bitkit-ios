import SwiftUI

/// Section header for settings screens
struct SettingsSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        CaptionMText(title)
            .frame(height: 50)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

enum SettingsRowRightIcon {
    case chevron
    case checkmark
}

struct SettingsRow: View {
    let title: String
    let iconName: String?
    let iconColor: Color?
    let rightText: String?
    let rightIcon: SettingsRowRightIcon?
    let toggle: Binding<Bool>?
    let disabled: Bool?
    let testIdentifier: String?

    init(
        title: String,
        iconName: String? = nil,
        iconColor: Color? = .brandAccent,
        rightText: String? = nil,
        rightIcon: SettingsRowRightIcon? = .chevron,
        toggle: Binding<Bool>? = nil,
        disabled: Bool? = nil,
        testIdentifier: String? = nil
    ) {
        self.title = title
        self.iconName = iconName
        self.iconColor = iconColor
        self.rightText = rightText
        self.rightIcon = rightIcon
        self.toggle = toggle
        self.disabled = disabled
        self.testIdentifier = testIdentifier
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                if let iconName {
                    CircularIcon(icon: iconName, iconColor: iconColor ?? .brandAccent, backgroundColor: .black)
                        .padding(.trailing, 8)
                }

                BodyMText(title, textColor: .textPrimary)

                Spacer()

                if let toggle {
                    Toggle("", isOn: toggle)
                        .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
                        .labelsHidden()
                        .disabled(disabled ?? false)
                        .accessibilityIdentifierIfPresent(testIdentifier)

                } else {
                    if let rightText {
                        BodyMText(rightText, textColor: .textSecondary)
                            .padding(.trailing, 5)
                            .accessibilityIdentifier("Value")
                    }

                    if let rightIcon {
                        switch rightIcon {
                        case .chevron:
                            Image("chevron")
                                .resizable()
                                .foregroundColor(.textSecondary)
                                .frame(width: 24, height: 24)
                        case .checkmark:
                            Image("check-mark")
                                .resizable()
                                .foregroundColor(.brandAccent)
                                .frame(width: 32, height: 32)
                        }
                    }
                }
            }
            .frame(height: 50)

            CustomDivider()
        }
    }
}
