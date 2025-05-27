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
        let fiatSymbol = currency.convert(sats: 1)?.symbol ?? "$"
        let description = localizedString("widgets__\(id.rawValue)__description", variables: ["fiatSymbol": fiatSymbol])
        let icon = "\(id.rawValue)-widget"

        return (name: name, description: description, icon: icon)
    }

    // Check if widget is already saved (for showing delete button)
    private var isWidgetSaved: Bool {
        widgets.isWidgetSaved(id)
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
        switch id {
        case .facts:
            FactsWidget(isEditing: false)
        case .news:
            NewsWidget(isEditing: false)
        case .price, .calculator, .weather, .block:
            // Placeholder for widgets not yet implemented
            VStack {
                Text("Widget Preview")
                    .foregroundColor(.textSecondary)
                Text("Coming Soon")
                    .foregroundColor(.textSecondary)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .background(Color.white10)
            .cornerRadius(16)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HeadlineText(widget.name.replacingOccurrences(of: " ", with: "\n"))
                }

                Spacer()

                Image(widget.icon)
                    .renderingMode(.original)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.bottom, 16)

            BodyMText(widget.description, textColor: .textSecondary)

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
