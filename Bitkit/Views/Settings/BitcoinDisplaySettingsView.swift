import SwiftUI

struct BitcoinDisplaySettingsView: View {
    @EnvironmentObject var forex: ForexViewModel

    var body: some View {
        List {
            ForEach(BitcoinDisplayUnit.allCases, id: \.self) { unit in
                HStack {
                    VStack(alignment: .leading) {
                        Text(unit.rawValue)
                        Text(unit == .modern ? "Display in satoshis" : "Display in bitcoin")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if forex.displayUnit == unit {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    forex.displayUnit = unit
                }
            }
        }
        .navigationTitle("Bitcoin Display")
    }
}
