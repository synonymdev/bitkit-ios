import SwiftUI
import UIKit

struct ScreenShotPreventMask: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UITextField()
        view.isSecureTextEntry = true
        view.text = ""
        view.isUserInteractionEnabled = false

        if let autoHideLayer = findAutoHideLayer(in: view) {
            autoHideLayer.backgroundColor = UIColor.white.cgColor
        } else {
            view.layer.sublayers?.last?.backgroundColor = UIColor.white.cgColor
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private func findAutoHideLayer(in view: UIView) -> CALayer? {
        if let layers = view.layer.sublayers {
            if let layer = layers.first(where: { layer in
                layer.delegate.debugDescription.contains("UITextLayoutCanvasView")
            }) {
                return layer
            }
        }

        return nil
    }
}

extension View {
    @ViewBuilder
    func screenshotPreventMask(_ isEnabled: Bool) -> some View {
        if isEnabled {
            mask(
                ScreenShotPreventMask()
                    .ignoresSafeArea()
            )
            .background(EmptyView())
        } else {
            self
        }
    }
}
