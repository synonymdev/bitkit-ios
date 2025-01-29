import SwiftUI

struct OnboardingTab: View {
    let imageName: String
    let title: String
    let text: String
    var disclaimerText: String? = nil
    let accentColor: Color

    var body: some View {
        VStack {
            Spacer()

            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 311, maxHeight: 311)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer()

            DisplayText(title, accentColor: accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)

            BodyMText(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)

            if let disclaimer = disclaimerText {
                CaptionText(disclaimer)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 30)
    }
}
