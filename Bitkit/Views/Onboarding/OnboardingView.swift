import SwiftUI

struct OnboardingView: View {
    @State private var currentTab: Int
    
    init(initialTab: Int = 0) {
        _currentTab = State(initialValue: initialTab)
    }
    
    var body: some View {
        VStack {
            TabView(selection: $currentTab) {
                // Tab 1: Welcome
                OnboardingTab(
                    imageName: "keyring",
                    titleFirstLine: "FREEDOM",
                    titleSecondLine: "IN YOUR POCKET",
                    text: "Bitkit hands you the keys to manage your money. Spend now or save for later. The choice is yours.",
                    secondLineColor: .blue
                )
                .padding(.bottom, 30)
                .padding(.horizontal, 32)
                .tag(0)
                
                // Tab 2: Features
                OnboardingTab(
                    imageName: "lightning",
                    titleFirstLine: "INSTANT",
                    titleSecondLine: "PAYMENTS",
                    text: "Spend bitcoin faster than ever. Enjoy instant and cheap payments with friends, family, and merchants*.",
                    disclaimerText: "*Bitkit does not currently provide Lightning services in your country, but you can still connect to other nodes.", //TODO: check geoblock status
                    secondLineColor: .purple
                )
                .padding(.bottom, 30)
                .padding(.horizontal, 32)
                .tag(1)
                
                // Tab 3: Security
                OnboardingTab(
                    imageName: "spark",
                    titleFirstLine: "BITCOINERS,",
                    titleSecondLine: "BORDERLESS",
                    text: "Take charge of your digital life with portable profiles and payable contacts.",
                    secondLineColor: .yellow
                )
                .padding(.bottom, 30)
                .padding(.horizontal, 32)
                .tag(2)
                
                // Tab 4: Privacy
                OnboardingTab(
                    imageName: "shield",
                    titleFirstLine: "PRIVACY IS",
                    titleSecondLine: "NOT A CRIME",
                    text: "Swipe to hide your balance, enjoy more private payments, and protect your wallet by enabling security features.",
                    secondLineColor: .green
                )
                .padding(.bottom, 30)
                .padding(.horizontal, 32)
                .tag(3)
                
                // Tab 5: Get Started
                CreateWalletView()
                    .padding(.horizontal, 32)
                    .tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            
            // Page indicator dots
            HStack(spacing: 8) {
                ForEach(0..<5) { index in
                    Circle()
                        .fill(currentTab == index ? Color.primary : Color.secondary)
                        .frame(width: 7, height: 7)
                }
            }
            .opacity(currentTab == 4 ? 0 : 1)
            .offset(y: currentTab == 4 ? 20 : 0)
            .animation(.easeInOut(duration: 0.3), value: currentTab)
            .padding(.bottom)
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if currentTab == 4 {
                    NavigationLink("Advanced Setup") {
                        CreateWalletWithPassphraseView()
                    }
                } else {
                    Button("Skip") {
                        withAnimation {
                            currentTab = 4
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    OnboardingView()
}
