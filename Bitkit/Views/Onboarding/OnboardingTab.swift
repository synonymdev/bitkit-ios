import SwiftUI

struct OnboardingTab: View {
    let imageName: String
    let title: String
    let text: [TranslationPart]
    var disclaimerText: String? = nil
    let secondLineColor: Color

    var body: some View {
        VStack {
            Spacer()

            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 311, maxHeight: 311)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer()

            DisplayText(text: title)
                .padding(.bottom, 4)

            // Text with conditional accent parts
            (text.reduce(Text("")) { current, part in
                current + Text(part.text)
                    .foregroundColor(part.isAccent ? .textPrimary : .textSecondary)
                    .fontWeight(part.isAccent ? .bold : .regular)
            })
            .bodyMTextStyle()
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)

            if let disclaimer = disclaimerText {
                Text(disclaimer)
                    .captionTextStyle(color: .textSecondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 30)
    }
}
