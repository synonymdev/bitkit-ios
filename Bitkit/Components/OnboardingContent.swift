import SwiftUI

struct OnboardingContent: View {
    let imageName: String
    let title: String
    let text: String
    let accentColor: Color

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(imageName)
                .resizable()
                .scaledToFit()
                // TODO: avoid image being squished when keyboard is open
                .frame(maxWidth: 311, maxHeight: 311)
                .padding(.bottom, 32)

            DisplayText(title, accentColor: accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                // TODO: fix line height and spacing
                .padding(.bottom, 2)

            BodyMText(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 32)
    }
}
