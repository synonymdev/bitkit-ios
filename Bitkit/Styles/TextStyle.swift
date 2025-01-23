import SwiftUI

// MARK: - Private Style Modifiers
fileprivate extension View {
    @ViewBuilder
    func kerningIfSupported(_ value: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            self.kerning(value)
        } else {
            self //There is no kerning in iOS 15, if we want to support it we need to use UIKit
        }
    }
}

// fileprivate struct DisplayTextStyle: ViewModifier {
//     let color: Color
    
//     func body(content: Content) -> some View {
//         content
//             .font(Fonts.black(size: 44))
//             .foregroundColor(color)
//             .textCase(.uppercase)
//             .kerningIfSupported(-1)
//     }
// }

fileprivate struct HeadlineTextStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.black(size: 30))
            .foregroundColor(color)
            .textCase(.uppercase)
            .kerningIfSupported(-1)
    }
}

fileprivate struct TitleTextStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.bold(size: 22))
            .foregroundColor(color)
            .kerningIfSupported(0.4)
    }
}

fileprivate struct SubtitleTextStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.bold(size: 17))
            .foregroundColor(color)
            .kerningIfSupported(0.4)
    }
}

fileprivate struct BodyMTextStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.regular(size: 17))
            .foregroundColor(color)
            .kerningIfSupported(0.4)
            .lineSpacing(5)
    }
}

fileprivate struct BodyMBoldTextStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.bold(size: 17))
            .foregroundColor(color)
            .kerningIfSupported(0.4)
            .lineSpacing(5)
    }
}

fileprivate struct BodySTextStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.regular(size: 15))
            .foregroundColor(color)
            .kerningIfSupported(0.4)
            .lineSpacing(5)
    }
}

fileprivate struct CaptionTextStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.regular(size: 13))
            .foregroundColor(color)
            .kerningIfSupported(0.4)
            .lineSpacing(5)
    }
}

fileprivate struct FootnoteTextStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.medium(size: 12))
            .foregroundColor(color)
            .kerningIfSupported(0.4)
            .lineSpacing(4)
    }
}

// MARK: - Public Style Extensions
extension View {
    // func displayTextStyle(color: Color = .textPrimary) -> some View {
    //     modifier(DisplayTextStyle(color: color))
    // }
    
    func headlineTextStyle(color: Color = .textPrimary) -> some View {
        modifier(HeadlineTextStyle(color: color))
    }
    
    func titleTextStyle(color: Color = .textPrimary) -> some View {
        modifier(TitleTextStyle(color: color))
    }
    
    func subtitleTextStyle(color: Color = .textPrimary) -> some View {
        modifier(SubtitleTextStyle(color: color))
    }
    
    func bodyMTextStyle(color: Color = .textPrimary) -> some View {
        modifier(BodyMTextStyle(color: color))
    }
    
    func bodyMBoldTextStyle(color: Color = .textPrimary) -> some View {
        modifier(BodyMBoldTextStyle(color: color))
    }
    
    func bodySTextStyle(color: Color = .textPrimary) -> some View {
        modifier(BodySTextStyle(color: color))
    }
    
    func captionTextStyle(color: Color = .textPrimary) -> some View {
        modifier(CaptionTextStyle(color: color))
    }
    
    func footnoteTextStyle(color: Color = .textPrimary) -> some View {
        modifier(FootnoteTextStyle(color: color))
    }
} 