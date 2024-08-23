//
//  QR.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import CoreImage.CIFilterBuiltins
import SwiftUI

struct QR: View {
    let content: String

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        Image(uiImage: generateQRCode(from: content))
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    VStack {
        QR(content: "Testing...")
            .frame(width: 200, height: 200)
    }
}
