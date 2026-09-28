import Foundation
import PhotosUI
import SwiftUI
import Vision

struct QRCodePayload: Sendable {
    let string: String?
    let data: Data?
}

enum QRCodeImageDecoderError: Error {
    case invalidImage
    case noQRCode
}

enum QRCodeImageDecoder {
    static func decode(_ item: PhotosPickerItem) async throws -> QRCodePayload {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw QRCodeImageDecoderError.invalidImage
        }

        return try await Task.detached {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]

            #if targetEnvironment(simulator) && compiler(>=5.7)
                request.revision = VNDetectBarcodesRequestRevision3
            #endif

            let handler = VNImageRequestHandler(data: data, options: [:])
            try handler.perform([request])

            guard let observation = request.results?.first else {
                throw QRCodeImageDecoderError.noQRCode
            }

            return QRCodePayload(
                string: observation.payloadStringValue,
                data: observation.payloadData
            )
        }.value
    }
}
