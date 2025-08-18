import SwiftUI

struct NoAnimationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct TabBar: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @State private var scaleEffect: CGFloat = 1.0

    var shouldShow: Bool {
        if navigation.activeDrawerMenuItem == .wallet || navigation.activeDrawerMenuItem == .activity {
            if navigation.path.isEmpty {
                return true
            }

            switch navigation.currentRoute {
            case .activityList, .savingsWallet, .spendingWallet:
                return true
            default:
                return false
            }
        }

        return false
    }

    var body: some View {
        VStack {
            Spacer()
            if shouldShow {
                HStack {
                    Spacer()
                    Button(
                        action: {
                            onSendPress()
                        },
                        label: {
                            HStack(spacing: 4) {
                                Image("arrow-down")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 16)
                                    .rotationEffect(.degrees(180))
                                BodySSBText(t("wallet__send"))
                            }
                            .foregroundColor(.white)
                        }
                    )
                    Spacer()
                    Spacer()
                    Spacer()
                    Button(
                        action: {
                            onReceivePress()
                        },
                        label: {
                            HStack(spacing: 4) {
                                Image("arrow-down")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 16)
                                BodySSBText(t("wallet__receive"))
                            }
                            .foregroundColor(.white)
                        }
                    )
                    Spacer()
                }
                .frame(height: 56)
                .background(.regularMaterial)
                .cornerRadius(30)
                .overlay {
                    Button(
                        action: {
                            onScanPress()
                        },
                        label: {
                            Image("scan")
                                .resizable()
                                .frame(width: 46, height: 46)
                                .padding(24)
                                .frame(width: 80, height: 80)
                                .background(Circle().fill(Color.gray6))
                                .foregroundColor(.gray2)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.white10, lineWidth: 2)
                                )
                                .scaleEffect(scaleEffect)
                        }
                    )
                    .buttonStyle(NoAnimationButtonStyle())
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut, value: shouldShow)
        .ignoresSafeArea(.keyboard)
        .bottomSafeAreaPadding()
    }

    private func onSendPress() {
        // TODO: find a better place to reset send state
        app.resetSendState()
        sheets.showSheet(.send)
    }

    private func onReceivePress() {
        if navigation.currentRoute == .spendingWallet {
            sheets.showSheet(.receive, data: ReceiveConfig(view: .cjitAmount))
        } else {
            sheets.showSheet(.receive)
        }
    }

    private func onScanPress() {
        sheets.showSheet(.scanner)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            scaleEffect = 1.1
        }

        // Reset scale after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                scaleEffect = 1.0
            }
        }
    }
}

#Preview {
    VStack {
        Text("Hello, World!")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay {
        TabBar()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(SheetViewModel())
    }
    .preferredColorScheme(.dark)
}

#Preview {
    VStack {
        Text("Hello, World!")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay {
        TabBar()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(SheetViewModel())
    }
    .preferredColorScheme(.light)
}
