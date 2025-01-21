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

fileprivate struct DisplayStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.black(size: 44))
            .foregroundColor(color)
            .textCase(.uppercase)
            .kerningIfSupported(-1)
    }
}

fileprivate struct HeadlineStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.black(size: 30))
            .foregroundColor(color)
            .textCase(.uppercase)
            .kerningIfSupported(-1)
    }
}

fileprivate struct TitleStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.bold(size: 22))
            .foregroundColor(color)
            .kerningIfSupported(0.4)
    }
}

fileprivate struct SubtitleStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.bold(size: 17))
            .foregroundColor(color)
            .kerningIfSupported(0.4)
    }
}

fileprivate struct BodyMStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.regular(size: 17))
            .foregroundColor(color)
            .kerningIfSupported(0.4)
            .lineSpacing(5)
    }
}

fileprivate struct BodyMBoldStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.bold(size: 17))
            .foregroundColor(color)
            .kerningIfSupported(0.4)
            .lineSpacing(5)
    }
}

fileprivate struct BodySStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.regular(size: 15))
            .foregroundColor(color)
            .kerningIfSupported(0.4)
            .lineSpacing(5)
    }
}

fileprivate struct CaptionStyle: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(Fonts.regular(size: 13))
            .foregroundColor(color)
            .kerningIfSupported(0.4)
            .lineSpacing(5)
    }
}

fileprivate struct FootnoteStyle: ViewModifier {
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
    func displayStyle(color: Color = .textPrimary) -> some View {
        modifier(DisplayStyle(color: color))
    }
    
    func headlineStyle(color: Color = .textPrimary) -> some View {
        modifier(HeadlineStyle(color: color))
    }
    
    func titleStyle(color: Color = .textPrimary) -> some View {
        modifier(TitleStyle(color: color))
    }
    
    func subtitleStyle(color: Color = .textPrimary) -> some View {
        modifier(SubtitleStyle(color: color))
    }
    
    func bodyMStyle(color: Color = .textPrimary) -> some View {
        modifier(BodyMStyle(color: color))
    }
    
    func bodyMBoldStyle(color: Color = .textPrimary) -> some View {
        modifier(BodyMBoldStyle(color: color))
    }
    
    func bodySStyle(color: Color = .textPrimary) -> some View {
        modifier(BodySStyle(color: color))
    }
    
    func captionStyle(color: Color = .textPrimary) -> some View {
        modifier(CaptionStyle(color: color))
    }
    
    func footnoteStyle(color: Color = .textPrimary) -> some View {
        modifier(FootnoteStyle(color: color))
    }
} 