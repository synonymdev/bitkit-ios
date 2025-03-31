import SwiftUI

struct RectangleButton: View {
    let icon: AnyView
    let title: String
    let action: (() async -> Void)?
    let trailingContent: AnyView?
    let isDisabled: Bool

    @State private var isPressed = false
    @State private var isLoading = false

    init(
        icon: any View,
        title: String,
        trailingContent: (any View)? = nil,
        isDisabled: Bool = false,
        action: (() async -> Void)? = nil
    ) {
        self.icon = AnyView(icon)
        self.title = title
        self.trailingContent = trailingContent.map { AnyView($0) }
        self.isDisabled = isDisabled
        self.action = action
    }

    private var backgroundColor: Color {
        if isPressed {
            return .white.opacity(0.16)  // white16
        }
        return .white.opacity(0.1)  // white10
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
            .opacity(isDisabled ? 0.5 : 1)
        } else {
            buttonContent
                .opacity(isDisabled ? 0.5 : 1)
        }
    }

    private var buttonContent: some View {
        HStack(spacing: 16) {
            if !isLoading {
                icon
                    .frame(width: 24, height: 24)
            }

            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .frame(width: 24, height: 24)
            } else {
                Text(title)
                    .font(Fonts.bold(size: 17))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let trailingContent = trailingContent {
                trailingContent
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 80)
        .padding(.horizontal, 24)
        .background(backgroundColor)
        .cornerRadius(8)
        .contentShape(Rectangle())
    }
}

#Preview {
    VStack(spacing: 8) {
        RectangleButton(
            icon: Image(systemName: "bolt.fill")
                .foregroundColor(.yellow),
            title: "Lightning Network",
            trailingContent: Image(systemName: "chevron.right")
                .foregroundColor(.white.opacity(0.64))
        ) {
            print("Button tapped")
        }

        RectangleButton(
            icon: Image(systemName: "network")
                .foregroundColor(.blue),
            title: "On-chain Bitcoin",
            trailingContent: Image(systemName: "chevron.right")
                .foregroundColor(.white.opacity(0.64))
        ) {
            print("Button tapped")
        }

        RectangleButton(
            icon: Image(systemName: "creditcard")
                .foregroundColor(.green),
            title: "Buy Bitcoin",
            trailingContent: Image(systemName: "chevron.right")
                .foregroundColor(.white.opacity(0.64))
        ) {
            print("Button tapped")
        }
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
