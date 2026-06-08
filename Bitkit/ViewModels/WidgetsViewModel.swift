import Foundation
import SwiftUI

// MARK: - Widget Options Protocol

protocol WidgetOptionsProtocol: Codable, Equatable {
    static var defaultOptions: Self { get }
}

// MARK: - Widget Options Types

/// Default options for each widget type
func getDefaultOptions(for type: WidgetType) -> Any {
    switch type {
    case .suggestions, .calculator, .facts:
        return EmptyWidgetOptions()
    case .blocks:
        return BlocksWidgetOptions()
    case .news:
        return NewsWidgetOptions()
    case .weather:
        return WeatherWidgetOptions()
    case .price:
        return PriceWidgetOptions()
    }
}

/// Empty options for widgets that don't have customization yet
struct EmptyWidgetOptions: Codable, Equatable {}

// MARK: - Widget Metadata

struct WidgetMetadata {
    let name: String
    let description: String
    let icon: String

    init(type: WidgetType, fiatSymbol: String = "$") {
        name = t("widgets__\(type.rawValue)__name")
        description = t("widgets__\(type.rawValue)__description", variables: ["fiatSymbol": fiatSymbol])
        icon = "\(type.rawValue)-widget"
    }
}

// MARK: - Widget Size

/// Display size for a widget on the home grid.
/// `small` occupies a single grid column (half-width square); `wide` spans both columns.
enum WidgetSize: String, Codable, CaseIterable {
    case small
    case wide

    /// Default grid size for a freshly added widget of this type.
    static func `default`(for type: WidgetType) -> WidgetSize {
        switch type {
        case .price, .news, .suggestions: return .wide
        default: return .small
        }
    }
}

// MARK: - Widget Models

struct Widget: Identifiable {
    let type: WidgetType
    let size: WidgetSize

    init(type: WidgetType, size: WidgetSize = .wide) {
        self.type = type
        self.size = size
    }

    /// Use type as identifier since only one widget per type is allowed
    var id: WidgetType {
        type
    }

    /// Widget metadata computed on demand
    func metadata(fiatSymbol: String = "$") -> WidgetMetadata {
        return WidgetMetadata(type: type, fiatSymbol: fiatSymbol)
    }

    @MainActor
    @ViewBuilder
    func view(widgetsViewModel: WidgetsViewModel, isEditing: Bool, onEditingEnd: (() -> Void)? = nil, isPreview: Bool = false) -> some View {
        switch type {
        case .suggestions:
            SuggestionsWidget(isEditing: isEditing, onEditingEnd: onEditingEnd, isPreview: isPreview)
        case .blocks:
            BlocksWidget(
                options: widgetsViewModel.getOptions(for: type, as: BlocksWidgetOptions.self),
                size: size,
                isEditing: isEditing,
                onEditingEnd: onEditingEnd
            )
        case .calculator:
            CalculatorWidget(size: size, isEditing: isEditing, onEditingEnd: onEditingEnd)
        case .facts:
            FactsWidget(size: size, isEditing: isEditing, onEditingEnd: onEditingEnd)
        case .news:
            NewsWidget(
                options: widgetsViewModel.getOptions(for: type, as: NewsWidgetOptions.self),
                size: size,
                isEditing: isEditing,
                onEditingEnd: onEditingEnd
            )
        case .price:
            PriceWidget(
                options: widgetsViewModel.getOptions(for: type, as: PriceWidgetOptions.self),
                size: size,
                isEditing: isEditing,
                onEditingEnd: onEditingEnd
            )
        case .weather:
            WeatherWidget(
                options: widgetsViewModel.getOptions(for: type, as: WeatherWidgetOptions.self),
                size: size,
                isEditing: isEditing,
                onEditingEnd: onEditingEnd
            )
        }
    }
}

/// Saved widget with options
struct SavedWidget: Codable, Identifiable {
    let type: WidgetType
    let optionsData: Data?
    let size: WidgetSize

