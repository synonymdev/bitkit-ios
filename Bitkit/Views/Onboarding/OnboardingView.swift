import SwiftUI

struct OnboardingView: View {
    var body: some View {
        NavigationView {
            TermsView()
        }
        .navigationViewStyle(.stack)
    }
}

#Preview {
    OnboardingView()
}
