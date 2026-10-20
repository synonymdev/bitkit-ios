import SwiftUI

enum SheetSize {
    case small, medium, large, calendar

    var height: CGFloat {
        let screenHeight = UIScreen.screenHeight
        let safeAreaInsets = windowSafeAreaInsets
        let headerHeight: CGFloat = 48
        let balanceHeight: CGFloat = 70
        let spacing: CGFloat = 16

        let headerSpacing = safeAreaInsets.top + headerHeight + spacing
        let balanceSpacing = headerSpacing + balanceHeight + spacing * 2

        switch self {
        case .small:
            return 400
        case .medium:
            let minHeight: CGFloat = 616
            // Header + Balance visible
            let preferredHeight = screenHeight - balanceSpacing
            if preferredHeight < minHeight {
                // Use large sheet size when medium is too small
                let largePreferredHeight = screenHeight - headerSpacing
                return max(minHeight, largePreferredHeight)
            }
            return preferredHeight
        case .calendar:
            let minHeight: CGFloat = 616
            // same as medium + 40px, to be just under search input
            let preferredHeight = screenHeight - balanceSpacing + 40
            if preferredHeight < minHeight {
                // Use large sheet size when it's too small
                let largePreferredHeight = screenHeight - headerSpacing
                return max(minHeight, largePreferredHeight)
            }
            return preferredHeight
        case .large:
            let minHeight: CGFloat = 616
            // Only Header visible
            let preferredHeight = screenHeight - headerSpacing
            return max(minHeight, preferredHeight)
        }
    }
}

struct SheetHeader: View {
    @Environment(\.dismiss) var dismiss
    let title: String
    let showBackButton: Bool
    let action: AnyView?
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let dragIndicatorTopPadding: CGFloat?
    let titleKerning: CGFloat
    let onBack: (() -> Void)?

    init(
        title: String,
        showBackButton: Bool = false,
        action: AnyView? = nil,
        topPadding: CGFloat = 32,
        bottomPadding: CGFloat = 24,
        dragIndicatorTopPadding: CGFloat? = nil,
        titleKerning: CGFloat = 0.4,
        onBack: (() -> Void)? = nil
    ) {
        self.title = title
        self.showBackButton = showBackButton
        self.action = action
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.dragIndicatorTopPadding = dragIndicatorTopPadding
        self.titleKerning = titleKerning
        self.onBack = onBack
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if showBackButton {
                Button(action: {
                    if let onBack {
                        onBack()
                    } else {
                        dismiss()
                    }
                }) {
                    Image("arrow-left")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.textPrimary)
                        .frame(width: 24, height: 24)
                }
                .accessibilityIdentifier("NavigationBack")
            } else {
                Spacer()
                    .frame(width: 24, height: 24)
            }

            SubtitleText(title, kerning: titleKerning)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)

            if let action {
                action
            } else {
                Spacer()
                    .frame(width: 24, height: 24)
            }
        }
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .preference(key: SheetDragIndicatorInsetPreferenceKey.self, value: dragIndicatorTopPadding)
    }
}

// MARK: - Generic Reusable Sheet Component

/// Base protocol that all sheet items should conform to
protocol SheetItem: Identifiable {
    var size: SheetSize { get }
}

struct Sheet<Content: View>: View {
    @EnvironmentObject private var sheets: SheetViewModel
    @State private var contentBackground: Color?
    @State private var contentDragIndicatorInset: CGFloat?
    let configuration: SheetConfiguration
    let backgroundColor: Color
    let applyGradient: Bool
    let dragIndicatorInset: CGFloat?
    let content: () -> Content

    init(
        id: SheetID,
        data: (any SheetItem)? = nil,
        backgroundColor: Color = .black,
        applyGradient: Bool = true,
        dragIndicatorInset: CGFloat? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        configuration = SheetConfiguration(id: id, data: data)
        self.backgroundColor = backgroundColor
        self.applyGradient = applyGradient
        self.dragIndicatorInset = dragIndicatorInset
        self.content = content
    }

    private var sheetSize: SheetSize {
        if let sheetItem = configuration.data as? (any SheetItem) {
            return sheetItem.size
        }
        return .medium // default
    }

    var body: some View {
        ZStack(alignment: .top) {
            content()
                .modifier(SheetBackgroundModifier(base: contentBackground ?? backgroundColor,
                                                  applyGradient: contentBackground == nil && applyGradient))
                .bottomSafeAreaPadding()

            // Custom drag indicator - always on top
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white32)
                .frame(width: 32, height: 4)
                .padding(.top, dragIndicatorInset ?? contentDragIndicatorInset ?? 12)
        }
        .onPreferenceChange(SheetBackgroundPreferenceKey.self) { contentBackground = $0 }
        .onPreferenceChange(SheetDragIndicatorInsetPreferenceKey.self) { contentDragIndicatorInset = $0 }
        .presentationBackgroundInteraction(.disabled)
        // The system adds the bottom safe area to a fixed-height detent.
        .presentationDetents([.height(sheetSize.height - windowSafeAreaInsets.bottom)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(32)
        .presentationBackground { contentBackground ?? backgroundColor }
    }
}
