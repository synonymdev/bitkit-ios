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
    private var refreshTask: Task<Void, Never>?
    
    init(currencyService: CurrencyService = .shared) {
        self.currencyService = currencyService
        
        // Load cached rates immediately
        if let cachedRates = currencyService.loadCachedRates() {
            self.rates = cachedRates
        }
        
        startPolling()
    }
    
    deinit {
        RunLoop.main.perform { [weak self] in
            Logger.debug("Stopping poll for rates")
            self?.stopPolling()
        }
    }
    
    func refresh() async {
        do {
            Logger.debug("Refreshing rates")
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
            self.refreshTask?.cancel()
            self.refreshTask = Task { @MainActor [weak self] in
                guard let self = self else { return }
                await self.refresh()
            }
        }
        
        // Initial refresh
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.refresh()
        }
    }
    
    private func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
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
