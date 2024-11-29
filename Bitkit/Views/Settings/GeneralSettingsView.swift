import SwiftUI

struct GeneralSettingsView: View {
    var body: some View {
        List {
            NavigationLink(destination: DefaultUnitSettingsView()) {
                Text("Default Unit")
            }

            NavigationLink(destination: LocalCurrencySettingsView()) {
                Text("Local Currency")
            }
        }
        .navigationTitle("General")
    }
}

#Preview {
    NavigationView {
        GeneralSettingsView()
    }
} 