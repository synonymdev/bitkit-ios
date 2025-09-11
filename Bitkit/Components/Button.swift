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
    }

    let title: String
    let variant: Variant
    let size: Size
    let icon: AnyView?
    let isDisabled: Bool
    let isLoading: Bool
    let shouldExpand: Bool
    let action: (() async -> Void)?
    let destination: AnyView?

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
        action = nil
        destination = nil
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
        destination = nil
    }

    // Navigation link initializer
    init(
        title: String,
        variant: Variant = .primary,
        size: Size = .large,
        icon: (any View)? = nil,
        isDisabled: Bool = false,
        isLoading: Bool = false,
        shouldExpand: Bool = false,
        destination: some View
    ) {
        self.title = title
        self.variant = variant
        self.size = size
        self.icon = icon.map { AnyView($0) }
        self.isDisabled = isDisabled
        self.isLoading = isLoading
        self.shouldExpand = shouldExpand
        action = nil
        self.destination = AnyView(destination)
    }

    private var buttonVariantView: some View {
        switch variant {
        case .primary:
            AnyView(PrimaryButtonView(
                title: title,
                size: size,
                icon: icon,
                isDisabled: isDisabled,
                isLoading: isLoading,
                isPressed: isPressed,
                shouldExpand: shouldExpand
            ))
        case .secondary:
            AnyView(SecondaryButtonView(
                title: title,
                size: size,
                icon: icon,
                isDisabled: isDisabled,
                isPressed: isPressed
            ))
        case .tertiary:
            AnyView(TertiaryButtonView(
                title: title,
                icon: icon,
                isPressed: isPressed
            ))
        }
    }

    var body: some View {
        Group {
            if let destination {
                NavigationLink(destination: destination) {
                    buttonVariantView
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
                    }
                )
            } else if let action {
                Button {
                    guard !isLoading, !isDisabled else { return }

                    Haptics.play(.buttonTap)

                    Task { @MainActor in
                        await action()
                    }
                } label: {
                    buttonVariantView
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
                buttonVariantView
                    .opacity(isDisabled ? 0.5 : 1)
            }
        }
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
