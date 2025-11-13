import BitkitCore
import SwiftUI

struct ActivityIcon: View {
    let isLightning: Bool
    let status: PaymentState?
    let confirmed: Bool?
    let txType: PaymentType
    let size: CGFloat
    let isBoosted: Bool
    let isTransfer: Bool

    init(activity: Activity, size: CGFloat = 32) {
        self.size = size
        switch activity {
        case let .lightning(ln):
            isLightning = true
            status = ln.status
            confirmed = nil
            txType = ln.txType
            isBoosted = false
            isTransfer = false
        case let .onchain(onchain):
            isLightning = false
            status = nil
            confirmed = onchain.confirmed
            txType = onchain.txType
            isBoosted = onchain.isBoosted
            isTransfer = onchain.isTransfer
        }
    }

    var body: some View {
        Group {
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
            } else if isBoosted && !(confirmed ?? false) {
                CircularIcon(
                    icon: "timer-alt",
                    iconColor: .yellow,
                    backgroundColor: .yellow16,
                    size: size
                )
            } else {
                let paymentIcon = txType == PaymentType.sent ? "arrow-up" : "arrow-down"
                CircularIcon(
                    icon: isTransfer ? "arrow-up-down" : paymentIcon,
                    iconColor: .brandAccent,
                    backgroundColor: .brand16,
                    size: size
                )
            }
        }
        .accessibilityIdentifierIfPresent(iconAccessibilityIdentifier)
    }

    private var iconAccessibilityIdentifier: String? {
        if !isLightning, isBoosted, !(confirmed ?? false) {
            return "BoostingIcon"
        }
        return nil
    }
}
