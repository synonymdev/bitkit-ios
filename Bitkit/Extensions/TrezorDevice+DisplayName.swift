import BitkitCore

/// Canonical hardware wallet display name: the Bitkit-side custom name when set. For a Trezor,
/// otherwise the device's own label when it differs from the factory model, otherwise the
/// vendor-prefixed model, falling back to "Trezor". A Jade has no label of its own and its model
/// already carries its name ("Jade", "Jade Plus"), so it shows the model, falling back to "Jade".
func resolveHwWalletName(
    label: String?,
    model: String?,
    customLabel: String? = nil,
    vendor: HwWalletVendor = .trezor
) -> String {
    if let customLabel, !customLabel.isEmpty {
        return customLabel
    }
    if vendor == .blockstream {
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedModel.isEmpty ? "Jade" : trimmedModel
    }
    if let label, !label.isEmpty, label != model {
        return label
    }
    guard let model else { return "Trezor" }
    return model.hasPrefix("Trezor") ? model : "Trezor \(model)"
}

extension HwKnownDevice {
    var displayName: String {
        resolveHwWalletName(label: label, model: model, customLabel: customLabel, vendor: vendor)
    }
}

extension TrezorDeviceInfo {
    var displayName: String {
        resolveHwWalletName(label: label, model: model)
    }
}
