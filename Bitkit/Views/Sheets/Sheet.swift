import SwiftUI

enum SheetSize {
    case small, medium, large

    var height: CGFloat {
        switch self {
        case .small: return 400
        case .medium: return UIScreen.screenHeight - 273 // Header + Balance visible
        case .large: return UIScreen.screenHeight - 153 // Only Header visible
        }
    }
}

struct SheetHeader: View {
    @Environment(\.dismiss) var dismiss
    let title: String
    let showBackButton: Bool

    init(title: String, showBackButton: Bool = false) {
        self.title = title
        self.showBackButton = showBackButton
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
            }

            SubtitleText(title)
                .frame(maxWidth: .infinity, alignment: .center)

            if showBackButton {
                Spacer()
                    .frame(width: 24, height: 24)
            } else {
                Spacer()
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
        self.configuration = SheetConfiguration(id: id, data: data)
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
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(32)
        .presentationBackground { Color.black }
    }
}
