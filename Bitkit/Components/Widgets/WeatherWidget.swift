import SwiftUI

struct WeatherWidget: View {
    var options: WeatherWidgetOptions = .init()
    var size: WidgetSize = .wide
    var isEditing: Bool = false
    var onEditingEnd: (() -> Void)?

    @StateObject private var viewModel = WeatherViewModel.shared
    @EnvironmentObject private var currency: CurrencyViewModel

    init(
        options: WeatherWidgetOptions = WeatherWidgetOptions(),
        size: WidgetSize = .wide,
        isEditing: Bool = false,
        onEditingEnd: (() -> Void)? = nil
    ) {
        self.options = options
        self.size = size
        self.isEditing = isEditing
        self.onEditingEnd = onEditingEnd
    }

    var body: some View {
        BaseWidget(
            type: .weather,
            size: size,
            isEditing: isEditing,
            onEditingEnd: onEditingEnd
        ) {
            content
        }
        .task {
            viewModel.setCurrencyViewModel(currency)
            viewModel.startUpdates()
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.weatherData == nil {
            WidgetContentBuilder.loadingView()
        } else if viewModel.error != nil && viewModel.weatherData == nil {
            WidgetContentBuilder.errorView(t("widgets__weather__error"))
        } else if let data = viewModel.weatherData {
            if size == .small {
                WeatherWidgetCompactContent(
                    data: data,
                    metric: options.selectedMetric,
                    conditionTitle: t(data.condition.titleKey),
                    metricLabel: t(options.selectedMetric.labelKey)
                )
            } else {
                WeatherWidgetWideContent(
                    data: data,
                    metric: options.selectedMetric,
                    conditionTitle: t(data.condition.titleKey),
                    conditionDescription: t(data.condition.descriptionKey),
                    metricLabel: t(options.selectedMetric.labelKey)
                )
            }
        }
    }
}

#Preview {
    WeatherWidget()
        .padding()
        .background(.black)
        .environmentObject(WalletViewModel())
        .environmentObject(CurrencyViewModel())
        .preferredColorScheme(.dark)
}
