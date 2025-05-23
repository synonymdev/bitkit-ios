import Foundation
import SwiftUI

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

// MARK: - Widget Model

struct Widget: Identifiable {
    let id: UUID
    let type: WidgetType

    // Widget metadata computed on demand
    func metadata(fiatSymbol: String = "$") -> WidgetMetadata {
        return WidgetMetadata(type: type, fiatSymbol: fiatSymbol)
    }

    @ViewBuilder
    func view(isEditing: Bool, onEditingEnd: (() -> Void)? = nil) -> some View {
        switch type {
        case .block:
            // BlockWidget(isEditing: isEditing, onEditingEnd: onEditingEnd)
            PlaceholderWidget(type: type, message: "Coming Soon")
        case .calculator:
            // CalculatorWidget(isEditing: isEditing, onEditingEnd: onEditingEnd)
            PlaceholderWidget(type: type, message: "Coming Soon")
        case .facts:
            FactsWidget(isEditing: isEditing, onEditingEnd: onEditingEnd)
        case .news:
            NewsWidget(isEditing: isEditing, onEditingEnd: onEditingEnd)
        case .price:
            // PriceWidget(isEditing: isEditing, onEditingEnd: onEditingEnd)
            PlaceholderWidget(type: type, message: "Coming Soon")
        case .weather:
            // WeatherWidget(isEditing: isEditing, onEditingEnd: onEditingEnd)
            PlaceholderWidget(type: type, message: "Coming Soon")
        }
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
    case block = "blocks"
    case facts = "facts"
    case calculator = "calculator"
    case weather = "weather"
}

// MARK: - WidgetsViewModel

@MainActor
class WidgetsViewModel: ObservableObject {
    @Published var savedWidgets: [Widget] = []

    // Persist widget IDs using AppStorage
    @AppStorage("savedWidgetTypes") private var savedWidgetTypesData: Data = Data()

    // Default widgets for new installs and resets
    private static let defaultWidgets: [Widget] = [
        // Widget(id: UUID(), type: .price),
        Widget(id: UUID(), type: .news),
        Widget(id: UUID(), type: .facts),
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

        let newWidget = Widget(id: UUID(), type: type)
        savedWidgets.append(newWidget)
        persistWidgets()
    }

    /// Delete a widget
    func deleteWidget(_ type: WidgetType) {
        savedWidgets.removeAll { $0.type == type }
        persistWidgets()
    }

    /// Delete a widget by ID
    func deleteWidget(id: UUID) {
        savedWidgets.removeAll { $0.id == id }
        persistWidgets()
    }

    /// Reorder widgets
    func reorderWidgets(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
            sourceIndex >= 0, sourceIndex < savedWidgets.count,
            destinationIndex >= 0, destinationIndex < savedWidgets.count
        else { return }

        let widget = savedWidgets.remove(at: sourceIndex)
        savedWidgets.insert(widget, at: destinationIndex)
        persistWidgets()
    }

    /// Clear all persisted widgets and restore defaults
    func clearWidgets() {
        savedWidgets = WidgetsViewModel.defaultWidgets
        persistWidgets()
    }

    // MARK: - Private Methods

    private func loadSavedWidgets() {
        do {
            let savedTypes = try JSONDecoder().decode([WidgetType].self, from: savedWidgetTypesData)
            savedWidgets = savedTypes.map { Widget(id: UUID(), type: $0) }
        } catch {
            // If no saved data or decode fails, start with default widgets
            savedWidgets = WidgetsViewModel.defaultWidgets
            persistWidgets()
        }
    }

    private func persistWidgets() {
        do {
            let widgetTypes = savedWidgets.map { $0.type }
            savedWidgetTypesData = try JSONEncoder().encode(widgetTypes)
        } catch {
            print("Failed to persist widgets: \(error)")
        }
    }
}
