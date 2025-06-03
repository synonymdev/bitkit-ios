import Foundation
import SwiftUI

// MARK: - Widget Options Protocol

protocol WidgetOptionsProtocol: Codable, Equatable {
    static var defaultOptions: Self { get }
}

// MARK: - Widget Options Types

// Default options for each widget type
func getDefaultOptions(for type: WidgetType) -> Any {
    switch type {
    case .blocks:
        return BlocksWidgetOptions()
    case .facts:
        return FactsWidgetOptions()
    case .news:
        return NewsWidgetOptions()
    case .weather:
        return WeatherWidgetOptions()
    case .price, .calculator:
        return EmptyWidgetOptions()
    }
}

// Empty options for widgets that don't have customization yet
struct EmptyWidgetOptions: Codable, Equatable {
}

// MARK: - Widget Metadata

struct WidgetMetadata {
    let name: String
    let description: String
    let icon: String

    init(type: WidgetType, fiatSymbol: String = "$") {
        self.name = localizedString("widgets__\(type.rawValue)__name")
        self.description = localizedString("widgets__\(type.rawValue)__description", variables: ["fiatSymbol": fiatSymbol])
        self.icon = "\(type.rawValue)-widget"
    }
}

// MARK: - Widget Models

struct Widget: Identifiable {
    let type: WidgetType

    // Use type as identifier since only one widget per type is allowed
    var id: WidgetType { type }

    init(type: WidgetType) {
        self.type = type
    }

    // Widget metadata computed on demand
    func metadata(fiatSymbol: String = "$") -> WidgetMetadata {
        return WidgetMetadata(type: type, fiatSymbol: fiatSymbol)
    }

    @MainActor
    @ViewBuilder
    func view(widgetsViewModel: WidgetsViewModel, isEditing: Bool, onEditingEnd: (() -> Void)? = nil) -> some View {
        switch type {
        case .blocks:
            BlocksWidget(
                options: widgetsViewModel.getOptions(for: type, as: BlocksWidgetOptions.self),
                isEditing: isEditing,
                onEditingEnd: onEditingEnd
            )
        case .calculator:
            CalculatorWidget(isEditing: isEditing, onEditingEnd: onEditingEnd)
        case .facts:
            FactsWidget(
                options: widgetsViewModel.getOptions(for: type, as: FactsWidgetOptions.self),
                isEditing: isEditing,
                onEditingEnd: onEditingEnd
            )
        case .news:
            NewsWidget(
                options: widgetsViewModel.getOptions(for: type, as: NewsWidgetOptions.self),
                isEditing: isEditing,
                onEditingEnd: onEditingEnd
            )
        case .price:
            // PriceWidget(isEditing: isEditing, onEditingEnd: onEditingEnd)
            PlaceholderWidget(type: type, message: "Coming Soon")
        case .weather:
            WeatherWidget(
                options: widgetsViewModel.getOptions(for: type, as: WeatherWidgetOptions.self),
                isEditing: isEditing,
                onEditingEnd: onEditingEnd
            )
        }
    }
}

// Saved widget with options
struct SavedWidget: Codable, Identifiable {
    let type: WidgetType
    let optionsData: Data?

    // Use type as identifier since only one widget per type is allowed
    var id: WidgetType { type }

    init(type: WidgetType, optionsData: Data? = nil) {
        self.type = type
        self.optionsData = optionsData
    }

    // Convert to Widget for UI
    func toWidget() -> Widget {
        return Widget(type: type)
    }
}

// Placeholder widget for unimplemented widgets
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
    case price = "price"
    case news = "news"
    case blocks = "blocks"
    case facts = "facts"
    case calculator = "calculator"
    case weather = "weather"
}

// MARK: - WidgetsViewModel

@MainActor
class WidgetsViewModel: ObservableObject {
    @Published var savedWidgets: [Widget] = []

    // Single AppStorage key for widgets with their options
    @AppStorage("savedWidgets") private var savedWidgetsData: Data = Data()

    // In-memory storage for saved widgets with options
    private var savedWidgetsWithOptions: [SavedWidget] = []

