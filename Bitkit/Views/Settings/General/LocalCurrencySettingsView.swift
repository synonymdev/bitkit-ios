import SwiftUI

struct LocalCurrencySettingsView: View {
    @EnvironmentObject var currency: CurrencyViewModel
    @State private var searchText = ""

    private let mostUsedCurrencies = ["USD", "GBP", "CAD", "CNY", "EUR"]

    private var filteredRates: [FxRate] {
        guard !searchText.isEmpty else { return currency.rates }
        return currency.rates.filter { rate in
            rate.quote.localizedCaseInsensitiveContains(searchText) || rate.quoteName.localizedCaseInsensitiveContains(searchText)
                || rate.currencySymbol.localizedCaseInsensitiveContains(searchText)
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
        Button(action: {
            currency.selectedCurrency = rate.quote
            Task {
                await currency.refresh()
            }
        }) {
            SettingsListLabel(
                title: "\(rate.quote) (\(rate.currencySymbol))",
                rightIcon: currency.selectedCurrency == rate.quote ? .checkmark : nil
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__general__currency_local_title"))

            ScrollView(showsIndicators: false) {
                if !availableMostUsed.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        CaptionText(t("settings__general__currency_most_used").uppercased())
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(availableMostUsed, id: \.quote) { rate in
                            currencyRow(rate)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    CaptionText(t("settings__general__currency_other").uppercased())
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(otherCurrencies, id: \.quote) { rate in
                        currencyRow(rate)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        // TODO: Fix search
        .searchable(text: $searchText, prompt: t("common__search"))
    }
}

#Preview {
    NavigationStack {
        LocalCurrencySettingsView()
    }
    .environmentObject(CurrencyViewModel())
    .preferredColorScheme(.dark)
}
