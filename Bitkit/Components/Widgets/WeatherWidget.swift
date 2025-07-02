import SwiftUI

/// Options for configuring the WeatherWidget
struct WeatherWidgetOptions: Codable, Equatable {
    var showStatus: Bool = true
    var showText: Bool = true
    var showMedian: Bool = true
    var showNextBlockFee: Bool = true
}

/// Fee condition enum matching the React Native implementation
enum FeeCondition: String, Codable {
    case good = "good"
    case average = "average"
    case poor = "poor"

    var title: String {
        switch self {
        case .good:
            return localizedString("widgets__weather__condition__good__title")
        case .average:
            return localizedString("widgets__weather__condition__average__title")
        case .poor:
            return localizedString("widgets__weather__condition__poor__title")
        }
    }

    var description: String {
        switch self {
        case .good:
            return localizedString("widgets__weather__condition__good__description")
        case .average:
            return localizedString("widgets__weather__condition__average__description")
        case .poor:
            return localizedString("widgets__weather__condition__poor__description")
        }
    }

    var icon: String {
        switch self {
        case .good:
            return "☀️"
        case .average:
            return "⛅"
        case .poor:
            return "⛈️"
        }
    }
}

/// Weather widget data model
struct WeatherData: Codable {
    let condition: FeeCondition
    let currentFee: String
    let nextBlockFee: Int
}

/// A widget that displays Bitcoin fee weather information
struct WeatherWidget: View {
    /// Configuration options for the widget
    var options: WeatherWidgetOptions = WeatherWidgetOptions()

    /// Flag indicating if the widget is in editing mode
    var isEditing: Bool = false

    /// Callback to signal when editing should end
    var onEditingEnd: (() -> Void)?

    /// View model for handling weather data
    @StateObject private var viewModel = WeatherViewModel.shared

    /// Currency view model for currency conversion
    @EnvironmentObject private var currency: CurrencyViewModel

    /// Initialize the widget
    init(
        options: WeatherWidgetOptions = WeatherWidgetOptions(),
        isEditing: Bool = false,
        onEditingEnd: (() -> Void)? = nil
    ) {
        self.options = options
        self.isEditing = isEditing
        self.onEditingEnd = onEditingEnd
    }

    var body: some View {
        BaseWidget(
            type: .weather,
            isEditing: isEditing,
            onEditingEnd: onEditingEnd
        ) {
            VStack(spacing: 0) {
                if viewModel.isLoading {
                    WidgetContentBuilder.loadingView()
                } else if viewModel.error != nil {
                    WidgetContentBuilder.errorView(localizedString("widgets__weather__error"))
                } else if let data = viewModel.weatherData {
                    VStack(spacing: 16) {
                        // Status condition with icon
                        if options.showStatus {
                            HStack(spacing: 16) {
                                WeatherTitleText(data.condition.title)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(data.condition.icon)
                                    .font(.system(size: 100))
                                    .frame(width: 110, height: 100)
                            }
                        }

                        // Description text
                        if options.showText {
                            BodyMText(data.condition.description, textColor: .textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Fee information rows
                        if options.showMedian || options.showNextBlockFee {
                            VStack(spacing: 8) {
                                if options.showMedian {
                                    HStack(spacing: 0) {
                                        HStack {
                                            BodySSBText(localizedString("widgets__weather__current_fee"), textColor: .textSecondary)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        HStack {
                                            BodyMSBText(data.currentFee)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                    }
                                    .frame(minHeight: 20)
                                }

                                if options.showNextBlockFee {
                                    HStack(spacing: 0) {
                                        HStack {
                                            BodySSBText(localizedString("widgets__weather__next_block"), textColor: .textSecondary)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        HStack {
                                            BodyMSBText("\(data.nextBlockFee) ₿/vByte")
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                    }
                                    .frame(minHeight: 20)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            // Inject currency dependency into view model
            viewModel.setCurrencyViewModel(currency)
            // Start data updates
            viewModel.startUpdates()
        }
    }
}

struct WeatherTitleText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Fonts.bold(size: 34))
            .foregroundColor(.textPrimary)
            .kerning(0)
            .environment(\._lineHeightMultiple, 0.85)
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
