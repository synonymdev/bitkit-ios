import SwiftUI

/// Paired step: the device's watch-only balance plus an editable "Label Funds" field, over the coin
/// illustration.
struct HwPairedView: View {
    let deviceName: String
    let balanceSats: UInt64
    @Binding var labelText: String
    let onFinish: () -> Void

    /// Coins illustration width as a fraction of the sheet — the 256-wide Visual in the 375-wide Figma frame.
    private let coinsWidthRatio: CGFloat = 256.0 / 375.0

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                Image("coin-stack-3")
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width * coinsWidthRatio)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                SheetHeader(title: t("hardware__paired_title"))
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 0) {
                    DisplayText(t("hardware__paired_header"), accentColor: .blueAccent)

                    BodyMText(t("hardware__paired_text"))
                        .padding(.top, 8)

                    HwPairedBalanceView(name: deviceName, sats: balanceSats)
                        .padding(.top, 32)

                    CaptionMText(t("hardware__paired_label"))
                        .padding(.top, 32)
                        .padding(.bottom, 8)

                    TextField(
                        deviceName,
                        text: $labelText,
                        testIdentifier: "HardwareWalletLabelInput"
                    )
                }
                .padding(.horizontal, 32)

                Spacer(minLength: 0)

                CustomButton(title: t("hardware__paired_finish"), shouldExpand: true) {
                    onFinish()
                }
                .accessibilityIdentifier("HardwareWalletPairedFinish")
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HardwareWalletPairedScreen")
    }
}

/// Device name over its watch-only balance, styled like the app's wallet balance rows.
private struct HwPairedBalanceView: View {
    let name: String
    let sats: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CaptionMText(name)

            HStack(spacing: 8) {
                Image("btc-circle-blue")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)

                MoneyText(sats: Int(clamping: sats), size: .subtitle, symbol: true, symbolColor: .textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    HwPairedView(
        deviceName: "Trezor Safe 3",
        balanceSats: 10_562_411,
        labelText: .constant("Trezor Safe 3"),
        onFinish: {}
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .environmentObject(CurrencyViewModel())
    .preferredColorScheme(.dark)
}
