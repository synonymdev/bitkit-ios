import SwiftUI

/// Reusable expandable section for the Trezor dashboard.
/// Provides a tappable header with animated expand/collapse of content.
struct TrezorExpandableSection<Content: View>: View {
    let title: String
    let icon: String
    let description: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            // Tappable header
            Button(action: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 16) {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)

                        Text(description)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .animation(.easeInOut(duration: 0.25), value: isExpanded)
                }
            }

            // Expandable content
            if isExpanded {
                Divider()
                    .background(Color.white.opacity(0.1))
                    .padding(.top, 12)

                content()
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
