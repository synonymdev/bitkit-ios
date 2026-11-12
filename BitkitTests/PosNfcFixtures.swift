import Foundation

/// Requests as point-of-sale terminals present them over NFC.
///
/// A Square Register (2nd generation) serves `lightning:` and the uppercase BOLT11 invoice from its QR code as one
/// long-format NDEF URI record with identifier code 0x00. Numo, and Square in a later release, serve the BIP 321 form
/// without an address. `squareInvoice` is a real signet invoice of the size Square serves (a 465-byte NDEF message).
enum PosNfcFixtures {
    static let squareInvoice =
        "LNTBS79900N1P4TZWUQD962DCH2CTJV5S9YET8D9EHGETJYP8YVSEQWFJKWUN9WDEKJMMWYPNXJ7R5W4EX2GZNW96KZUN9YPFX2E" +
        "MFWD6X2U3QFERYXGRJV4NHYETNWD5K7M3QVE5HSAR4WFJJQ5M3W4SHYEFQ2FJKW6TNW3JHYGZWGEPJQUN9VAEX2UMND9HKUGRXD9" +
        "U8GATJV5PP5QURSWPC8QURSWPC8QURSWPC8QURSWPC8QURSWPC8QURSWPC8QURSSP5PYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPY" +
        "YSJZGFPYYSJZGFPYYS9QRSGQXQ97ZVUQCQZYSKUAHP9D6GKX2H8ERFH5E9NZZ52SY0UFR2F6VGK43QEJ0ZJU7FTYQYJTQE8705R2" +
        "KM9QS5NYFM3ZPR330ML3S3HWJP5D0RERD49QGT5CPUXAWEL"
    static let squareUri = "lightning:\(squareInvoice)"
    static let bip321Uri = "bitcoin:?lightning=\(squareInvoice)"
}
