import BitkitCore
import SwiftUI

struct ActivityIcon: View {
    let isLightning: Bool
    let status: PaymentState?
    let confirmed: Bool?
    let txType: PaymentType
    let size: CGFloat

    init(activity: Activity, size: CGFloat = 32) {
        self.size = size
        switch activity {
        case let .lightning(ln):
            isLightning = true
            status = ln.status
            confirmed = nil
            txType = ln.txType
        case let .onchain(onchain):
            isLightning = false
            status = nil
            confirmed = onchain.confirmed
            txType = onchain.txType
        }
    }

    var body: some View {
        if isLightning {
            if status == .failed {
                CircularIcon(
                    icon: "x-circle",
                    iconColor: .purpleAccent,
                    backgroundColor: .purple16,
                    size: size
                )
            } else if status == .pending {
                CircularIcon(
                    icon: "hourglass-simple",
                    iconColor: .purpleAccent,
                    backgroundColor: .purple16,
                    size: size
                )
            } else {
                CircularIcon(
                    icon: txType == .sent ? "arrow-up" : "arrow-down",
                    iconColor: .purpleAccent,
                    backgroundColor: .purple16,
                    size: size
                )
            }
        } else {
            CircularIcon(
                icon: txType == .sent ? "arrow-up" : "arrow-down",
                iconColor: .brandAccent,
                backgroundColor: .brand16,
                size: size
            )
        }
    }
}
