import BitkitCore
import SwiftUI

struct ActivityRow: View {
    let item: Activity
    let feeEstimates: FeeRates?

    var body: some View {
        Group {
            switch item {
            case let .lightning(activity):
                ActivityRowLightning(item: activity)
            case let .onchain(activity):
                ActivityRowOnchain(item: activity, feeEstimates: feeEstimates)
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(16)
    }
}
