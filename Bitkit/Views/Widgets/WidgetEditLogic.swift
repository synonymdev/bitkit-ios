import SwiftUI

// MARK: - Widget Edit Logic

@MainActor
class WidgetEditLogic: ObservableObject {
    @Published var blocksOptions = BlocksWidgetOptions()
    @Published var factsOptions = FactsWidgetOptions()
    @Published var newsOptions = NewsWidgetOptions()
    @Published var weatherOptions = WeatherWidgetOptions()
    @Published var priceOptions = PriceWidgetOptions()

    private let widgetType: WidgetType
    private let widgetsViewModel: WidgetsViewModel
    var onStateChange: (() -> Void)?

    init(widgetType: WidgetType, widgetsViewModel: WidgetsViewModel) {
        self.widgetType = widgetType
        self.widgetsViewModel = widgetsViewModel
        // Don't load options in init, do it in loadCurrentOptions() when called from onAppear
    }

    // MARK: - Computed Properties

    var hasOptions: Bool {
        switch widgetType {
        case .facts, .blocks, .news, .price, .weather:
            return true
        case .calculator, .suggestions:
            return false
        }
    }

    var hasEnabledOption: Bool {
        switch widgetType {
        case .blocks:
            return blocksOptions.height
                || blocksOptions.time
                || blocksOptions.date
                || blocksOptions.transactionCount
                || blocksOptions.size
                || blocksOptions.fees
        case .news:
            return newsOptions.showTitle || newsOptions.showSource || newsOptions.showDate
        case .facts:
            // Facts widget's static title is always shown, so it always has an enabled option
            return true
        case .weather:
            // Weather widget has multiple options, check if any are enabled
            return weatherOptions.showStatus || weatherOptions.showText || weatherOptions.showMedian || weatherOptions.showNextBlockFee
        case .price:
            // Price widget always has a selected pair (single-select).
            return true
        case .calculator, .suggestions:
            return false
        }
    }

    var hasEdited: Bool {
        switch widgetType {
        case .blocks:
            let defaultOptions = BlocksWidgetOptions()
            return blocksOptions != defaultOptions
        case .facts:
            let defaultOptions = FactsWidgetOptions()
            return factsOptions != defaultOptions
        case .news:
            let defaultOptions = NewsWidgetOptions()
            return newsOptions != defaultOptions
        case .weather:
            let defaultOptions = WeatherWidgetOptions()
            return weatherOptions != defaultOptions
        case .price:
            let defaultOptions = PriceWidgetOptions()
            return priceOptions != defaultOptions
        case .calculator, .suggestions:
            return false
        }
    }

    // MARK: - Methods

    func toggleOption(_ item: WidgetEditItem) {
        // Don't toggle static items
        guard item.type != .staticItem else { return }

        switch widgetType {
        case .blocks:
            switch item.key {
            case "height":
                guard canToggleBlockOption(blocksOptions.height) else { break }
                blocksOptions.height.toggle()
            case "time":
                guard canToggleBlockOption(blocksOptions.time) else { break }
                blocksOptions.time.toggle()
            case "date":
                guard canToggleBlockOption(blocksOptions.date) else { break }
                blocksOptions.date.toggle()
            case "transactionCount":
                guard canToggleBlockOption(blocksOptions.transactionCount) else { break }
                blocksOptions.transactionCount.toggle()
            case "size":
                guard canToggleBlockOption(blocksOptions.size) else { break }
                blocksOptions.size.toggle()
            case "fees":
                guard canToggleBlockOption(blocksOptions.fees) else { break }
                blocksOptions.fees.toggle()
            default:
                break
            }
        case .facts:
            switch item.key {
            case "showSource":
                factsOptions.showSource.toggle()
            default:
                break
            }
        case .news:
            switch item.key {
            case "showDate":
                newsOptions.showDate.toggle()
            case "showTitle":
                newsOptions.showTitle.toggle()
            case "showSource":
                newsOptions.showSource.toggle()
            default:
                break
            }
        case .weather:
            switch item.key {
            case "showStatus":
                weatherOptions.showStatus.toggle()
            case "showText":
                weatherOptions.showText.toggle()
            case "showMedian":
                weatherOptions.showMedian.toggle()
            case "showNextBlockFee":
                weatherOptions.showNextBlockFee.toggle()
            default:
                break
            }
        case .price:
            switch item.key {
            case "BTC/USD", "BTC/EUR", "BTC/GBP", "BTC/JPY":
                priceOptions.selectedPair = item.key
            case "1D":
                priceOptions.selectedPeriod = .oneDay
            case "1W":
                priceOptions.selectedPeriod = .oneWeek
            case "1M":
                priceOptions.selectedPeriod = .oneMonth
            case "1Y":
                priceOptions.selectedPeriod = .oneYear
            default:
                break
            }
        case .calculator, .suggestions:
            break
        }
        onStateChange?()
    }

    private func canToggleBlockOption(_ isCurrentlyEnabled: Bool) -> Bool {
        isCurrentlyEnabled || enabledBlockOptionsCount < 4
    }

    private var enabledBlockOptionsCount: Int {
        [
            blocksOptions.height,
            blocksOptions.time,
            blocksOptions.date,
            blocksOptions.transactionCount,
            blocksOptions.size,
            blocksOptions.fees,
        ].filter { $0 }.count
    }

    func loadCurrentOptions() {
        switch widgetType {
        case .blocks:
            blocksOptions = widgetsViewModel.getOptions(for: widgetType, as: BlocksWidgetOptions.self)
        case .facts:
            factsOptions = widgetsViewModel.getOptions(for: widgetType, as: FactsWidgetOptions.self)
        case .news:
            newsOptions = widgetsViewModel.getOptions(for: widgetType, as: NewsWidgetOptions.self)
        case .weather:
            weatherOptions = widgetsViewModel.getOptions(for: widgetType, as: WeatherWidgetOptions.self)
        case .price:
            priceOptions = widgetsViewModel.getOptions(for: widgetType, as: PriceWidgetOptions.self)
        case .calculator, .suggestions:
            break
        }
    }

    func resetOptions() {
        switch widgetType {
        case .blocks:
            blocksOptions = BlocksWidgetOptions()
        case .facts:
            factsOptions = FactsWidgetOptions()
        case .news:
            newsOptions = NewsWidgetOptions()
        case .weather:
            weatherOptions = WeatherWidgetOptions()
        case .price:
            priceOptions = PriceWidgetOptions()
        case .calculator, .suggestions:
            break
        }
        onStateChange?()
    }

    func saveOptions() {
        switch widgetType {
        case .blocks:
            widgetsViewModel.saveOptions(blocksOptions, for: widgetType)
        case .facts:
            widgetsViewModel.saveOptions(factsOptions, for: widgetType)
        case .news:
            widgetsViewModel.saveOptions(newsOptions, for: widgetType)
        case .weather:
            widgetsViewModel.saveOptions(weatherOptions, for: widgetType)
        case .price:
            widgetsViewModel.saveOptions(priceOptions, for: widgetType)
        case .calculator, .suggestions:
            break
        }
    }
}
