import BitkitCore
import SwiftUI

struct ActivityRow: View {
    let item: Activity
    let feeEstimates: FeeRates?
    let titleOverride: String?

    init(item: Activity, feeEstimates: FeeRates?, titleOverride: String? = nil) {
        self.item = item
        self.feeEstimates = feeEstimates
        self.titleOverride = titleOverride
    }

    var body: some View {
        Group {
            switch item {
            case let .lightning(activity):
                ActivityRowLightning(item: activity, titleOverride: titleOverride)
            case let .onchain(activity):
                ActivityRowOnchain(item: activity, feeEstimates: feeEstimates, titleOverride: titleOverride)
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(16)
    }
}