    /// Use type as identifier since only one widget per type is allowed
    var id: WidgetType {
        type
    }

    init(type: WidgetType, optionsData: Data? = nil, size: WidgetSize = .wide) {
        self.type = type
        self.optionsData = optionsData
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case optionsData
        case size
    }

    /// v60 saved blobs have no `size` key — default missing values to `.wide`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(WidgetType.self, forKey: .type)
        optionsData = try container.decodeIfPresent(Data.self, forKey: .optionsData)
        size = try container.decodeIfPresent(WidgetSize.self, forKey: .size) ?? .wide
    }

    /// Convert to Widget for UI
    func toWidget() -> Widget {
        return Widget(type: type, size: size)
    }
}

/// Placeholder widget for unimplemented widgets
struct PlaceholderWidget: View {
    let type: WidgetType
    let message: String

    var body: some View {
        VStack {
            Text("Widget Preview")
                .foregroundColor(.textSecondary)
            Text(message)
                .foregroundColor(.textSecondary)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .background(Color.white10)
        .cornerRadius(16)
    }
}

// MARK: - Widget Types

enum WidgetType: String, CaseIterable, Codable {
    case price
    case news
    case blocks
    case facts
    case weather
    case calculator
    case suggestions

    /// Whether the widget exposes configurable options in the edit sheet.
    var hasOptions: Bool {
        switch self {
        case .blocks, .news, .price, .weather:
            return true
        case .calculator, .suggestions, .facts:
            return false
        }
    }
}

// MARK: - WidgetsViewModel

@MainActor
class WidgetsViewModel: ObservableObject {
    @Published var savedWidgets: [Widget] = []

    private static let savedWidgetsKey = "savedWidgets"

    /// In-memory storage for saved widgets with options
    private var savedWidgetsWithOptions: [SavedWidget] = []

    @Published private var draftOptionsData: [WidgetType: Data] = [:]

    /// Default widgets for new installs and resets
    private static let defaultSavedWidgets: [SavedWidget] = [
        .suggestions, .price, .blocks, .facts, .weather, .calculator, .news,
    ].map { SavedWidget(type: $0, size: .default(for: $0)) }

    init() {
        loadSavedWidgets()
    }

    // MARK: - Public Methods

    /// Check if a widget type is already saved
    func isWidgetSaved(_ type: WidgetType) -> Bool {
        return savedWidgets.contains { $0.type == type }
    }

    /// Commit a widget to the grid at the chosen size, folding in any staged option edits.
    /// This is the single commit point: it persists the widget, syncs staged options to the
    /// iOS home-screen widget, and clears the draft.
    func saveWidget(_ type: WidgetType, size: WidgetSize = .wide) {
        let resolvedSize: WidgetSize = type == .suggestions ? .wide : size
        let draft = draftOptionsData[type]

        if let index = savedWidgetsWithOptions.firstIndex(where: { $0.type == type }) {
            let existing = savedWidgetsWithOptions[index]
            let optionsData = draft ?? existing.optionsData
            savedWidgetsWithOptions[index] = SavedWidget(type: type, optionsData: optionsData, size: resolvedSize)
        } else {
            savedWidgetsWithOptions.append(SavedWidget(type: type, optionsData: draft, size: resolvedSize))
        }

        if let draft {
            syncHomeScreenWidgetOptions(for: type, optionsData: draft)
            draftOptionsData[type] = nil
        }

        savedWidgets = savedWidgetsWithOptions.map { $0.toWidget() }
        persistSavedWidgets()
    }

    func getSize(for type: WidgetType) -> WidgetSize {
        savedWidgetsWithOptions.first(where: { $0.type == type })?.size ?? .wide
    }

    /// Delete a widget
    func deleteWidget(_ type: WidgetType) {
        savedWidgetsWithOptions.removeAll { $0.type == type }
        savedWidgets.removeAll { $0.type == type }
        draftOptionsData[type] = nil
        persistSavedWidgets()
    }

