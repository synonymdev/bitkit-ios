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
                .padding(.bottom, 16)

            // Custom search bar
            HStack(spacing: 0) {
                Image("magnifying-glass")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundColor(!searchText.isEmpty ? .brandAccent : .white64)
                TextField(t("common__search"), text: $searchText, backgroundColor: .clear, font: .custom(Fonts.regular, size: 17))
                    .frame(maxWidth: .infinity)
                    .offset(x: -5)
            }
            .frame(height: 48)
            .padding(.horizontal, 16)
            .background(Color.gray6)
            .cornerRadius(32)
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                if !availableMostUsed.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        CaptionMText(t("settings__general__currency_most_used"))
                            .padding(.top, 16)
                            .padding(.bottom, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(availableMostUsed, id: \.quote) { rate in
                            currencyRow(rate)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    CaptionMText(t("settings__general__currency_other"))
                        .padding(.top, 24)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(otherCurrencies, id: \.quote) { rate in
                        currencyRow(rate)
                    }
                }

                CaptionText(t("settings__general__currency_footer"))
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationStack {
        LocalCurrencySettingsView()
    }
    .environmentObject(CurrencyViewModel())
    .preferredColorScheme(.dark)
}
