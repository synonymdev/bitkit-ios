import SwiftUI

/// BaseWidget component that forms the foundation for all widget types in the app
struct BaseWidget<Content: View>: View {
    // MARK: - Properties

    /// Unique identifier for the widget
    let id: String

    /// Content to display within the widget
    let content: Content

    /// Flag indicating if the widget is in editing mode
    var isEditing: Bool = false

    /// State for showing the delete confirmation dialog
    @State private var showDeleteDialog = false

    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var widgetStore: WidgetStore

    /// Widget information
    private var widget: (name: String, icon: String) {
        return (
            name: localizedString("widgets__\(id)__name"),
            icon: "\(id)-widget"
        )
    }

    // MARK: - Initialization

    /// Initialize a new widget with required and optional parameters
    /// - Parameters:
    ///   - id: Unique identifier for the widget
    ///   - isEditing: Flag indicating if the widget is in editing mode
    ///   - content: Content view builder for the widget
    init(
        id: String,
        isEditing: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.isEditing = isEditing
        self.content = content()
    }

    // MARK: - Actions

    /// Navigate to widget edit screen
    private func onEdit() {
        // TODO: Implement navigation
        // navigation.navigate(to: .widget(id: id))
    }

    /// Show the delete confirmation dialog
    private func onDelete() {
        showDeleteDialog = true
    }

    // MARK: - View Body

    var body: some View {
        Button {
        } label: {
            VStack(spacing: 0) {
                if wallet.showWidgetTitles || isEditing {
                    HStack {
                        HStack(spacing: 16) {
                            Image(widget.icon)
                                .renderingMode(.original)
                                .resizable()
                                .frame(width: 32, height: 32)

                            BodyMSBText(truncate(widget.name, 18))
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
                    if wallet.showWidgetTitles && !isEditing {
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
        .accessibilityIdentifier("\(id)-widget")
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
                    widgetStore.deleteWidget(id: id)
                    showDeleteDialog = false
                }
            },
            message: {
                Text(
                    localizedString(
                        "widgets__delete__description"
                    )
                    .replacingOccurrences(of: "{name}", with: widget.name)
                )
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
            id: "facts",
            isEditing: false
        ) {
            Text("Widget Content Goes Here")
                .frame(height: 100)
                .frame(maxWidth: .infinity)
        }

        BaseWidget(
            id: "stats",
            isEditing: true
        ) {
            Text("Widget Content Goes Here")
                .frame(height: 100)
                .frame(maxWidth: .infinity)
        }
    }
    .padding()
    .background(Color.black)
    .environmentObject(WidgetStore())
}

/// Placeholder widget store - would be replaced by actual app implementation
class WidgetStore: ObservableObject {
    func deleteWidget(id: String) {
        // Delete widget logic would go here
        print("Deleting widget with id: \(id)")
    }
}
