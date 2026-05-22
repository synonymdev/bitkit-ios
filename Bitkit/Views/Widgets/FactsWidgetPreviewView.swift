import SwiftUI

/// Preview screen for the Bitcoin Facts widget.
struct FactsWidgetPreviewView: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var widgets: WidgetsViewModel

    @StateObject private var viewModel = FactsViewModel.shared

    // TODO: revert to 0 to re-enable the compact widget preview
    @State private var carouselPage: Int = 1
    @State private var showDeleteAlert = false

    private let widgetType: WidgetType = .facts

    private var widgetName: String {
        t("widgets__facts__name")
    }

    private var widgetDescription: String {
        t("widgets__facts__description")
    }

    private var isWidgetSaved: Bool {
        widgets.isWidgetSaved(widgetType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NavigationBar(title: widgetName, showMenuButton: true)

            VStack(alignment: .leading, spacing: 0) {
                BodyMText(widgetDescription, textColor: .textSecondary)
                    .padding(.bottom, 16)

                Divider().background(Color.white.opacity(0.1))
            }

            VStack(spacing: 16) {
                carousel

                // Size label hidden while only the wide widget is shown
                // sizeLabel

                // Page indicator hidden while only the wide widget is shown
                // pageIndicator
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            buttonsRow
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .alert(
            t("widgets__delete__title"),
            isPresented: $showDeleteAlert,
            actions: {
                Button(t("common__cancel"), role: .cancel) { showDeleteAlert = false }
                Button(t("common__delete_yes"), role: .destructive) { onDelete() }
            },
            message: {
                Text(t("widgets__delete__description", variables: ["name": widgetName]))
            }
        )
    }

    private var carousel: some View {
        TabView(selection: $carouselPage) {
            // Compact preview temporarily hidden — only the wide widget can be added for now
            // compactPage.tag(0)
            widePage.tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxHeight: .infinity)
    }

    private var compactPage: some View {
        VStack {
            Spacer(minLength: 0)
            FactsWidgetCompactContent(fact: viewModel.fact)
                .padding(16)
                .background(Color.gray6)
                .cornerRadius(16)
                .frame(width: 163, height: 192)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var widePage: some View {
        VStack {
            Spacer(minLength: 0)
            FactsWidgetWideContent(fact: viewModel.fact)
                .padding(16)
                .background(Color.gray6)
                .cornerRadius(16)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
    }

    private var sizeLabel: some View {
        HStack {
            Spacer()
            CaptionMText(
                carouselPage == 0
                    ? t("widgets__widget__size_small")
                    : t("widgets__widget__size_wide"),
                textColor: .textSecondary
            )
            .textCase(.uppercase)
            Spacer()
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            Spacer()
            ForEach(0 ..< 2, id: \.self) { index in
                Circle()
                    .fill(carouselPage == index ? Color.white : Color.white.opacity(0.32))
                    .frame(width: 8, height: 8)
            }
            Spacer()
        }
    }

    private var buttonsRow: some View {
        HStack(spacing: 16) {
            if isWidgetSaved {
                CustomButton(
                    title: t("common__delete"),
                    variant: .secondary,
                    size: .large,
                    shouldExpand: true
                ) {
                    showDeleteAlert = true
                }
                .accessibilityIdentifier("WidgetDelete")
            }

            CustomButton(
                title: t("widgets__widget__save_widget"),
                variant: .primary,
                size: .large,
                shouldExpand: true,
                action: onSave
            )
            .accessibilityIdentifier("WidgetSave")
        }
    }

    private func onSave() {
        widgets.saveWidget(widgetType)
        navigation.reset()
    }

    private func onDelete() {
        widgets.deleteWidget(widgetType)
        navigation.reset()
    }
}

#Preview {
    NavigationStack {
        FactsWidgetPreviewView()
            .environmentObject(NavigationViewModel())
            .environmentObject(WidgetsViewModel())
    }
    .preferredColorScheme(.dark)
}
