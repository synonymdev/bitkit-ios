/// Vendor-neutral views over the Trezor and Jade error predicates, for code shared by every vendor.
/// A `TrezorError` is never a `JadeError`, so for a Trezor error each one answers as its `isTrezor*`
/// counterpart does.
extension Error {
    func isHwUserCancellation() -> Bool {
        isTrezorUserCancellation() || isJadeUserCancellation()
    }

    func isHwDeviceBusy() -> Bool {
        isTrezorDeviceBusy() || isJadeDeviceBusy()
    }

    func isHwFirmwareError() -> Bool {
        isTrezorFirmwareError() || isJadeFirmwareError()
    }

    func isHwSessionFailure() -> Bool {
        isTrezorSessionFailure() || isJadeSessionFailure()
    }

    /// The vendor of the busy or locked device this error reports, so its busy copy can name it.
    var hwBusyVendor: HwWalletVendor? {
        if isJadeDeviceBusy() {
            return .blockstream
        }
        if isTrezorDeviceBusy() {
            return .trezor
        }
        return nil
    }
}
