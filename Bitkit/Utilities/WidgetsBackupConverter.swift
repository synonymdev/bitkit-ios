import Foundation

/// Converts between iOS `SavedWidget` format and Android `WidgetsData` format for backup/restore
enum WidgetsBackupConverter {
    /// Converts iOS `[SavedWidget]` to Android `WidgetsData` format
    static func convertToAndroidFormat(savedWidgets: [SavedWidget]) throws -> Data {
        var widgetsArray: [[String: Any]] = []
        var blocksPreferences: [String: Any]?
        var newsPreferences: [String: Any]?
        var factsPreferences: [String: Any]?
        var weatherPreferences: [String: Any]?
        var pricePreferences: [String: Any]?

        for (index, widget) in savedWidgets.enumerated() {
            var androidType = widget.type.rawValue.uppercased()
            if androidType == "BLOCKS" {
                androidType = "BLOCK"
            }

            widgetsArray.append([
                "type": androidType,
                "position": index,
            ])

            if let optionsData = widget.optionsData {
                switch widget.type {
                case .blocks:
                    if let options = try? JSONDecoder().decode(BlocksWidgetOptions.self, from: optionsData) {
                        blocksPreferences = [
                            "showBlock": options.height,
                            "showTime": options.time,
                            "showDate": options.date,
                            "showTransactions": options.transactionCount,
                            "showSize": options.size,
                            "showSource": options.showSource,
                        ]
                    }
                case .news:
                    if let options = try? JSONDecoder().decode(NewsWidgetOptions.self, from: optionsData) {
                        newsPreferences = [
                            "showTime": options.showDate,
                            "showSource": options.showSource,
                        ]
                    }
                case .facts:
                    if let options = try? JSONDecoder().decode(FactsWidgetOptions.self, from: optionsData) {
                        factsPreferences = [
                            "showSource": options.showSource,
                        ]
                    }
                case .weather:
                    if let options = try? JSONDecoder().decode(WeatherWidgetOptions.self, from: optionsData) {
                        weatherPreferences = [
                            "showTitle": options.showStatus,
                            "showDescription": options.showText,
                            "showCurrentFee": options.showMedian,
                            "showNextBlockFee": options.showNextBlockFee,
                        ]
                    }
                case .price:
                    if let options = try? JSONDecoder().decode(PriceWidgetOptions.self, from: optionsData) {
                        let androidPairs = options.selectedPairs.map { pair in
                            pair.replacingOccurrences(of: "/", with: "_")
                        }
                        let androidPeriod = convertIosPeriodToAndroid(options.selectedPeriod)
                        pricePreferences = [
                            "enabledPairs": androidPairs.isEmpty ? ["BTC_USD"] : androidPairs,
                            "period": androidPeriod,
                            "showSource": options.showSource,
                        ]
                    }
                case .calculator:
                    break
                }
            }
        }

        let androidWidgetsData: [String: Any] = [
            "widgets": widgetsArray,
            "headlinePreferences": newsPreferences ?? getDefaultNewsPreferences(),
            "factsPreferences": factsPreferences ?? getDefaultFactsPreferences(),
            "blocksPreferences": blocksPreferences ?? getDefaultBlocksPreferences(),
            "weatherPreferences": weatherPreferences ?? getDefaultWeatherPreferences(),
            "pricePreferences": pricePreferences ?? getDefaultPricePreferences(),
            "calculatorValues": [
                "btcValue": "",
                "fiatValue": "",
            ],
            "articles": [[String: Any]](),
            "facts": [String](),
            "block": NSNull(),
            "weather": NSNull(),
            "price": NSNull(),
        ]

        return try JSONSerialization.data(withJSONObject: androidWidgetsData, options: [])
    }

    /// Converts Android `WidgetsData` format to iOS `[SavedWidget]`
    static func convertFromAndroidFormat(jsonDict: [String: Any]) throws -> [SavedWidget] {
        guard let widgetsArray = jsonDict["widgets"] as? [[String: Any]] else {
            throw NSError(domain: "WidgetsBackupConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid widgets format"])
        }

