import SwiftUI

struct NavigationBar: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @Environment(\.dismiss) var dismiss

    let title: String
    let showBackButton: Bool
    let action: AnyView?
    let icon: String?

    init(title: String, showBackButton: Bool = true, action: AnyView? = nil, icon: String? = nil) {
        self.title = title
        self.showBackButton = showBackButton
        self.action = action
        self.icon = icon
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if showBackButton {
                Button(action: {
                    if navigation.canGoBack {
                        navigation.navigateBack()
                    } else {
                        navigation.reset()
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
            } else {
                // Spacer()
                //     .frame(width: 24, height: 24)

                Button {
                    withAnimation {
                        app.showDrawer = true
                    }
                } label: {
                    Image("burger")
                }
            }
        }
        .frame(height: 48)
        // .background(Color.gray3)
        .offset(y: -5)
        // .padding(.horizontal, 14)
        // .padding(.bottom, 16)
    }
}
