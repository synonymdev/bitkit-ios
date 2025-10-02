import SwiftUI

struct NotificationPreview: View {
    var disabled: Bool
    var enableAmount: Bool

    var amountText: String {
        if enableAmount {
            return "₿ 21 000 ($21.00)"
        } else {
            return t("settings__notifications__settings__preview__text")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image("app-icon")
                .resizable()
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(t("settings__notifications__settings__preview__title"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(hex: 0x222222))
                    Spacer()
                    Text(t("settings__notifications__settings__preview__time"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(hex: 0x3F3F3F).opacity(0.5))
                }

                Text(amountText)
                    .font(.system(size: 15))
                    .foregroundColor(Color(hex: 0x3F3F3F))
            }
        }
        .padding(9)
        .background(Color.white80)
        .cornerRadius(16)
        .overlay(disabled ? Color.black.opacity(0.7) : Color.clear)
    }
}
