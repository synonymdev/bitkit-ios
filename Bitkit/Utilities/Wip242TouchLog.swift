import ObjectiveC
import UIKit

/// Throwaway flake probe: logs every touch each window receives, with the view a touch began on.
enum Wip242TouchLog {
    static func install() {
        guard let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
              let replacement = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.wip242_sendEvent(_:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }
}

extension UIWindow {
    @objc func wip242_sendEvent(_ event: UIEvent) {
        if event.type == .touches, let touches = event.allTouches {
            for touch in touches {
                let point = touch.location(in: self)
                let view = touch.view.map { String(describing: type(of: $0)) } ?? "nil"
                NSLog("WIP242 touch window=%@ level=%.0f key=%d phase=%d point=%@ view=%@ gestures=%@",
                      String(describing: type(of: self)), windowLevel.rawValue, isKeyWindow ? 1 : 0, touch.phase.rawValue,
                      "\(point)", view,
                      "\((touch.gestureRecognizers ?? []).map { "\(type(of: $0)):\($0.state.rawValue)" })")
            }
        }
        wip242_sendEvent(event)
    }
}
