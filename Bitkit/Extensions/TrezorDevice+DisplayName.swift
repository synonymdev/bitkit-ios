import BitkitCore

/// Canonical Trezor display name: the user-set label when it differs from the factory model,
/// otherwise the vendor-prefixed model, falling back to "Trezor".
func resolveHwWalletName(label: String?, model: String?) -> String {
    if let label, !label.isEmpty, label != model { return label }
    guard let model else { return "Trezor" }
    return model.hasPrefix("Trezor") ? model : "Trezor \(model)"
}

extension TrezorKnownDevice {
    var displayName: String {
        resolveHwWalletName(label: label, model: model)
    }
}

extension TrezorDeviceInfo {
    var displayName: String {
        resolveHwWalletName(label: label, model: model)
    }
}
