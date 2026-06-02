import SwiftUI

// MARK: - Widget Protocol

/// Protocol that all widgets should conform to for consistent behavior
protocol WidgetProtocol {
    associatedtype OptionsType: Codable & Equatable
    associatedtype ViewModelType: ObservableObject

    var options: OptionsType { get set }
    var isEditing: Bool { get set }
    var onEditingEnd: (() -> Void)? { get set }

    init(options: OptionsType, isEditing: Bool, onEditingEnd: (() -> Void)?)
    init(viewModel: ViewModelType, options: OptionsType, isEditing: Bool, onEditingEnd: (() -> Void)?)
}

// MARK: - Common Widget States

/// Common states that widgets can be in
enum WidgetState {
    case loading
    case loaded
    case error(String)
    case empty
}

// MARK: - Widget Content Builder

/// Helper for building common widget content patterns
enum WidgetContentBuilder {
    /// Creates a standard loading view
    static func loadingView() -> some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Creates a standard error view
    static func errorView(_ message: String) -> some View {
        CaptionBText(message, textColor: .textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Creates a standard source attribution row
    static func sourceRow(source: String) -> some View {
        HStack(spacing: 0) {
            HStack {
                CaptionBText(t("widgets__widget__source"))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                CaptionBText(source)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, 16)
    }
}

/// Foundation container for all widgets. Owns the card chrome (gray6 bg, 16pt radius),
/// the v61 editing overlay (dashed brand border + centred action icons), and the small/wide
/// sizing rules used by the home grid.
struct BaseWidget<Content: View>: View {
    let type: WidgetType
    let content: Content
    var size: WidgetSize = .wide
    var isEditing: Bool = false
    var hasBackground: Bool = true
    var onEditingEnd: (() -> Void)?

    @State private var showDeleteDialog = false

    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var widgets: WidgetsViewModel
    @Environment(\.widgetDragState) private var dragState

    private static var smallHeight: CGFloat {
        192
    }

    private var metadata: WidgetMetadata {
        WidgetMetadata(type: type, fiatSymbol: currency.symbol)
    }

    private var isSettingsDisabled: Bool {
        switch type {
        case .suggestions, .facts, .calculator: return true
        default: return false
        }
    }

    init(
        type: WidgetType,
        size: WidgetSize = .wide,
        isEditing: Bool = false,
        hasBackground: Bool = true,
        onEditingEnd: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.type = type
        self.size = size
        self.isEditing = isEditing
        self.hasBackground = hasBackground
        self.onEditingEnd = onEditingEnd
        self.content = content()
    }

    var body: some View {
        cardBody
            .frame(maxWidth: .infinity)
            .frame(height: size == .small ? Self.smallHeight : nil, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifierIfPresent(isEditing ? nil : "\(type.rawValue.capitalized)Widget")
            .alert(
                t("widgets__delete__title"),
                isPresented: $showDeleteDialog,
                actions: {
                    Button(t("common__cancel"), role: .cancel) { showDeleteDialog = false }
                    Button(t("common__delete_yes"), role: .destructive) {
                        widgets.deleteWidget(type)
                        showDeleteDialog = false
                    }
                },
                message: {
                    Text(t("widgets__delete__description", variables: ["name": metadata.name]))
                }
            )
    }

    private var cardBody: some View {
        ZStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .blur(radius: isEditing ? 4 : 0)
                // Contain the blur's soft halo so it doesn't bleed past the rounded corners and
                // muddy the dashed border. cornerRadius 0 (non-editing) just clips to bounds.
                .clipShape(RoundedRectangle(cornerRadius: isEditing ? 16 : 0))
                // Editing only responds to the overlay controls; keep the blurred content from
                // reacting to taps underneath (e.g. opening the calculator keypad or navigating).
                .allowsHitTesting(!isEditing)
                .accessibilityHidden(isEditing)

            if isEditing {
                Color.gray6.opacity(0.8)

                editingOverlay
            }
        }
        .padding((hasBackground || isEditing) ? 16 : 0)
        .background((hasBackground || isEditing) ? Color.gray6 : Color.clear)
        .cornerRadius(hasBackground || isEditing ? 16 : 0)
        .overlay {
            if isEditing {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        Color.brandAccent,
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
            }
        }
    }

    private var editingOverlay: some View {
        VStack(spacing: 12) {
            BodyMSBText(metadata.name)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(spacing: 16) {
                Button(action: { showDeleteDialog = true }) {
                    Image("trash")
                        .resizable()
                        .foregroundColor(.textPrimary)
                        .frame(width: 24, height: 24)
                }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .accessibilityIdentifier("\(metadata.name)_WidgetActionDelete")

                Button(action: onEdit) {
                    Image("gear-six")
                        .resizable()
                        .foregroundColor(.textPrimary)
                        .frame(width: 24, height: 24)
                        .opacity(isSettingsDisabled ? 0.3 : 1)
                }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .disabled(isSettingsDisabled)
                .accessibilityIdentifier("\(metadata.name)_WidgetActionEdit")

                Image("burger")
                    .resizable()
                    .foregroundColor(.textPrimary)
                    .frame(width: 24, height: 24)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                    .overlay {
                        Color.clear
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .trackDragHandle()
                    }
                    .onDrag {
                        dragState.draggingType = type
                        dragState.lastTarget = nil
                        return NSItemProvider(object: type.rawValue as NSString)
                    } preview: {
                        dragPreview
                    }
                    .accessibilityIdentifier("\(metadata.name)_WidgetActionReorder")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Snapshot of the card in its editing state — dashed brand border, centred name,
    /// gray6 fill. Used as the floating preview while the user drags the burger handle so
    /// the dashed component "follows" the finger instead of just the icon.
    private var dragPreview: some View {
        VStack(spacing: 12) {
            BodyMSBText(metadata.name)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(spacing: 16) {
                Image("trash")
                    .resizable()
                    .foregroundColor(.textPrimary)
                    .frame(width: 24, height: 24)
                Image("gear-six")
                    .resizable()
                    .foregroundColor(.textPrimary)
                    .frame(width: 24, height: 24)
                Image("burger")
                    .resizable()
                    .foregroundColor(.textPrimary)
                    .frame(width: 24, height: 24)
            }
        }
        .frame(
            width: size == .small ? 172 : 343,
            height: size == .small ? Self.smallHeight : 120
        )
        .background(Color.gray6)
        .cornerRadius(16)
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    Color.brandAccent,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
        }
    }

    private func onEdit() {
        sheets.showSheet(.widgets, data: WidgetsConfig(initialRoute: .preview(type)))
        onEditingEnd?()
    }
}

#Preview {
    VStack {
        BaseWidget(type: .facts, isEditing: false) {
            Text("Widget Content Goes Here")
                .frame(height: 100)
                .frame(maxWidth: .infinity)
        }

        BaseWidget(type: .news, isEditing: true) {
            Text("Widget Content Goes Here")
                .frame(height: 100)
                .frame(maxWidth: .infinity)
        }
    }
    .padding()
    .background(Color.black)
    .environmentObject(CurrencyViewModel())
    .environmentObject(SettingsViewModel.shared)
    .environmentObject(SheetViewModel())
    .environmentObject(WidgetsViewModel())
    .preferredColorScheme(.dark)
}
