import SwiftUI

/// Variants of the ellipse loader: ellipse colors, animation, and center content are defined per variant.
enum EllipseLoaderVariant {
    case sync
    case quickpay
    case transfer
    case hardware

    var accentColor: String {
        switch self {
        case .sync, .quickpay, .transfer: return "purple"
        case .hardware: return "blue"
        }
    }

    var centerScale: CGFloat {
        switch self {
        case .sync, .transfer, .hardware: return 0.85
        case .quickpay: return 1
        }
    }

    var ellipseAnimation: Animation {
        switch self {
        case .sync:
            return Animation.easeOut(duration: 1.5).repeatForever(autoreverses: true)
        case .quickpay:
            return Animation.easeOut(duration: 1.6).repeatForever(autoreverses: true)
        case .transfer:
            return Animation.easeInOut(duration: 3).repeatForever(autoreverses: true)
        case .hardware:
            return Animation.linear(duration: 1).repeatForever(autoreverses: true)
        }
    }
}

/// Center content for transfer variant: transfer figure with its own rotation animation.
private struct AnimatedTransferFigure: View {
    @State private var rotation: Double = 0

    var body: some View {
        Image("transfer-figure")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                    rotation = 90
                }
            }
    }
}

/// Center content for quickpay variant: coin stack with subtle rotation.
private struct AnimatedCoinStack: View {
    @State private var rotation: Double = 0

    var body: some View {
        Image("coin-stack-4")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                    rotation = 20
                }
            }
    }
}

/// Animated loading view with rotating ellipses and variant-specific center content.
/// Sizes to the available space so it can shrink on small screens and leave room for text.
struct EllipseLoader: View {
    let variant: EllipseLoaderVariant

    @State private var outerRotation: Double = 0
    @State private var innerRotation: Double = 0

    var body: some View {
        GeometryReader { geo in
            let container = min(geo.size.width, geo.size.height)
            let figure = container * variant.centerScale
            let inner = container * 0.7

            ZStack(alignment: .center) {
                Image("ellipse-outer-\(variant.accentColor)")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: container, height: container)
                    .rotationEffect(.degrees(outerRotation))

                Image("ellipse-inner-\(variant.accentColor)")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: inner, height: inner)
                    .rotationEffect(.degrees(innerRotation))

                centerContent
                    .frame(width: figure, height: figure)
            }
            .frame(width: container, height: container)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(variant.ellipseAnimation) { outerRotation = -180 }
            withAnimation(variant.ellipseAnimation) { innerRotation = 180 }
        }
    }

    @ViewBuilder private var centerContent: some View {
        switch variant {
        case .sync:
            Image("lightning")
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .quickpay:
            AnimatedCoinStack()
        case .transfer:
            AnimatedTransferFigure()
        case .hardware:
            // TODO: change to hardware figure
            Image("shield-figure")
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}
