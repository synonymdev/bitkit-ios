import SwiftUI

struct EmptyActivityRow: View {
    var body: some View {
        HStack(spacing: 16) {
            CircularIcon(
                icon: "heartbeat",
                iconColor: .yellowAccent,
                backgroundColor: .yellow16
            )

            VStack(alignment: .leading, spacing: 4) {
                BodyMSBText(localizedString("wallet__activity_no"))
                CaptionBText(localizedString("wallet__activity_no_explain"))
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
