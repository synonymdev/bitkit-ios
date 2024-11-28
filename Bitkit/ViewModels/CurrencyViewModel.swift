import Foundation
import SwiftUI

enum PrimaryDisplay: String {
    case bitcoin = "Bitcoin"
    case fiat = "Fiat"
}

@MainActor
class CurrencyViewModel: ObservableObject {
    @Published private(set) var rates: [FxRate] = []
    @Published private(set) var error: Error?
    @Published private(set) var hasStaleData: Bool = false
    @AppStorage("selectedCurrency") var selectedCurrency: String = "USD"
    @AppStorage("bitcoinDisplayUnit") var displayUnit: BitcoinDisplayUnit = .modern
    @AppStorage("primaryDisplay") var primaryDisplay: PrimaryDisplay = .bitcoin
    
    private let currencyService: CurrencyService
    private var refreshTimer: Timer?
    private var lastSuccessfulRefresh: Date?
    
    init(currencyService: CurrencyService = .shared) {
        self.currencyService = currencyService
        startPolling()
    }
    
    deinit {
        Task { @MainActor in
            stopPolling()
        }
    }
    
    func refresh() async {
        do {
            rates = try await currencyService.fetchLatestRates()
            lastSuccessfulRefresh = Date()
            error = nil
            hasStaleData = false
        } catch {
            self.error = error
            Logger.error(error, context: "Currency rates refresh failed")
            
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

extension CurrencyViewModel {
    func convert(sats: UInt64, to currency: String? = nil) -> ConvertedAmount? {
        let targetCurrency = currency ?? selectedCurrency
        guard let rate = currencyService.getCurrentRate(for: targetCurrency, from: rates) else {
            return nil
        }
        
        return currencyService.convert(sats: sats, rate: rate)
    }
}
