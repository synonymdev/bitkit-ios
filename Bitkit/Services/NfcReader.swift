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
            let session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)
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
    nonisolated func readerSession(_: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
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
            self.finish(result)
        }
    }

    nonisolated func readerSession(_: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        guard let readError = Self.readError(for: error) else { return }
        Task { @MainActor in
            self.finish(.failure(readError))
        }
    }
}
