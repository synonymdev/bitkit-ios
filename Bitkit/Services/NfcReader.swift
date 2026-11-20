import CoreNFC
import Foundation

enum NfcReadError: Error, Equatable {
    case unavailable
    case busy
    case cancelled
    case timedOut
    case noPaymentRequest
    case multiplePaymentRequests
    case failed(String)

    /// Cancelling or letting the system sheet time out is a user choice, not an error worth a toast.
    var isSilent: Bool {
        self == .cancelled || self == .timedOut
    }

    /// Message for the app toast and the system NFC sheet.
    var message: String {
        switch self {
        case .unavailable: t("other__nfc_error_unavailable")
        case .multiplePaymentRequests: t("other__nfc_error_multiple")
        case .noPaymentRequest: t("other__nfc_error_text")
        case .busy, .cancelled, .timedOut, .failed: t("other__nfc_error_read_failed")
        }
    }
}

@MainActor
protocol NfcPaymentReading: AnyObject {
    var isAvailable: Bool { get }
    func readPaymentRequest(alertMessage: String) async throws -> String
}

/// Reads one payment request from an NFC tag, or from an Android phone emulating one, through the
/// system NFC sheet. iOS cannot detect tags in the background for custom schemes, so a read always
/// starts from a user action.
@MainActor
final class NfcReader: NSObject, NfcPaymentReading {
    static let shared = NfcReader()

    private var session: NFCNDEFReaderSession?
    private var continuation: CheckedContinuation<String, Error>?

    var isAvailable: Bool {
        NFCNDEFReaderSession.readingAvailable
    }

    func readPaymentRequest(alertMessage: String) async throws -> String {
        guard isAvailable else { throw NfcReadError.unavailable }
        guard continuation == nil else { throw NfcReadError.busy }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            // Kept open after a read so a tag without a payment request can be refused on the system sheet.
            let session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: false)
            session.alertMessage = alertMessage
            self.session = session
            session.begin()
        }
    }

    private func finish(_ result: Result<String, NfcReadError>) {
        guard let continuation else { return }
        self.continuation = nil
        session = nil
        continuation.resume(with: result.mapError { $0 as Error })
    }

    private func complete(_ session: NFCNDEFReaderSession, with result: Result<String, NfcReadError>) {
        guard session === self.session else { return }
        switch result {
        case .success:
            session.invalidate()
        case let .failure(error):
            session.invalidate(errorMessage: error.message)
        }
        finish(result)
    }

    nonisolated static func readError(for error: Error) -> NfcReadError? {
        guard let readerError = error as? NFCReaderError else {
            return .failed(error.localizedDescription)
        }
        switch readerError.code {
        case .readerSessionInvalidationErrorFirstNDEFTagRead:
            // Expected after a successful read; the result is delivered by didDetectNDEFs.
            return nil
        case .readerSessionInvalidationErrorUserCanceled:
            return .cancelled
        case .readerSessionInvalidationErrorSessionTimeout:
            return .timedOut
        default:
            return .failed(readerError.localizedDescription)
        }
    }
}

extension NfcReader: NFCNDEFReaderSessionDelegate {
    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        let records = messages.flatMap(\.records).map {
            NdefRecord(typeNameFormat: $0.typeNameFormat.rawValue, type: $0.type, payload: $0.payload)
        }
        let result = NdefPayloadParser.paymentRequest(from: records).mapError { error -> NfcReadError in
            switch error {
            case .empty: .noPaymentRequest
            case .multiplePayloads: .multiplePaymentRequests
            }
        }
        Task { @MainActor in
            self.complete(session, with: result)
        }
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        guard let readError = Self.readError(for: error) else { return }
        Task { @MainActor in
            guard session === self.session else { return }
            self.finish(.failure(readError))
        }
    }
}
