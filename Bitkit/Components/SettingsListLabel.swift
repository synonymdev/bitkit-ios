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
    let testIdentifier: String?

    init(
        title: String,
        iconName: String? = nil,
        rightText: String? = nil,
        rightIcon: SettingsListRightIcon? = .chevron,
        toggle: Binding<Bool>? = nil,
        disabled: Bool? = nil,
        testIdentifier: String? = nil
    ) {
        self.title = title
        self.iconName = iconName
        self.rightText = rightText
        self.rightIcon = rightIcon
        self.toggle = toggle
        self.disabled = disabled
        self.testIdentifier = testIdentifier
    }

    var body: some View {
        VStack(spacing: 0) {
            rowContent
                .frame(height: 50)

            Rectangle()
                .fill(Color.white10)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        let row = HStack(alignment: .center, spacing: 0) {
            if let iconName {
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

            if let toggle {
                if let testIdentifier {
                    Toggle("", isOn: toggle)
                        .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
                        .labelsHidden()
                        .disabled(disabled ?? false)
                        .accessibilityIdentifier(testIdentifier)
                } else {
                    Toggle("", isOn: toggle)
                        .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
                        .labelsHidden()
                        .disabled(disabled ?? false)
                }
            } else {
                if let rightText {
                    BodyMText(rightText, textColor: .textPrimary)
                        .padding(.trailing, 5)
                }

                if let rightIcon {
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

        if let testIdentifier, toggle == nil {
            row.accessibilityIdentifier(testIdentifier)
        } else {
            row
        }
    }
}
