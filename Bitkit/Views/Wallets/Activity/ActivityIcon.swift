import SwiftUI
import BitkitCore

struct ActivityIcon: View {
    let isLightning: Bool
    let status: PaymentState?
    let confirmed: Bool?
    let txType: PaymentType
    let size: CGFloat

    init(activity: Activity, size: CGFloat = 32) {
        self.size = size
        switch activity {
        case .lightning(let ln):
            self.isLightning = true
            self.status = ln.status
            self.confirmed = nil
            self.txType = ln.txType
        case .onchain(let onchain):
            self.isLightning = false
            self.status = nil
            self.confirmed = onchain.confirmed
            self.txType = onchain.txType
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
