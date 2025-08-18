import SwiftUI

enum ChannelStatus {
    case pending
    case open
    case closed
}

struct LightningChannel: View {
    let capacity: UInt64
    let localBalance: UInt64
    let remoteBalance: UInt64
    let status: ChannelStatus
    let showLabels: Bool

    init(
        capacity: UInt64,
        localBalance: UInt64,
        remoteBalance: UInt64,
        status: ChannelStatus = .open,
        showLabels: Bool = false
    ) {
        self.capacity = capacity
        self.localBalance = localBalance
        self.remoteBalance = remoteBalance
        self.status = status
        self.showLabels = showLabels
    }

    private var spendingColor: Color {
        switch status {
        case .closed:
            return Color.gray5
        default:
            return Color.purple50
        }
    }

    private var spendingAvailableColor: Color {
        switch status {
        case .closed:
            return Color.gray3
        default:
            return Color.purpleAccent
        }
    }

    private var receivingColor: Color {
        switch status {
        case .closed:
            return Color.gray5
        default:
            return Color.white64
        }
    }

    private var receivingAvailableColor: Color {
        switch status {
        case .closed:
            return Color.gray3
        default:
            return Color.white
        }
    }

    private var spendingPercentage: CGFloat {
        guard capacity > 0 else { return 0 }
        return CGFloat(localBalance) / CGFloat(capacity)
    }

    private var receivingPercentage: CGFloat {
        guard capacity > 0 else { return 0 }
        return CGFloat(remoteBalance) / CGFloat(capacity)
    }

    private func formatNumber(_ number: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.groupingSize = 3
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    var body: some View {
        VStack(spacing: 8) {
            if showLabels {
                HStack {
                    CaptionMText(t("lightning__spending_label"))

                    Spacer()

                    CaptionMText(t("lightning__receiving_label"))
                }
            }

            HStack {
                HStack(spacing: 4) {
                    Image("arrow-up")
                        .resizable()
                        .frame(width: 14, height: 14)
                        .foregroundColor(spendingAvailableColor)

                    CaptionBText(formatNumber(localBalance), textColor: spendingAvailableColor)
                }

                Spacer()

                HStack(spacing: 4) {
                    Image("arrow-down")
                        .resizable()
                        .frame(width: 14, height: 14)
                        .foregroundColor(receivingAvailableColor)

                    CaptionBText(formatNumber(remoteBalance), textColor: receivingAvailableColor)
                }
            }

            HStack(spacing: 4) {
                // Spending bar (left)
                ZStack(alignment: .trailing) {
                    // Background
                    Rectangle()
                        .fill(spendingColor)
                        .cornerRadius(8, corners: [.topLeft, .bottomLeft])

                    // Available
                    Rectangle()
                        .fill(spendingAvailableColor)
                        .frame(width: spendingPercentage * 100.0)
                        .cornerRadius(8, corners: [.topLeft, .bottomLeft])
                }

                // Receiving bar (right)
                ZStack(alignment: .leading) {
                    // Background
                    Rectangle()
                        .fill(receivingColor)
                        .cornerRadius(8, corners: [.topRight, .bottomRight])

                    // Available
                    Rectangle()
                        .fill(receivingAvailableColor)
                        .frame(width: receivingPercentage * 100.0)
                        .cornerRadius(8, corners: [.topRight, .bottomRight])
                }
            }
            .frame(height: 16)
            .opacity(status == .pending ? 0.5 : 1.0)
        }
    }
}

// Extension to apply rounded corners to specific corners
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCornerShape(radius: radius, corners: corners))
    }
}

// Custom shape for specific rounded corners
struct RoundedCornerShape: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

struct LightningChannel_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 32) {
            // Example 1: Balanced channel
            VStack(alignment: .leading, spacing: 8) {
                SubtitleText("Balanced Channel")
                LightningChannel(
                    capacity: 200_000 as UInt64,
                    localBalance: 100_000 as UInt64,
                    remoteBalance: 100_000 as UInt64,
                    showLabels: true
                )
            }

            // Example 2: More local balance
            VStack(alignment: .leading, spacing: 8) {
                SubtitleText("More Local Balance")
                LightningChannel(
                    capacity: 200_000 as UInt64,
                    localBalance: 150_000 as UInt64,
                    remoteBalance: 50000 as UInt64
                )
            }

            // Example 3: More remote balance
            VStack(alignment: .leading, spacing: 8) {
                SubtitleText("More Remote Balance")
                LightningChannel(
                    capacity: 200_000 as UInt64,
                    localBalance: 50000 as UInt64,
                    remoteBalance: 150_000 as UInt64
                )
            }

            // Example 4: Pending channel
            VStack(alignment: .leading, spacing: 8) {
                SubtitleText("Pending Channel")
                LightningChannel(
                    capacity: 200_000 as UInt64,
                    localBalance: 100_000 as UInt64,
                    remoteBalance: 100_000 as UInt64,
                    status: .pending
                )
            }

            // Example 5: Closed channel
            VStack(alignment: .leading, spacing: 8) {
                SubtitleText("Closed Channel")
                LightningChannel(
                    capacity: 200_000 as UInt64,
                    localBalance: 100_000 as UInt64,
                    remoteBalance: 100_000 as UInt64,
                    status: .closed
                )
            }

            // Example 6: Based on the screenshot
            VStack(alignment: .leading, spacing: 8) {
                SubtitleText("Screenshot Example")
                LightningChannel(
                    capacity: 343_868 as UInt64,
                    localBalance: 85967 as UInt64,
                    remoteBalance: 257_901 as UInt64
                )
            }
        }
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
