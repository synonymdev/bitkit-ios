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
    let doesExist: Bool
    let isCpfpChild: Bool

    init(activity: Activity, size: CGFloat = 32, isCpfpChild: Bool = false) {
        self.size = size
        self.isCpfpChild = isCpfpChild
        switch activity {
        case let .lightning(ln):
            isLightning = true
            status = ln.status
            confirmed = nil
            txType = ln.txType
            isBoosted = false
            isTransfer = false
            doesExist = true
        case let .onchain(onchain):
            isLightning = false
            status = nil
            confirmed = onchain.confirmed
            txType = onchain.txType
            isBoosted = onchain.isBoosted
            isTransfer = onchain.isTransfer
            doesExist = onchain.doesExist
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
            } else if !doesExist {
                CircularIcon(
                    icon: "x-mark",
                    iconColor: .redAccent,
                    backgroundColor: .red16,
                    size: size
                )
            } else if isCpfpChild || (isBoosted && !(confirmed ?? false)) {
                CircularIcon(
                    icon: "timer-alt",
                    iconColor: .yellow,
                    backgroundColor: .yellow16,
                    size: size
                )
            } else {
                let paymentIcon = txType == PaymentType.sent ? "arrow-up" : "arrow-down"
                let (iconColor, backgroundColor): (Color, Color) = if isTransfer {
                    // From savings (to spending) = sent = orange, From spending (to savings) = received = purple
                    txType == .sent ? (.brandAccent, .brand16) : (.purpleAccent, .purple16)
                } else {
                    (.brandAccent, .brand16)
                }
                CircularIcon(
                    icon: isTransfer ? "arrow-up-down" : paymentIcon,
                    iconColor: iconColor,
                    backgroundColor: backgroundColor,
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