    /// Discard all uncommitted option edits. Call when the widgets sheet is dismissed so staged
    /// edits don't leak into a later session.
    func clearDrafts() {
        guard !draftOptionsData.isEmpty else { return }
        draftOptionsData = [:]
    }

    /// Reorder the widgets list by moving one widget to a new index.
    func reorderWidgets(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < savedWidgetsWithOptions.count,
              destinationIndex >= 0, destinationIndex < savedWidgetsWithOptions.count
        else { return }
        let moved = savedWidgetsWithOptions.remove(at: sourceIndex)
        savedWidgetsWithOptions.insert(moved, at: destinationIndex)
        savedWidgets = savedWidgetsWithOptions.map { $0.toWidget() }
        persistSavedWidgets()
    }

    /// Clear all persisted widgets and restore defaults
    func clearWidgets() {
        savedWidgetsWithOptions = WidgetsViewModel.defaultSavedWidgets
        savedWidgets = savedWidgetsWithOptions.map { $0.toWidget() }
        persistSavedWidgets()
    }

    // MARK: - Widget Options Methods

    /// Get options for a specific widget type
    func getOptions<T: Codable>(for type: WidgetType, as optionsType: T.Type) -> T {
        // A staged draft (uncommitted edit) shadows the persisted value so the preview reflects it.
        if let draft = draftOptionsData[type],
           let options = try? JSONDecoder().decode(optionsType, from: draft)
        {
            return options
        }

        // Find the saved widget with this type
        if let savedWidget = savedWidgetsWithOptions.first(where: { $0.type == type }),
           let optionsData = savedWidget.optionsData,
           let options = try? JSONDecoder().decode(optionsType, from: optionsData)
        {
            return options
        }

        // Return default options if none saved
        return getDefaultOptions(for: type) as! T
    }

    /// Stage option edits for a widget type without committing. The edit is held in memory and
    /// shadows the persisted value via `getOptions(...)`; it is only persisted (and synced to the
    /// iOS home-screen widget) once the user taps "Save Widget" (`saveWidget`).
    func stageOptions(_ options: some Codable, for type: WidgetType) {
        do {
            draftOptionsData[type] = try JSONEncoder().encode(options)
        } catch {
            Logger.error("Failed to stage widget options: \(error)", context: "WidgetsViewModel")
        }
    }

    /// Persist the given options to the shared App Group store and reload the iOS home-screen
    /// widget timeline. Called on commit (`saveWidget`) for the types that back a home-screen widget.
    private func syncHomeScreenWidgetOptions(for type: WidgetType, optionsData: Data) {
        switch type {
        case .price:
            if let options = try? JSONDecoder().decode(PriceWidgetOptions.self, from: optionsData) {
                syncPriceOptionsToHomeScreenWidget(options)
            }
        case .news:
            if let options = try? JSONDecoder().decode(NewsWidgetOptions.self, from: optionsData) {
                syncNewsOptionsToHomeScreenWidget(options)
            }
        case .blocks:
            if let options = try? JSONDecoder().decode(BlocksWidgetOptions.self, from: optionsData) {
                syncBlocksOptionsToHomeScreenWidget(options)
            }
        case .weather:
            if let options = try? JSONDecoder().decode(WeatherWidgetOptions.self, from: optionsData) {
                syncWeatherOptionsToHomeScreenWidget(options)
            }
        case .calculator, .facts, .suggestions:
            break
        }
    }

