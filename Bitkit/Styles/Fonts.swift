import SwiftUI

enum Fonts {
    static let regular = "InterTight-Regular"
    static let medium = "InterTight-Medium"
    static let semiBold = "InterTight-SemiBold"
    static let bold = "InterTight-Bold"
    static let extraBold = "InterTight-ExtraBold"
    static let black = "InterTight-Black"
    
    static func regular(size: CGFloat) -> Font {
        Font.custom(regular, size: size)
    }
    
    static func medium(size: CGFloat) -> Font {
        Font.custom(medium, size: size)
    }
    
    static func semiBold(size: CGFloat) -> Font {
        Font.custom(semiBold, size: size)
    }
    
    static func bold(size: CGFloat) -> Font {
        Font.custom(bold, size: size)
    }
    
    static func extraBold(size: CGFloat) -> Font {
        Font.custom(extraBold, size: size)
    }
    
    static func black(size: CGFloat) -> Font {
        Font.custom(black, size: size)
    }
} 