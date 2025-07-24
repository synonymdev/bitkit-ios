import SwiftUI

struct PressEventsModifier: ViewModifier {
    var onPress: () -> Void
    var onRelease: () -> Void

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        onPress()
                    }
                    .onEnded { _ in
                        onRelease()
                    }
            )
    }
}

extension View {
    func pressEvents(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        modifier(PressEventsModifier(onPress: onPress, onRelease: onRelease))
    }
}

struct CustomButtonStyle: ButtonStyle {
    let variant: CustomButton.Variant
    let isDisabled: Bool
    let isLoading: Bool
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { pressed in
                isPressed = pressed
            }
    }
}

struct CustomButton: View {
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
            case .small: return 12
            case .large: return 16
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .small: return 30
            case .large: return 64
            }
        }
    }

    enum Variant {
        case primary
        case secondary
        case tertiary
        case accent
    }

    let title: String
    let variant: Variant
    let size: Size
    let icon: AnyView?
    let isDisabled: Bool
    let shouldExpand: Bool
    let action: (() async -> Void)?
    let destination: AnyView?

    @State private var isLoading = false
    @State private var isPressed = false

    // Base initializer for optional action
    init(
        title: String,
        variant: Variant = .primary,
        size: Size = .large,
        icon: (any View)? = nil,
        isDisabled: Bool = false,
        isLoading: Bool = false,
        shouldExpand: Bool = false
    ) {
        self.title = title
        self.variant = variant
        self.size = size
        self.icon = icon.map { AnyView($0) }
        self.isDisabled = isDisabled
        self.isLoading = isLoading
        self.shouldExpand = shouldExpand
        self.action = nil
        self.destination = nil
    }

    // Trailing closure initializer
    init(
        title: String,
        variant: Variant = .primary,
        size: Size = .large,
        icon: (any View)? = nil,
        isDisabled: Bool = false,
        isLoading: Bool = false,
        shouldExpand: Bool = false,
        action: @escaping () async -> Void
    ) {
        self.title = title
        self.variant = variant
        self.size = size
        self.icon = icon.map { AnyView($0) }
        self.isDisabled = isDisabled
        self.isLoading = isLoading
        self.shouldExpand = shouldExpand
        self.action = action
        self.destination = nil
    }

    // Navigation link initializer
    init<D: View>(
        title: String,
        variant: Variant = .primary,
        size: Size = .large,
        icon: (any View)? = nil,
        isDisabled: Bool = false,
        isLoading: Bool = false,
        shouldExpand: Bool = false,
        destination: D
    ) {
        self.title = title
        self.variant = variant
        self.size = size
        self.icon = icon.map { AnyView($0) }
        self.isDisabled = isDisabled
        self.isLoading = isLoading
        self.shouldExpand = shouldExpand
        self.action = nil
        self.destination = AnyView(destination)
    }

    private var backgroundColor: Color {
        if isLoading {
            return .gray6
        }

        if isDisabled && icon != nil {
            return .white06
        }

        if isDisabled {
            return .clear
        }

        switch variant {
        case .primary:
            if isPressed {
                return .white32
            } else {
                return .white16
            }
        case .secondary, .tertiary:
            return .clear
        case .accent:
            if isPressed {
                return .brandAccent.opacity(0.8)
            } else {
                return .brandAccent
            }
        }
    }

    private var foregroundColor: Color {
        if isDisabled {
            return .white32
        }

        switch variant {
        case .primary:
            return .textPrimary
        case .secondary, .tertiary:
            if isPressed {
                return .textPrimary
            } else {
                return .white80
            }
        case .accent:
            return .white
        }
    }

    private var borderColor: Color? {
        if isDisabled {
            return nil
        }

        switch variant {
        case .primary:
            return nil
        case .secondary:
            if isPressed {
                return .white32
            } else {
                return .white16
            }
        case .tertiary:
            return nil
        case .accent:
            return nil
        }
    }

    var body: some View {
        Group {
            if let destination = destination {
                NavigationLink(destination: destination) {
                    buttonContent
                }
                .buttonStyle(
                    CustomButtonStyle(
                        variant: variant,
                        isDisabled: isDisabled,
                        isLoading: isLoading,
                        isPressed: $isPressed
                    )
                )
                .disabled(isDisabled)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        if !isDisabled {
                            Haptics.play(.buttonTap)
                        }
                    })
            } else if let action = action {
                Button {
                    guard !isLoading, !isDisabled else { return }

                    Haptics.play(.buttonTap)

                    Task { @MainActor in
                        isLoading = true
                        await action()
                        isLoading = false
                    }
                } label: {
                    buttonContent
                }
                .buttonStyle(
                    CustomButtonStyle(
                        variant: variant,
                        isDisabled: isDisabled,
                        isLoading: isLoading,
                        isPressed: $isPressed
                    )
                )
                .disabled(isDisabled || isLoading)
            } else {
                buttonContent
                    .opacity(isDisabled ? 0.5 : 1)
            }
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
                if size == .small {
                    CaptionBText(title, textColor: foregroundColor)
                } else {
                    BodySSBText(title, textColor: foregroundColor)
                }
            }
        }
        .frame(maxWidth: size == .large || shouldExpand ? .infinity : nil)
        .frame(height: size.height)
        .padding(.horizontal, size.horizontalPadding)
        .background(backgroundColor)
        .cornerRadius(size.cornerRadius)
        .overlay(
            Group {
                if let borderColor = borderColor {
                    RoundedRectangle(cornerRadius: size.cornerRadius)
                        .stroke(borderColor, lineWidth: 2)
                }
            }
        )
        .contentShape(Rectangle())
    }
}

// UIViewRepresentable for UIKit blur effect
struct BackdropBlurView: UIViewRepresentable {
    let radius: CGFloat

    func makeUIView(context: Context) -> UIVisualEffectView {
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: .systemUltraThinMaterial)
    }
}

#Preview {
    NavigationStack {
        VStack(spacing: 20) {
            CustomButton(
                title: "Primary Button (Navigation)",
                destination: Text("Navigation Example")
            )

            CustomButton(title: "Secondary Button", variant: .secondary) {
                print("Button tapped")
            }

            CustomButton(title: "Tertiary Button", variant: .tertiary) {
                print("Button tapped")
            }

            CustomButton(title: "Disabled Button", isDisabled: true) {
                print("Button tapped")
            }

            CustomButton(title: "Small Button", size: .small) {
                print("Button tapped")
            }

            CustomButton(
                title: "With Icon",
                icon: Image(systemName: "lock.shield")
                    .foregroundColor(.textPrimary)
            ) {
                print("Button tapped")
            }
        }
        .padding()
        .background(Color.gray6)
        .preferredColorScheme(.dark)
    }
}