    /// Check if widget has custom options (different from default)
    func hasCustomOptions(for type: WidgetType) -> Bool {
        switch type {
        case .suggestions, .calculator, .facts:
            return false
        case .blocks:
            let current: BlocksWidgetOptions = getOptions(for: type, as: BlocksWidgetOptions.self)
            let defaultOptions = BlocksWidgetOptions()
            return current != defaultOptions
        case .news:
            let current: NewsWidgetOptions = getOptions(for: type, as: NewsWidgetOptions.self)
            let defaultOptions = NewsWidgetOptions()
            return current != defaultOptions
        case .weather:
            let current: WeatherWidgetOptions = getOptions(for: type, as: WeatherWidgetOptions.self)
            let defaultOptions = WeatherWidgetOptions()
            return current != defaultOptions
        case .price:
            let current: PriceWidgetOptions = getOptions(for: type, as: PriceWidgetOptions.self)
            let defaultOptions = PriceWidgetOptions()
            return current != defaultOptions
        }
    }

    // MARK: - Private Methods

    func loadSavedWidgets() {
        let widgetsData = UserDefaults.standard.data(forKey: Self.savedWidgetsKey) ?? .init()

        do {
            let decoded = try JSONDecoder().decode([SavedWidget].self, from: widgetsData)
            let deduped = Self.dedupedByType(decoded)
            savedWidgetsWithOptions = deduped
            savedWidgets = deduped.map { $0.toWidget() }
            // If we removed duplicates, rewrite the blob so the bad state disappears permanently.
            if deduped.count != decoded.count { persistSavedWidgets() }
        } catch {
            // If no saved data or decode fails, start with default widgets
            savedWidgetsWithOptions = WidgetsViewModel.defaultSavedWidgets
            savedWidgets = savedWidgetsWithOptions.map { $0.toWidget() }
            persistSavedWidgets()
        }
    }

    /// Collapses `widgets` to at most one entry per `WidgetType`, preserving the first-seen order.
    /// When the input contains duplicates, prefers the entry that carries `optionsData` so the
    /// user's customisation isn't lost — within duplicates, the first non-nil `optionsData` wins.
    static func dedupedByType(_ widgets: [SavedWidget]) -> [SavedWidget] {
        var preferredByType: [WidgetType: SavedWidget] = [:]
        var order: [WidgetType] = []
        for widget in widgets {
            if preferredByType[widget.type] == nil {
                preferredByType[widget.type] = widget
                order.append(widget.type)
                continue
            }
            if let existing = preferredByType[widget.type],
               existing.optionsData == nil,
               widget.optionsData != nil
            {
                preferredByType[widget.type] = widget
            }
        }
        return order.compactMap { preferredByType[$0] }
    }

    private func persistSavedWidgets() {
        do {
            let encodedData = try JSONEncoder().encode(savedWidgetsWithOptions)
            UserDefaults.standard.set(encodedData, forKey: Self.savedWidgetsKey)
        } catch {
            Logger.error("Failed to persist widgets: \(error)", context: "WidgetsViewModel")
        }
    }

    private func syncPriceOptionsToHomeScreenWidget(_ options: PriceWidgetOptions) {
        PriceHomeScreenWidgetOptionsStore.save(options)
        PriceHomeScreenWidgetOptionsStore.reloadHomeScreenWidgetIfNeeded()
    }

    private func syncNewsOptionsToHomeScreenWidget(_ options: NewsWidgetOptions) {
        NewsHomeScreenWidgetOptionsStore.save(options)
        NewsHomeScreenWidgetOptionsStore.reloadHomeScreenWidgetIfNeeded()
    }

    private func syncBlocksOptionsToHomeScreenWidget(_ options: BlocksWidgetOptions) {
        BlocksHomeScreenWidgetOptionsStore.save(options)
        BlocksHomeScreenWidgetOptionsStore.reloadHomeScreenWidgetIfNeeded()
    }

    private func syncWeatherOptionsToHomeScreenWidget(_ options: WeatherWidgetOptions) {
        WeatherHomeScreenWidgetOptionsStore.save(options)
        WeatherHomeScreenWidgetOptionsStore.reloadHomeScreenWidgetIfNeeded()
    }
}
