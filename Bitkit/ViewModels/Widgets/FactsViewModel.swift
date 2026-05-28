import SwiftUI

/// ViewModel for handling Bitcoin facts
@MainActor
class FactsViewModel: ObservableObject {
    static let shared = FactsViewModel()

    @Published var fact: String = ""

    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 2 * 60 // 2 minutes

    /// Private initializer for the singleton instance
    private init() {
        fact = randomFact()
        startRefreshTimer()
    }

    /// Public initializer for previews and testing
    init(preview: Bool = true) {
        fact = randomFact()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fact = self?.randomFact() ?? ""
            }
        }
    }

    private func randomFact() -> String {
        BitcoinFacts.all.randomElement()!
    }
}
