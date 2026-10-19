import CoreImage.CIFilterBuiltins
import SwiftUI

struct QR: View {
    let content: String
    var imageAsset: String?

    @State private var cachedImage: UIImage?
    var onPressed: (() -> Void)?

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        ZStack {
            if let cachedImage {
                Image(uiImage: cachedImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(Color.white)
                    .cornerRadius(8)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }

            if let imageAsset {
                GeometryReader { geometry in
                    let size = min(68, min(geometry.size.width, geometry.size.height) * 0.2)
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: size, height: size)

                        Image(imageAsset)
                            .resizable()
                            .scaledToFit()
                            .frame(width: size * 50 / 68, height: size * 50 / 68)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .onTapGesture {
            if let onPressed {
                onPressed()
            }
        }
        .task(id: content) {
            cachedImage = generateQRCode(from: content)
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

extension QR {
    static func shareImage(content: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)

        if let outputImage = filter.outputImage {
            // Generate padded QR image for sharing
            let fixedSize = 400
            let padding: CGFloat = 16
            let qrSize = CGFloat(fixedSize) - (padding * 2)

            // Scale the QR code to fit exactly in the available space
            let scale = qrSize / outputImage.extent.width
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            let scaledOutputImage = outputImage.transformed(by: transform)

            if let cgImage = context.createCGImage(scaledOutputImage, from: scaledOutputImage.extent) {
                UIGraphicsBeginImageContextWithOptions(CGSize(width: fixedSize, height: fixedSize), false, 0)
                defer { UIGraphicsEndImageContext() }

                // Fill background with white
                UIColor.white.setFill()
                UIRectFill(CGRect(origin: .zero, size: CGSize(width: fixedSize, height: fixedSize)))

                // Calculate position to center the QR code with padding
                let qrRect = CGRect(
                    x: padding,
                    y: padding,
                    width: qrSize,
                    height: qrSize
                )

                // Draw the QR code in the padded area
                UIImage(cgImage: cgImage).draw(in: qrRect)

                return UIGraphicsGetImageFromCurrentImageContext()
            }
        }

        return nil
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
