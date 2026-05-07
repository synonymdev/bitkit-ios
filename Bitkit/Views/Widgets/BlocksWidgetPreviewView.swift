import SwiftUI

/// Preview screen for the Bitcoin Blocks widget.
struct BlocksWidgetPreviewView: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var widgets: WidgetsViewModel

    @StateObject private var viewModel = BlocksViewModel.shared

    @State private var carouselPage: Int = 0
    @State private var showDeleteAlert = false

    private let widgetType: WidgetType = .blocks

    private var widgetName: String {
        t("widgets__blocks__name")
    }

    private var widgetDescription: String {
        t("widgets__blocks__description")
    }

    private var isWidgetSaved: Bool {
        widgets.isWidgetSaved(widgetType)
    }

    private var hasCustomOptions: Bool {
        widgets.hasCustomOptions(for: widgetType)
    }

    private var currentOptions: BlocksWidgetOptions {
        widgets.getOptions(for: widgetType, as: BlocksWidgetOptions.self)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NavigationBar(title: widgetName, showMenuButton: false, showGradient: false)

            VStack(alignment: .leading, spacing: 0) {
                BodyMText(widgetDescription, textColor: .textSecondary)
                    .padding(.bottom, 16)

                Divider().background(Color.white.opacity(0.1))

                widgetSettingsRow

                Divider().background(Color.white.opacity(0.1))
            }

            VStack(spacing: 16) {
                Spacer(minLength: 0)

                carousel

                Spacer(minLength: 0)

                sizeLabel

                pageIndicator
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            buttonsRow
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray7.ignoresSafeArea())
        .task {
            viewModel.startUpdates()
        }
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

    // MARK: - Widget Settings cell

    private var widgetSettingsRow: some View {
        Button(action: { navigation.navigate(.widgetEdit(widgetType)) }) {
            HStack(alignment: .center, spacing: 0) {
                BodyMText(t("widgets__blocks__widget_settings"), textColor: .textPrimary)

                Spacer()

                BodyMText(
                    hasCustomOptions
                        ? t("widgets__widget__edit_custom")
                        : t("widgets__widget__edit_default"),
                    textColor: .textSecondary
                )

                Image("chevron")
                    .resizable()
                    .foregroundColor(.textSecondary)
                    .frame(width: 24, height: 24)
                    .padding(.leading, 5)
            }
            .frame(maxWidth: .infinity, minHeight: 51)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityIdentifier("WidgetEdit")
    }

    // MARK: - Carousel

    private var carousel: some View {
        TabView(selection: $carouselPage) {
            compactPage.tag(0)
            widePage.tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: 320)
    }

    private var compactPage: some View {
        VStack {
            Spacer(minLength: 0)
            Group {
                if let data = viewModel.blockData {
                    BlocksWidgetCompactContent(data: data, options: currentOptions)
                } else {
                    placeholderCompact
                }
            }
            .frame(width: 163, height: 192)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var widePage: some View {
        VStack {
            Spacer(minLength: 0)
            Group {
                if let data = viewModel.blockData {
                    BlocksWidgetWideContent(data: data, options: currentOptions)
                        .padding(16)
                        .background(Color.gray6)
                        .cornerRadius(16)
                } else {
                    placeholderWide
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
    }

    private var placeholderCompact: some View {
        Color.gray6
            .cornerRadius(16)
            .overlay(ProgressView())
    }

    private var placeholderWide: some View {
        Color.gray6
            .cornerRadius(16)
            .frame(height: 180)
            .overlay(ProgressView())
    }

    // MARK: - Size label & page indicator

    private var sizeLabel: some View {
        HStack {
            Spacer()
            CaptionMText(
                carouselPage == 0
                    ? t("widgets__blocks__size_small")
                    : t("widgets__blocks__size_wide"),
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
                    .fill(carouselPage == index ? Color.brandAccent : Color.white.opacity(0.32))
                    .frame(width: 8, height: 8)
            }
            Spacer()
        }
    }

    // MARK: - Buttons

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

    // MARK: - Actions

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
        BlocksWidgetPreviewView()
            .environmentObject(NavigationViewModel())
            .environmentObject(WidgetsViewModel())
    }
    .preferredColorScheme(.dark)
}
