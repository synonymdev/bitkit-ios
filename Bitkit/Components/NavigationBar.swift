import SwiftUI

struct NavigationBar: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    let title: String
    let showBackButton: Bool
    let showMenuButton: Bool
    let action: AnyView?
    let icon: String?
    let onBack: (() -> Void)?

    init(
        title: String,
        showBackButton: Bool = true,
        showMenuButton: Bool = true,
        action: AnyView? = nil,
        icon: String? = nil,
        onBack: (() -> Void)? = nil
    ) {
        self.title = title
        self.showBackButton = showBackButton
        self.showMenuButton = showMenuButton
        self.action = action
        self.icon = icon
        self.onBack = onBack
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if showBackButton {
                Button(action: {
                    if let onBack {
                        onBack()
                    } else {
                        // Default behavior for main navigation stack
                        if navigation.canGoBack {
                            navigation.navigateBack()
                        } else {
                            navigation.reset()
                        }
                    }
                }) {
                    Image("arrow-left")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.textPrimary)
                        .frame(width: 24, height: 24)
                }
            } else {
                Spacer()
                    .frame(width: 24, height: 24)
            }

            HStack(alignment: .center, spacing: 0) {
                if let icon {
                    Image(icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .padding(.trailing, 16)
                }

                TitleText(title)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            if let action {
                action
            } else if showMenuButton {
                Button {
                    withAnimation {
                        app.showDrawer = true
                    }
                } label: {
                    Image("burger")
                        .resizable()
                        .foregroundColor(.textPrimary)
                        .frame(width: 24, height: 24)
                }
                .frame(width: 32, height: 32)
                .offset(x: 6)
                .accessibilityIdentifier("HeaderMenu")
            } else {
                Spacer()
                    .frame(width: 24, height: 24)
            }
        }
        .frame(height: 48)
    }
}
