import SwiftUI

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
    let action: (() async -> Void)?
    
    @State private var isLoading = false
    
    // Base initializer for optional action
    init(
        title: String,
        variant: Variant = .primary,
        size: Size = .large,
        icon: (any View)? = nil,
        isDisabled: Bool = false
    ) {
        self.title = title
        self.variant = variant
        self.size = size
        self.icon = icon.map { AnyView($0) }
        self.isDisabled = isDisabled
        self.action = nil
    }
    
    // Trailing closure initializer
    init(
        title: String,
        variant: Variant = .primary,
        size: Size = .large,
        icon: (any View)? = nil,
        isDisabled: Bool = false,
        action: @escaping () async -> Void
    ) {
        self.title = title
        self.variant = variant
        self.size = size
        self.icon = icon.map { AnyView($0) }
        self.isDisabled = isDisabled
        self.action = action
    }
    
    private var backgroundColor: Color {
        switch variant {
        case .primary:
            return .gray2
        case .secondary, .tertiary:
            return .clear
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
            return .white64
        }
    }
    
    private var borderColor: Color? {
        switch variant {
        case .primary:
            return nil
        case .secondary:
            return .gray2
        case .tertiary:
            return nil
        }
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
                    .frame(maxWidth: icon == nil ? .infinity : nil)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: size.height)
        .padding(.horizontal, size.horizontalPadding)
        .background(backgroundColor)
        .cornerRadius(size.cornerRadius)
        .overlay(
            Group {
                if let borderColor = borderColor {
                    RoundedRectangle(cornerRadius: size.cornerRadius)
                        .stroke(borderColor, lineWidth: 1)
                }
            }
        )
        .contentShape(Rectangle())
    }
}

#Preview {
    VStack(spacing: 20) {
        NavigationLink(destination: Text("Navigation Example")) {
            CustomButton(title: "Primary Button (Navigation)")
        }
        
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
