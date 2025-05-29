import SwiftUI

/// BaseWidget component that forms the foundation for all widget types in the app
struct BaseWidget<Content: View>: View {
    // MARK: - Properties

    /// Widget type identifier
    let type: WidgetType

    /// Content to display within the widget
    let content: Content

    /// Flag indicating if the widget is in editing mode
    var isEditing: Bool = false

    /// Callback to signal when editing should end
    var onEditingEnd: (() -> Void)?

    /// State for showing the delete confirmation dialog
    @State private var showDeleteDialog = false

    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var widgets: WidgetsViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var settings: SettingsViewModel

    /// Widget metadata computed from type
    private var metadata: WidgetMetadata {
        let fiatSymbol = currency.convert(sats: 1)?.symbol ?? "$"
        return WidgetMetadata(type: type, fiatSymbol: fiatSymbol)
    }

    // MARK: - Initialization

    /// Initialize a new widget with required and optional parameters
    /// - Parameters:
    ///   - type: Widget type identifier
    ///   - isEditing: Flag indicating if the widget is in editing mode
    ///   - onEditingEnd: Callback to signal when editing should end
    ///   - content: Content view builder for the widget
    init(
        type: WidgetType,
        isEditing: Bool = false,
        onEditingEnd: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.type = type
        self.isEditing = isEditing
        self.onEditingEnd = onEditingEnd
        self.content = content()
    }

    private func onEdit() {
        navigation.navigate(.widgetDetail(type))
        onEditingEnd?()
    }

    private func onDelete() {
        showDeleteDialog = true
    }

    var body: some View {
        Button {
        } label: {
            VStack(spacing: 0) {
                if settings.showWidgetTitles || isEditing {
                    HStack {
                        HStack(spacing: 16) {
                            Image(metadata.icon)
                                .renderingMode(.original)
                                .resizable()
                                .frame(width: 32, height: 32)

                            BodyMSBText(truncate(metadata.name, 18))
                                .lineLimit(1)
                        }

                        Spacer()

                        // Action buttons when in edit mode
                        if isEditing {
                            HStack(spacing: 8) {
                                // Delete button
                                Button {
                                    onDelete()
                                } label: {
                                    Image("trash")
                                        .renderingMode(.original)
                                        .resizable()
                                        .frame(width: 24, height: 24)
                                        .foregroundColor(.white)
                                }
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                                .trackButtonLocation { _ in }

                                // Edit button
                                Button {
                                    onEdit()
                                } label: {
                                    Image("gear-six")
                                        .resizable()
                                        .frame(width: 24, height: 24)
                                        .foregroundColor(.white)
                                }
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                                .trackButtonLocation { _ in }

                                Image("burger")
                                    .resizable()
                                    .frame(width: 24, height: 24)
                                    .foregroundColor(.white)
                            }
                        }
                    }

                    // Add spacer only when showing title and not editing
                    if settings.showWidgetTitles && !isEditing {
                        Spacer()
                            .frame(height: 16)
                    }
                }

                // Widget content (only shown when not editing)
                if !isEditing {
                    content
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("\(type.rawValue)-widget")
        .buttonStyle(WidgetButtonStyle())
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color.white10)
        .cornerRadius(16)
        .alert(
            localizedString("widgets__delete__title"),
            isPresented: $showDeleteDialog,
            actions: {
                Button(localizedString("common__cancel"), role: .cancel) {
                    showDeleteDialog = false
                }

                Button(localizedString("common__delete_yes"), role: .destructive) {
                    widgets.deleteWidget(type)
                    showDeleteDialog = false
                    onEditingEnd?()
                }
            },
            message: {
                Text(localizedString("widgets__delete__description", variables: ["name": metadata.name]))
            }
        )
    }

    /// Truncate a string to a maximum length
    private func truncate(_ text: String, _ maxLength: Int) -> String {
        if text.count <= maxLength {
            return text
        }

        let index = text.index(text.startIndex, offsetBy: maxLength - 3)
        return String(text[..<index]) + "..."
    }
}

/// Custom button style for widgets
struct WidgetButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }
}

/// Preview for the BaseWidget
#Preview {
    VStack {
        BaseWidget(
            type: .facts,
            isEditing: false,
            onEditingEnd: {
                print("Editing ended")
            }
        ) {
            Text("Widget Content Goes Here")
                .frame(height: 100)
                .frame(maxWidth: .infinity)
        }

        BaseWidget(
            type: .news,
            isEditing: true,
            onEditingEnd: {
                print("Editing ended")
            }
        ) {
            Text("Widget Content Goes Here")
                .frame(height: 100)
                .frame(maxWidth: .infinity)
        }
    }
    .padding()
    .background(Color.black)
    .environmentObject(WidgetsViewModel())
    .environmentObject(NavigationViewModel())
    .environmentObject(CurrencyViewModel())
    .environmentObject(SettingsViewModel())
    .preferredColorScheme(.dark)
}
