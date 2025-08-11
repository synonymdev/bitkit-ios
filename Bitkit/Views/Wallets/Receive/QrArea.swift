import SwiftUI

struct QrArea: View {
    let uri: String
    let imageAsset: String?
    let accentColor: Color
    @Binding var navigationPath: [ReceiveRoute]

    @State private var showCopyTooltip = false

    var body: some View {
        ZStack {
            QR(content: uri, imageAsset: imageAsset)

            if showCopyTooltip {
                Tooltip(text: localizedString("wallet__receive_copied"))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .offset(y: 80)
                    .allowsHitTesting(false)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showCopyTooltip)
            }
        }

        HStack {
            CustomButton(
                title: localizedString("common__edit"),
                size: .small,
                icon: Image("pencil").foregroundColor(accentColor),
                shouldExpand: true
            ) {
                navigationPath.append(.edit)
            }

            CustomButton(
                title: localizedString("common__copy"),
                size: .small,
                icon: Image("copy").foregroundColor(accentColor),
                shouldExpand: true
            ) {
                UIPasteboard.general.string = uri
                Haptics.play(.copiedToClipboard)

                // Show tooltip
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    showCopyTooltip = true
                }

                // Hide tooltip after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        showCopyTooltip = false
                    }
                }
            }

            ShareLink(item: URL(string: uri)!) {
                CustomButton(
                    title: localizedString("common__share"),
                    size: .small,
                    icon: Image("share").foregroundColor(accentColor),
                    shouldExpand: true
                )
            }
        }
        .padding(.vertical)
    }
}
