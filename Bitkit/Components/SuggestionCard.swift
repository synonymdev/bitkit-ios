import SwiftUI

/// Shared gradient tile used by suggestions widget and shop discover
struct SuggestionCard: View {
    let title: String
    let description: String
    let imageName: String
    let accentColor: Color
    let onTap: () -> Void
    let onDismiss: (() -> Void)?

    init(
        title: String,
        description: String,
        imageName: String,
        accentColor: Color,
        onTap: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.title = title
        self.description = description
        self.imageName = imageName
        self.accentColor = accentColor
        self.onTap = onTap
        self.onDismiss = onDismiss
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer()

                    Image(imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text(title)
                        .font(.custom(Fonts.black, size: 20))
                        .lineLimit(1)
                        .kerning(-0.5)
                        .textCase(.uppercase)
                        .padding(.top, 4)

                    CaptionBText(description)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: accentColor, location: 0.0),
                                    .init(color: Color.black.opacity(0.1), location: 0.9),
                                    .init(color: Color.black, location: 1.0),
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
            }
            .buttonStyle(.plain)
            .zIndex(0)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image("x-mark")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(.textSecondary)
                        .frame(width: 16, height: 16)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .padding(8)
                .contentShape(Rectangle())
                .accessibilityIdentifier("SuggestionDismiss")
                .accessibility(label: Text("Dismiss \(title)"))
                .buttonStyle(.plain)
                .zIndex(1)
            }
        }
    }
}
