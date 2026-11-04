import BitkitCore

extension OnChainInvoice {
    /// The Lightning invoice of a unified code. bitkit-core keeps each key as written, and a code in uppercase, as QR codes often
    /// are, carries it as `LIGHTNING`.
    var lightningParam: String? {
        guard let params else { return nil }
        return params["lightning"] ?? params.keys.sorted().first { $0.lowercased() == "lightning" }.flatMap { params[$0] }
    }
}