    // Default widgets for new installs and resets
    private static let defaultSavedWidgets: [SavedWidget] = [
        // SavedWidget(type: .price),
        SavedWidget(type: .facts),
        SavedWidget(type: .news),
        SavedWidget(type: .blocks),
    ]

    init() {
        loadSavedWidgets()
    }

    // MARK: - Public Methods

    /// Check if a widget type is already saved
    func isWidgetSaved(_ type: WidgetType) -> Bool {
        return savedWidgets.contains { $0.type == type }
    }

    /// Save a new widget
    func saveWidget(_ type: WidgetType) {
        // Don't add duplicates
        guard !isWidgetSaved(type) else { return }

        let newSavedWidget = SavedWidget(type: type)
        savedWidgetsWithOptions.append(newSavedWidget)
        savedWidgets.append(newSavedWidget.toWidget())
        persistSavedWidgets()
    }

    /// Delete a widget
    func deleteWidget(_ type: WidgetType) {
        savedWidgetsWithOptions.removeAll { $0.type == type }
        savedWidgets.removeAll { $0.type == type }
        persistSavedWidgets()
    }

    /// Reorder widgets
    func reorderWidgets(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
            sourceIndex >= 0, sourceIndex < savedWidgets.count,
            destinationIndex >= 0, destinationIndex < savedWidgets.count
        else { return }

        let savedWidget = savedWidgetsWithOptions.remove(at: sourceIndex)
        savedWidgetsWithOptions.insert(savedWidget, at: destinationIndex)

        let widget = savedWidgets.remove(at: sourceIndex)
        savedWidgets.insert(widget, at: destinationIndex)

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

    /// Save options for a specific widget type
    func saveOptions<T: Codable>(_ options: T, for type: WidgetType) {
        do {
            let optionsData = try JSONEncoder().encode(options)

            // Find existing saved widget or create new one
            if let index = savedWidgetsWithOptions.firstIndex(where: { $0.type == type }) {
                // Update existing widget with new options
                savedWidgetsWithOptions[index] = SavedWidget(
                    type: type,
                    optionsData: optionsData
                )
            } else {
                // Create new saved widget with options
                savedWidgetsWithOptions.append(SavedWidget(type: type, optionsData: optionsData))
            }

            persistSavedWidgets()
        } catch {
            print("Failed to save widget options: \(error)")
        }
    }

    /// Check if widget has custom options (different from default)
    func hasCustomOptions(for type: WidgetType) -> Bool {
        switch type {
        case .blocks:
            let current: BlocksWidgetOptions = getOptions(for: type, as: BlocksWidgetOptions.self)
            let defaultOptions = BlocksWidgetOptions()
            return current != defaultOptions
        case .facts:
            let current: FactsWidgetOptions = getOptions(for: type, as: FactsWidgetOptions.self)
            let defaultOptions = FactsWidgetOptions()
            return current != defaultOptions
        case .news:
            let current: NewsWidgetOptions = getOptions(for: type, as: NewsWidgetOptions.self)
            let defaultOptions = NewsWidgetOptions()
            return current != defaultOptions
        case .weather:
            let current: WeatherWidgetOptions = getOptions(for: type, as: WeatherWidgetOptions.self)
            let defaultOptions = WeatherWidgetOptions()
            return current != defaultOptions
        case .price, .calculator:
            return false // No customization available yet
        }
    }

    // MARK: - Private Methods

    private func loadSavedWidgets() {
        do {
            savedWidgetsWithOptions = try JSONDecoder().decode([SavedWidget].self, from: savedWidgetsData)
            savedWidgets = savedWidgetsWithOptions.map { $0.toWidget() }
        } catch {
            // If no saved data or decode fails, start with default widgets
            savedWidgetsWithOptions = WidgetsViewModel.defaultSavedWidgets
            savedWidgets = savedWidgetsWithOptions.map { $0.toWidget() }
            persistSavedWidgets()
        }
    }

    private func persistSavedWidgets() {
        do {
            savedWidgetsData = try JSONEncoder().encode(savedWidgetsWithOptions)
        } catch {
            print("Failed to persist widgets: \(error)")
        }
    }
}
