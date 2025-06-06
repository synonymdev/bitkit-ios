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
        case .calculator:
            return false
        }
    }

    var hasEnabledOption: Bool {
        switch widgetType {
        case .blocks:
            // Blocks widget has many options, check if any are enabled
            return blocksOptions.height || blocksOptions.time || blocksOptions.date || blocksOptions.transactionCount || blocksOptions.size
                || blocksOptions.weight || blocksOptions.difficulty || blocksOptions.hash || blocksOptions.merkleRoot || blocksOptions.showSource
        case .news, .facts:
            // Static items (showTitle) are always enabled, so these widgets always have enabled options
            return true
        case .weather:
            // Weather widget has multiple options, check if any are enabled
            return weatherOptions.showStatus || weatherOptions.showText || weatherOptions.showMedian || weatherOptions.showNextBlockFee
        case .price:
            // Price widget has options, check if at least one trading pair is selected
            return !priceOptions.selectedPairs.isEmpty
        case .calculator:
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
        case .calculator:
            return false
        }
    }

    // MARK: - Methods

    func toggleOption(_ item: WidgetEditItem) {
        // Don't toggle static items
        guard item.type == .toggleItem else { return }

        switch widgetType {
        case .blocks:
            switch item.key {
            case "height":
                blocksOptions.height.toggle()
            case "time":
                blocksOptions.time.toggle()
            case "date":
                blocksOptions.date.toggle()
            case "transactionCount":
                blocksOptions.transactionCount.toggle()
            case "size":
                blocksOptions.size.toggle()
            case "weight":
                blocksOptions.weight.toggle()
            case "difficulty":
                blocksOptions.difficulty.toggle()
            case "hash":
                blocksOptions.hash.toggle()
            case "merkleRoot":
                blocksOptions.merkleRoot.toggle()
            case "showSource":
                blocksOptions.showSource.toggle()
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
            case "BTC/USD":
                toggleTradingPair("BTC/USD")
            case "BTC/EUR":
                toggleTradingPair("BTC/EUR")
            case "BTC/GBP":
                toggleTradingPair("BTC/GBP")
            case "BTC/JPY":
                toggleTradingPair("BTC/JPY")
            case "period_1D":
                priceOptions.selectedPeriod = .oneDay
            case "period_1W":
                priceOptions.selectedPeriod = .oneWeek
            case "period_1M":
                priceOptions.selectedPeriod = .oneMonth
            case "period_1Y":
                priceOptions.selectedPeriod = .oneYear
            case "showSource":
                priceOptions.showSource.toggle()
            default:
                break
            }
        case .calculator:
            break
        }
        onStateChange?()
    }

    private func toggleTradingPair(_ pairName: String) {
        if priceOptions.selectedPairs.contains(pairName) {
            priceOptions.selectedPairs.removeAll { $0 == pairName }
        } else {
            priceOptions.selectedPairs.append(pairName)
        }
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
        case .calculator:
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
        case .calculator:
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
        case .calculator:
            break
        }
    }
}
