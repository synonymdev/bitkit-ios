import SwiftUI

struct LocalCurrencySettingsView: View {
    @EnvironmentObject var currency: CurrencyViewModel
    @State private var searchText = ""
    
    private let mostUsedCurrencies = ["USD", "GBP", "CAD", "CNY", "EUR"]
    
    private var filteredRates: [FxRate] {
        guard !searchText.isEmpty else { return currency.rates }
        return currency.rates.filter { rate in
            rate.quote.localizedCaseInsensitiveContains(searchText) ||
                rate.quoteName.localizedCaseInsensitiveContains(searchText) ||
                rate.currencySymbol.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    private var availableMostUsed: [FxRate] {
        filteredRates.filter { mostUsedCurrencies.contains($0.quote) }
            .sorted { $0.quote < $1.quote }
    }
    
    private var otherCurrencies: [FxRate] {
        filteredRates.filter { !mostUsedCurrencies.contains($0.quote) }
            .sorted { $0.quote < $1.quote }
    }
    
    private func currencyRow(_ rate: FxRate) -> some View {
        HStack {
            Text("\(rate.quote) (\(rate.currencySymbol))")
            Spacer()
            if currency.selectedCurrency == rate.quote {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            currency.selectedCurrency = rate.quote
            Task {
                await currency.refresh()
            }
        }
    }
    
    var body: some View {
        List {
            if !availableMostUsed.isEmpty {
                Section("Most Used") {
                    ForEach(availableMostUsed, id: \.quote) { rate in
                        currencyRow(rate)
                    }
                }
            }
            
            Section("Other Currencies") {
                ForEach(otherCurrencies, id: \.quote) { rate in
                    currencyRow(rate)
                }
            }
        }
        .navigationTitle("Local Currency")
        .searchable(text: $searchText, prompt: "Search currencies")
    }
}

#Preview {
    NavigationView {
        LocalCurrencySettingsView()
            .environmentObject(CurrencyViewModel())
    }
}
