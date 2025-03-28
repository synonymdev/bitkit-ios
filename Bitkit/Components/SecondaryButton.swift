import SwiftUI

struct SecondaryButton: View {
    enum Size {
        case small
        case large

        var height: CGFloat {
            switch self {
            case .small: return 40
            case .large: return 56
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .small: return 16
            case .large: return 28
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .small: return 30
            case .large: return 64
            }
        }
    }

    let title: String
    let size: Size
    let icon: AnyView?
    let isDisabled: Bool
    let action: (() async -> Void)?

    @State private var isLoading = false

    // Base initializer for optional action
    init(
        title: String,
        size: Size = .large,
        icon: (any View)? = nil,
        isDisabled: Bool = false
    ) {
        self.title = title
        self.size = size
        self.icon = icon.map { AnyView($0) }
        self.isDisabled = isDisabled
        action = nil
    }

    // Trailing closure initializer
    init(
        title: String,
        size: Size = .large,
        icon: (any View)? = nil,
        isDisabled: Bool = false,
        action: @escaping () async -> Void
    ) {
        self.title = title
        self.size = size
        self.icon = icon.map { AnyView($0) }
        self.isDisabled = isDisabled
        self.action = action
    }

    private var foregroundColor: Color {
        isDisabled ? .white32 : .white80
    }

    var body: some View {
        if let action = action {
            Button {
                guard !isLoading, !isDisabled else { return }

                // Play haptic feedback
                Haptics.play(.medium)

                Task { @MainActor in
                    isLoading = true
                    await action()
                    isLoading = false
                }
            } label: {
                buttonContent
            }
            .disabled(isDisabled || isLoading)
            .opacity(isDisabled || isLoading ? 0.5 : 1)
        } else {
            buttonContent
                .opacity(isDisabled ? 0.5 : 1)
        }
    }

    private var buttonContent: some View {
        HStack(spacing: 8) {
            if let icon = icon, !isLoading {
                icon
            }

            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: foregroundColor))
                    .frame(width: 20, height: 20)
            } else {
                Text(title)
                    .font(Fonts.bold(size: 17))
                    .foregroundColor(foregroundColor)
                    .lineLimit(1)
                    .frame(maxWidth: size == .large && icon == nil ? .infinity : nil)
            }
        }
        .frame(maxWidth: size == .large ? .infinity : nil)
        .frame(height: size.height)
        .padding(.horizontal, size.horizontalPadding)
        .background(
            BlurEffect(style: .dark)
                .opacity(0.1)
        )
        .cornerRadius(size.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: size.cornerRadius)
                .stroke(Color.white16, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

struct BlurEffect: UIViewRepresentable {
    var style: UIBlurEffect.Style

    func makeUIView(context _: Context) -> UIVisualEffectView {
        return UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context _: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

#Preview {
    VStack(spacing: 20) {
        SecondaryButton(title: "Transfer To Spending") {
            print("Button tapped")
        }

        SecondaryButton(
            title: "With Icon",
            icon: Image(systemName: "arrow.up.arrow.down")
                .foregroundColor(.white80)
        ) {
            print("Button tapped")
        }

        SecondaryButton(
            title: "Small Button",
            size: .small,
            icon: Image(systemName: "arrow.up.arrow.down")
                .foregroundColor(.white80)
        ) {
            print("Button tapped")
        }

        SecondaryButton(title: "Disabled Button", isDisabled: true) {
            print("Button tapped")
        }
    }
    .padding()
    .background(.black)
    .preferredColorScheme(.dark)
}
