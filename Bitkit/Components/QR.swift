import CoreImage.CIFilterBuiltins
import SwiftUI

struct QR: View {
    let content: String
    var imageAsset: String?

    @State private var cachedImage: UIImage?
    @State private var cachedContent: String = ""
    var onPressed: (() -> Void)?

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        ZStack {
            Image(uiImage: cachedImage ?? generateQRCode(from: content))
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(Color.white)
                .cornerRadius(8)

            if let imageAsset {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 68, height: 68)

                    Image(imageAsset)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 50, height: 50)
                }
            }
        }
        .onTapGesture {
            if let onPressed {
                onPressed()
            }
        }
        .onAppear {
            // Generate initial QR code
            if cachedImage == nil {
                cachedContent = content
                cachedImage = generateQRCode(from: content)
            }
        }
        .onChange(of: content) { newContent in
            // Regenerate when content changes
            cachedContent = newContent
            cachedImage = generateQRCode(from: newContent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("QRCode")
        .accessibilityLabel(content)
        .accessibilityValue(content)
    }

    func generateQRCode(from string: String) -> UIImage {
        filter.message = Data(string.utf8)

        if let outputImage = filter.outputImage {
            if let cgImage = context.createCGImage(outputImage, from: outputImage.extent) {
                return UIImage(cgImage: cgImage)
            }
        }

        return UIImage(systemName: "xmark.circle") ?? UIImage()
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 20) {
            QR(
                content:
                "bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq?lightning=lnbc1500n1p3hk3sppp5k54t9c4p4u4tdgj0y8tqjp3kzjak8jtr0fwvnl2dpl5pvrm9gxsdqqcqzpgxqyz5vqsp5usxefww9jeqxv4ujmfwqhynz3rgf4x4k8kmjkjy8mkzctxt5vvq9qyyssqy4lgd8nj3vxjmnqyfgxnz3gqhykj8rd9v4xnz970m2cfqsz3vh7qwg0o4jj2mcwhzguktgc8hm8zmnwnp6f5ke4h8dkwrm8fqz2cpgqqqqqqqqlgqqqq",
                imageAsset: "btc-and-ln",
                onPressed: {
                    print("QR code pressed!")
                }
            )

            QR(content: "bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", imageAsset: "btc")

            QR(
                content:
                "lnbc1500n1p3hk3sppp5k54t9c4p4u4tdgj0y8tqjp3kzjak8jtr0fwvnl2dpl5pvrm9gxsdqqcqzpgxqyz5vqsp5usxefww9jeqxv4ujmfwqhynz3rgf4x4k8kmjkjy8mkzctxt5vvq9qyyssqy4lgd8nj3vxjmnqyfgxnz3gqhykj8rd9v4xnz970m2cfqsz3vh7qwg0o4jj2mcwhzguktgc8hm8zmnwnp6f5ke4h8dkwrm8fqz2cpgqqqqqqqqlgqqqq",
                imageAsset: "ln"
            )

            QR(content: "bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq")
        }
        .padding(.horizontal, 20)
    }
    .preferredColorScheme(.dark)
}
