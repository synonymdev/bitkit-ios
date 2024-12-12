import SwiftUI

struct IntroView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
                
            Image("logo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 279, alignment: .center)
                
            Spacer()
                
            VStack(alignment: .leading, spacing: 0) {
                Text("YOU CAN ₿")
                    .font(.system(size: 44, weight: .black))
                Text("THE CHANGE")
                    .font(.system(size: 44, weight: .black))
                    .foregroundColor(Color.brand)
                    
                Text("Use Bitkit to pay anyone, anywhere, any time, and spend your bitcoin on the things you value in life.")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
                
            HStack(spacing: 16) {
                NavigationLink(destination: OnboardingView()) {
                    Text("Get Started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .foregroundColor(.white)
                        .background(Color.gray)
                        .cornerRadius(30)
                }
                    
                NavigationLink(destination: WalletSetup()) {
                    Text("Skip Intro")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .foregroundColor(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 30)
                                .stroke(Color.gray, lineWidth: 1)
                        )
                        .cornerRadius(30)
                }
            }
        }
        .padding()
        .background(
            Image("figures")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
        )
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
    }
}

#Preview {
    NavigationView {
        IntroView()
    }
}
