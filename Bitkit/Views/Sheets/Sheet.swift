import SwiftUI

enum SheetSize {
    case small, medium, large, calendar

    var height: CGFloat {
        let screenHeight = UIScreen.screenHeight
        let safeAreaInsets =
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.windows.first?.safeAreaInsets ?? .zero
        let headerHeight: CGFloat = 46
        let balanceHeight: CGFloat = 70
        let spacing: CGFloat = 32
        let adjustment: CGFloat = -21

        let safeArea = safeAreaInsets.top + safeAreaInsets.bottom
        let headerSpacing = safeArea + headerHeight + spacing + adjustment
        let balanceSpacing = headerSpacing + balanceHeight + spacing

        switch self {
        case .small:
            return 400
        case .medium:
            let minHeight: CGFloat = 600
            // Header + Balance visible
            let preferredHeight = screenHeight - balanceSpacing
            if preferredHeight < minHeight {
                // Use large sheet size when medium is too small
                let largePreferredHeight = screenHeight - headerSpacing
                return max(minHeight, largePreferredHeight)
            }
            return preferredHeight
        case .calendar:
            let minHeight: CGFloat = 600
            // same as medium + 40px, to be just under search input
            let preferredHeight = screenHeight - balanceSpacing + 40
            if preferredHeight < minHeight {
                // Use large sheet size when it's too small
                let largePreferredHeight = screenHeight - headerSpacing
                return max(minHeight, largePreferredHeight)
            }
            return preferredHeight
        case .large:
            let minHeight: CGFloat = 600
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

    init(title: String, showBackButton: Bool = false, action: AnyView? = nil) {
        self.title = title
        self.showBackButton = showBackButton
        self.action = action
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if showBackButton {
                Button(action: {
                    dismiss()
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

            SubtitleText(title)
                .frame(maxWidth: .infinity, alignment: .center)

            if let action {
                action
            } else {
                Spacer()
                    .frame(width: 24, height: 24)
            }
        }
        .padding(.top, 32) // Make room for the drag indicator
        .padding(.bottom, 32)
    }
}

// MARK: - Generic Reusable Sheet Component

// Base protocol that all sheet items should conform to
protocol SheetItem: Identifiable {
    var size: SheetSize { get }
}

struct Sheet<Content: View>: View {
    @EnvironmentObject private var sheets: SheetViewModel
    let configuration: SheetConfiguration
    let content: () -> Content

    init(id: SheetID, data: (any SheetItem)? = nil, @ViewBuilder content: @escaping () -> Content) {
        configuration = SheetConfiguration(id: id, data: data)
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
                .sheetBackground()
                .bottomSafeAreaPadding()

            // Custom drag indicator - always on top
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white32)
                .frame(width: 32, height: 4)
                .padding(.top, 12)
        }
        .presentationBackgroundInteraction(.disabled)
        .presentationDetents([.height(sheetSize.height)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(32)
        .presentationBackground { Color.black }
    }
}
