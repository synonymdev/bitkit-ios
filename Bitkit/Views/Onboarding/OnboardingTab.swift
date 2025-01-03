import SwiftUI

struct OnboardingTab: View {
    let imageName: String
    let title: [TranslationPart]
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

            VStack(alignment: .leading, spacing: 0) {
                title.reduce(Text("")) { current, part in
                    current + Text(part.text.uppercased())
                        .font(.largeTitle)
                        .fontWeight(.black)
                        .foregroundColor(part.isAccent ? secondLineColor : .primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)

            // Text with conditional accent parts
            text.reduce(Text("")) { current, part in
                current + Text(part.text)
                    .foregroundColor(part.isAccent ? .primary : .secondary)
                    .fontWeight(part.isAccent ? .bold : .regular)
            }
            .font(.body)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)

            if let disclaimer = disclaimerText {
                Text(disclaimer)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 30)
    }
}

#Preview {
    OnboardingTab(
        imageName: "lock.shield",
        title: [
            TranslationPart(text: "Security ", isAccent: false),
            TranslationPart(text: "First", isAccent: true)
        ],
        text: [
            TranslationPart(text: "Your funds are secured with industry-leading encryption. ", isAccent: false),
            TranslationPart(text: "Keep them safe!", isAccent: true)
        ],
        disclaimerText: "*Some features may require additional setup",
        secondLineColor: .brand
    )
}
