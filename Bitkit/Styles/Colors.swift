import SwiftUI

extension Color {
    // MARK: - Accents
    static let brandAccent = Color(hex: 0xFF4400)
    static let blueAccent = Color(hex: 0x0085FF)
    static let greenAccent = Color(hex: 0x75BF72)
    static let purpleAccent = Color(hex: 0xB95CE8)
    static let redAccent = Color(hex: 0xE95164)
    static let yellowAccent = Color(hex: 0xFFD200)
    
    // MARK: - Base
    static let customBlack = Color.black
    static let customWhite = Color.white
    
    // MARK: - Gray Base
    static let gray6 = Color(hex: 0x151515)
    static let gray5 = Color(hex: 0x1C1C1D)
    static let gray3 = Color(hex: 0x48484A)
    static let gray2 = Color(hex: 0x636366)
    
    // MARK: - Alpha Colors
    static let black50 = Color.black.opacity(0.5)
    static let black92 = Color.black.opacity(0.92)
    static let white06 = Color.white.opacity(0.06)
    static let white08 = Color.white.opacity(0.08)
    static let white10 = Color.white.opacity(0.10)
    static let white16 = Color.white.opacity(0.16)
    static let white32 = Color.white.opacity(0.32)
    static let white50 = Color.white.opacity(0.50)
    static let white64 = Color.white.opacity(0.64)
    static let white80 = Color.white.opacity(0.80)
    
    static let blue24 = Color.blueAccent.opacity(0.24)
    static let brand08 = Color.brandAccent.opacity(0.08)
    static let brand16 = Color.brandAccent.opacity(0.16)
    static let brand24 = Color.brandAccent.opacity(0.24)
    static let brand32 = Color.brandAccent.opacity(0.32)
    static let brand50 = Color.brandAccent.opacity(0.50)
    static let green16 = Color.greenAccent.opacity(0.16)
    static let green24 = Color.greenAccent.opacity(0.24)
    static let green32 = Color.greenAccent.opacity(0.32)
    static let purple16 = Color.purpleAccent.opacity(0.16)
    static let purple24 = Color.purpleAccent.opacity(0.24)
    static let purple32 = Color.purpleAccent.opacity(0.32)
    static let purple50 = Color.purpleAccent.opacity(0.50)
    static let red16 = Color.redAccent.opacity(0.16)
    static let red24 = Color.redAccent.opacity(0.24)
    static let yellow16 = Color.yellowAccent.opacity(0.16)
    static let yellow24 = Color.yellowAccent.opacity(0.24)
}

// MARK: - Hex Initializer
extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 08) & 0xff) / 255,
            blue: Double((hex >> 00) & 0xff) / 255,
            opacity: alpha
        )
    }
}
