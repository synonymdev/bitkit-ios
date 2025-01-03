import SwiftUI

struct OnboardingTab: View {
    let imageName: String
    let titleFirstLine: String
    let titleSecondLine: String
    let text: String
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
                Text(titleFirstLine.uppercased())
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundColor(.primary) +
                Text(titleSecondLine.uppercased())
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundColor(secondLineColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)

            Text(text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .foregroundColor(.secondary)
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
        titleFirstLine: "Security",
        titleSecondLine: "First",
        text: "Your funds are secured with industry-leading encryption",
        disclaimerText: "*Some features may require additional setup",
        secondLineColor: .brand
    )
}
