import Foundation

enum LightningAmountConversion {
    /// Lightning amounts are commonly expressed in millisatoshis (msat).
    ///
    /// The UI and amount input operate in whole sats. When converting a minimum bound to sats we must round up:
    /// `100500 msat` means the minimum payable amount is `101 sat` (not `100 sat`).
    static func satsCeil(fromMsats msats: UInt64) -> UInt64 {
        let quotient = msats / Env.msatsPerSat
        let remainder = msats % Env.msatsPerSat
        return remainder == 0 ? quotient : quotient + 1
    }

    /// Converts msats → sats by rounding down (safe for maximum bounds).
    static func satsFloor(fromMsats msats: UInt64) -> UInt64 {
        msats / Env.msatsPerSat
    }
}
