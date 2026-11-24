import Paykit

/// Storage error contexts Paykit raises when the identity's shared state was saved by a newer Paykit.
private let newerPaykitStateContexts = [
    "SDK state blob contains trailing bytes",
    "unsupported SDK state blob version",
]

extension Error {
    func isPaykitStateFromNewerVersion() -> Bool {
        let error = (self as? AppError)?.underlyingError ?? self
        guard case let PaykitError.Storage(code, context) = error, code == "storage_error" else { return false }
        return newerPaykitStateContexts.contains { context.contains($0) }
    }

    /// Shared Paykit state saved by a newer Bitkit can only be read after an update, so the raw storage error is replaced.
    var profileErrorDescription: String {
        isPaykitStateFromNewerVersion() ? t("profile__update_required") : localizedDescription
    }
}