        let widgetsWithPosition = widgetsArray.compactMap { widgetDict -> (position: Int, widget: SavedWidget)? in
            guard let typeString = widgetDict["type"] as? String else {
                return nil
            }

            // Android serializes position as Int (JSON number), JSONSerialization may return Int or NSNumber
            let position: Int
            if let posInt = widgetDict["position"] as? Int {
                position = posInt
            } else if let posNumber = widgetDict["position"] as? NSNumber {
                position = posNumber.intValue
            } else {
                Logger.warn("Invalid position value for widget: \(typeString)", context: "WidgetsBackupConverter")
                return nil
            }

            var mappedType = typeString.lowercased()
            if mappedType == "block" {
                mappedType = "blocks"
            }

            guard let widgetType = WidgetType(rawValue: mappedType) else {
                Logger.warn("Unknown widget type from Android: \(typeString)", context: "WidgetsBackupConverter")
                return nil
            }

            var optionsData: Data?
            switch widgetType {
            case .blocks:
                if let prefs = jsonDict["blocksPreferences"] as? [String: Any] {
                    let iosOptions = BlocksWidgetOptions(
                        height: prefs["showBlock"] as? Bool ?? true,
                        time: prefs["showTime"] as? Bool ?? true,
                        date: prefs["showDate"] as? Bool ?? true,
                        transactionCount: prefs["showTransactions"] as? Bool ?? false,
                        size: prefs["showSize"] as? Bool ?? false,
                        weight: false,
                        difficulty: false,
                        hash: false,
                        merkleRoot: false,
                        showSource: prefs["showSource"] as? Bool ?? false
                    )
                    optionsData = try? JSONEncoder().encode(iosOptions)
                }
            case .news:
                if let prefs = jsonDict["headlinePreferences"] as? [String: Any] {
                    let iosOptions = NewsWidgetOptions(
                        showDate: prefs["showTime"] as? Bool ?? true,
                        showTitle: true,
                        showSource: prefs["showSource"] as? Bool ?? true
                    )
                    optionsData = try? JSONEncoder().encode(iosOptions)
                }
            case .facts:
                if let prefs = jsonDict["factsPreferences"] as? [String: Any] {
                    let iosOptions = FactsWidgetOptions(
                        showSource: prefs["showSource"] as? Bool ?? false
                    )
                    optionsData = try? JSONEncoder().encode(iosOptions)
                }
            case .weather:
                if let prefs = jsonDict["weatherPreferences"] as? [String: Any] {
                    let iosOptions = WeatherWidgetOptions(
                        showStatus: prefs["showTitle"] as? Bool ?? true,
                        showText: prefs["showDescription"] as? Bool ?? false,
                        showMedian: prefs["showCurrentFee"] as? Bool ?? false,
                        showNextBlockFee: prefs["showNextBlockFee"] as? Bool ?? false
                    )
                    optionsData = try? JSONEncoder().encode(iosOptions)
                }
            case .price:
                if let prefs = jsonDict["pricePreferences"] as? [String: Any] {
                    var selectedPairs = ["BTC/USD"]
                    if let pairsArray = prefs["enabledPairs"] as? [String] {
                        selectedPairs = pairsArray.map { pairType in
                            pairType.replacingOccurrences(of: "_", with: "/")
                        }
                        if selectedPairs.isEmpty {
                            selectedPairs = ["BTC/USD"]
                        }
                    }

                    let period = convertAndroidPeriodToIos(prefs["period"] as? String)
                    let iosOptions = PriceWidgetOptions(
                        selectedPairs: selectedPairs,
                        selectedPeriod: period,
                        showSource: prefs["showSource"] as? Bool ?? false
                    )
                    optionsData = try? JSONEncoder().encode(iosOptions)
                }
            case .calculator:
                break
            }

            return (position: position, widget: SavedWidget(type: widgetType, optionsData: optionsData))
        }

        let sortedWidgets = widgetsWithPosition.sorted { $0.position < $1.position }
        return sortedWidgets.map(\.widget)
    }

    // MARK: - Default Preferences Helpers

    private static func getDefaultBlocksPreferences() -> [String: Any] {
        let defaults = BlocksWidgetOptions()
        return [
            "showBlock": defaults.height,
            "showTime": defaults.time,
            "showDate": defaults.date,
            "showTransactions": defaults.transactionCount,
            "showSize": defaults.size,
            "showSource": defaults.showSource,
        ]
    }

    private static func getDefaultNewsPreferences() -> [String: Any] {
        let defaults = NewsWidgetOptions()
        return [
            "showTime": defaults.showDate,
            "showSource": defaults.showSource,
        ]
    }

    private static func getDefaultFactsPreferences() -> [String: Any] {
        let defaults = FactsWidgetOptions()
        return [
            "showSource": defaults.showSource,
        ]
    }

    private static func getDefaultWeatherPreferences() -> [String: Any] {
        let defaults = WeatherWidgetOptions()
        return [
            "showTitle": defaults.showStatus,
            "showDescription": defaults.showText,
            "showCurrentFee": defaults.showMedian,
            "showNextBlockFee": defaults.showNextBlockFee,
        ]
    }

    private static func getDefaultPricePreferences() -> [String: Any] {
        let defaults = PriceWidgetOptions()
        let androidPairs = defaults.selectedPairs.map { pair in
            pair.replacingOccurrences(of: "/", with: "_")
        }
        let androidPeriod = convertIosPeriodToAndroid(defaults.selectedPeriod)
        return [
            "enabledPairs": androidPairs.isEmpty ? ["BTC_USD"] : androidPairs,
            "period": androidPeriod,
            "showSource": defaults.showSource,
        ]
    }

    // MARK: - Period Conversion Helpers

    /// Converts iOS GraphPeriod rawValue ("1D", "1W", etc.) to Android enum name ("ONE_DAY", "ONE_WEEK", etc.)
    private static func convertIosPeriodToAndroid(_ period: GraphPeriod) -> String {
        switch period {
        case .oneDay:
            return "ONE_DAY"
        case .oneWeek:
            return "ONE_WEEK"
        case .oneMonth:
            return "ONE_MONTH"
        case .oneYear:
            return "ONE_YEAR"
        }
    }

    /// Converts Android GraphPeriod enum name ("ONE_DAY", "ONE_WEEK", etc.) to iOS GraphPeriod
    private static func convertAndroidPeriodToIos(_ androidPeriod: String?) -> GraphPeriod {
        guard let period = androidPeriod else {
            return .oneDay
        }

        switch period {
        case "ONE_DAY":
            return .oneDay
        case "ONE_WEEK":
            return .oneWeek
        case "ONE_MONTH":
            return .oneMonth
        case "ONE_YEAR":
            return .oneYear
        default:
            return GraphPeriod(rawValue: period) ?? .oneDay
        }
    }
}
