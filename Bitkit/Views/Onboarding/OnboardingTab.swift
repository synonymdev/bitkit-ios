import SwiftUI

struct OnboardingTab: View {
    let imageName: String
    let title: String
    let text: String
    var disclaimerText: String? = nil
    let accentColor: Color

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 311, maxHeight: 311)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(spacing: 0) {
                DisplayText(title, accentColor: accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)

                BodyMText(text)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let disclaimer = disclaimerText {
                    CaptionText(disclaimer)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 255, alignment: .top)
            .padding(.top, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
