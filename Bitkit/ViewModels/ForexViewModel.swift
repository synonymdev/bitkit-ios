import Foundation
import SwiftUI

enum PrimaryDisplay: String {
    case bitcoin = "Bitcoin"
    case fiat = "Fiat"
}

@MainActor
class ForexViewModel: ObservableObject {
    @Published private(set) var rates: [ForexRate] = []
    @Published private(set) var error: Error?
    @Published private(set) var hasStaleData: Bool = false
    @AppStorage("selectedCurrency") var selectedCurrency: String = "USD"
    @AppStorage("bitcoinDisplayUnit") var displayUnit: BitcoinDisplayUnit = .modern
    @AppStorage("primaryDisplay") var primaryDisplay: PrimaryDisplay = .bitcoin
    
    private let forexService: ForexService
    private var refreshTimer: Timer?
    private var lastSuccessfulRefresh: Date?
    
    init(forexService: ForexService = .shared) {
        self.forexService = forexService
        startPolling()
    }
    
    deinit {
        Task { @MainActor in
            stopPolling()
        }
    }
    
    func refresh() async {
        do {
            rates = try await forexService.fetchLatestRates()
            lastSuccessfulRefresh = Date()
            error = nil
            hasStaleData = false
        } catch {
            self.error = error
            Logger.error(error, context: "Forex refresh failed")
            
            // Set stale data flag if no successful refresh in last 10 minutes
            if let lastRefresh = lastSuccessfulRefresh {
                hasStaleData = Date().timeIntervalSince(lastRefresh) > Env.fxRateStaleThreshold
            }
        }
    }
    
    private func startPolling() {
        stopPolling()
        
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Env.fxRateRefreshInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
        
        // Initial refresh
        Task {
            await refresh()
        }
    }
    
    private func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    func togglePrimaryDisplay() {
        primaryDisplay = primaryDisplay == .bitcoin ? .fiat : .bitcoin
    }
}

// MARK: - UI Helpers

extension ForexViewModel {
    func convert(sats: UInt64, to currency: String? = nil) -> ConvertedAmount? {
        let targetCurrency = currency ?? selectedCurrency
        guard let rate = forexService.getCurrentRate(for: targetCurrency, from: rates) else {
            return nil
        }
        
        return forexService.convert(sats: sats, rate: rate)
    }
    
    var availableCurrencies: [String] {
        forexService.getAvailableCurrencies(from: rates)
    }
} 