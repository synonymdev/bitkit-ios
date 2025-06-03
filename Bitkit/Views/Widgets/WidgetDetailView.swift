import SwiftUI

struct WidgetDetailView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var widgets: WidgetsViewModel
    let id: WidgetType

    // State for managing widget actions
    @State private var showDeleteAlert = false

    // Widget data computed from the ID
    private var widget: (name: String, description: String, icon: String) {
        let name = localizedString("widgets__\(id.rawValue)__name")

        // Get fiat symbol from currency conversion
        let fiatSymbol = currency.symbol
        let description = localizedString("widgets__\(id.rawValue)__description", variables: ["fiatSymbol": fiatSymbol])
        let icon = "\(id.rawValue)-widget"

        return (name: name, description: description, icon: icon)
    }

    // Check if widget is already saved (for showing delete button)
    private var isWidgetSaved: Bool {
        widgets.isWidgetSaved(id)
    }

    // Check if widget has customization options
    private var hasOptions: Bool {
        switch id {
        case .blocks, .facts, .news, .price, .weather:
            return true
        case .calculator:
            return false
        }
    }

    // Check if widget has custom options
    private var hasCustomOptions: Bool {
        widgets.hasCustomOptions(for: id)
    }

    private func onSave() {
        widgets.saveWidget(id)
        navigation.reset()
    }

    private func onDelete() {
        widgets.deleteWidget(id)
        navigation.reset()
    }

    @ViewBuilder
    private func renderWidget() -> some View {
        let widget = Widget(type: id)
        widget.view(widgetsViewModel: widgets, isEditing: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HeadlineText(widget.name.replacingOccurrences(of: " ", with: "\n"))
                }

                Spacer()

                Image(widget.icon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.bottom, 16)

            BodyMText(widget.description, textColor: .textSecondary)

            if hasOptions {
                Button(action: {
                    navigation.navigate(.widgetEdit(id))
                }) {
                    HStack(spacing: 0) {
                        BodyMText(localizedString("widgets__widget__edit"), textColor: .textPrimary)

                        Spacer()

                        BodyMText(
                            hasCustomOptions
                                ? localizedString("widgets__widget__edit_custom")
                                : localizedString("widgets__widget__edit_default"),
                            textColor: .textPrimary
                        )

                        Image("arrow-right")
                            .resizable()
                            .foregroundColor(.textSecondary)
                            .frame(width: 24, height: 24)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.vertical, 14)
                .overlay(
                    VStack {
                        Divider()
                            .background(Color.white.opacity(0.1))
                        Spacer()
                        Divider()
                            .background(Color.white.opacity(0.1))
                    }
                )
                .padding(.top, 16)
                .accessibilityIdentifier("WidgetEdit")
            }

            Spacer()

            VStack(alignment: .leading, spacing: 0) {
                CaptionText(localizedString("common__preview"))
                    .textCase(.uppercase)
                    .padding(.top, 16)
                    .padding(.bottom, 16)

                renderWidget()

                HStack(spacing: 16) {
                    if isWidgetSaved {
                        CustomButton(
                            title: localizedString("common__delete"),
                            variant: .secondary,
                            size: .large,
                            shouldExpand: true
                        ) {
                            showDeleteAlert = true
                        }
                        .accessibilityIdentifier("WidgetDelete")
                    }

                    CustomButton(
                        title: localizedString("common__save"),
                        variant: .primary,
                        size: .large,
                        shouldExpand: true,
                        action: onSave
                    )
                    .accessibilityIdentifier("WidgetSave")
                }
                .padding(.top, 16)
            }
        }
        .padding(.top)
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .navigationTitle(localizedString("widgets__widget__nav_title"))
        .navigationBarTitleDisplayMode(.inline)
        .backToWalletButton()
        .alert(
            localizedString("widgets__delete__title"),
            isPresented: $showDeleteAlert,
            actions: {
                Button(localizedString("common__cancel"), role: .cancel) {
                    showDeleteAlert = false
                }

                Button(localizedString("common__delete_yes"), role: .destructive) {
                    onDelete()
                }
            },
            message: {
                Text(localizedString("widgets__delete__description", variables: ["name": widget.name]))
            }
        )
    }
}

#Preview {
    NavigationStack {
        WidgetDetailView(id: .price)
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject(WidgetsViewModel())
    }
    .preferredColorScheme(.dark)
}
