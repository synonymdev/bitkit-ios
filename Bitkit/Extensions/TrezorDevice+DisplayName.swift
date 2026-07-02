import BitkitCore

/// Canonical Trezor display name: the Bitkit-side custom name when set, otherwise the device's own
/// label when it differs from the factory model, otherwise the vendor-prefixed model, falling back
/// to "Trezor".
func resolveHwWalletName(label: String?, model: String?, customLabel: String? = nil) -> String {
    if let customLabel, !customLabel.isEmpty { return customLabel }
    if let label, !label.isEmpty, label != model { return label }
    guard let model else { return "Trezor" }
    return model.hasPrefix("Trezor") ? model : "Trezor \(model)"
}

extension TrezorKnownDevice {
    var displayName: String {
        resolveHwWalletName(label: label, model: model, customLabel: customLabel)
    }
}

extension TrezorDeviceInfo {
    var displayName: String {
        resolveHwWalletName(label: label, model: model)
    }
}
