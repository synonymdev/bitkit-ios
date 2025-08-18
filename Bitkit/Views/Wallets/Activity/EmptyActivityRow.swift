import SwiftUI

struct EmptyActivityRow: View {
    var body: some View {
        HStack(spacing: 16) {
            CircularIcon(
                icon: "activity",
                iconColor: .yellowAccent,
                backgroundColor: .yellow16
            )

            VStack(alignment: .leading, spacing: 4) {
                BodyMSBText(t("wallet__activity_no"))
                CaptionBText(t("wallet__activity_no_explain"))
            }

            Spacer()
        }
    }
}

#Preview {
    EmptyActivityRow()
        .padding()
        .preferredColorScheme(.dark)
}
