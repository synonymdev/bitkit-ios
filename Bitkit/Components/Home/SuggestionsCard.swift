import SwiftUI

struct SuggestionCard: View {
    let data: SuggestionCardData
    var onDismiss: () -> Void = {}

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                Image(data.imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 80)

                Text(data.title)
                    .font(.custom(Fonts.black, size: 20))
                    .lineLimit(1)
                    .kerning(-0.5)
                    .textCase(.uppercase)
                    .padding(.top, 4)

                CaptionBText(data.description)
            }
            .padding()
            .frame(width: 152, height: 152, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: data.color, location: 0.0),
                                .init(color: Color.black.opacity(0.1), location: 0.9),
                                .init(color: Color.black, location: 1.0),
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )

            Button(action: onDismiss) {
                Image("x-mark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(.textSecondary)
                    .frame(width: 16, height: 16)
                    .padding(8)
            }
            .padding(8)
            .accessibilityIdentifier("SuggestionDismiss")
            .accessibility(label: Text("Dismiss \(data.title)"))
        }
    }
}
