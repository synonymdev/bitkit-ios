import SwiftUI
import UIKit

extension ScrollView {
    public func dismissKeyboardOnScroll() -> some View {
        if #available(iOS 16.0, *) {
            return self.scrollDismissesKeyboard(.interactively)
        } else {
            return self.simultaneousGesture(DragGesture().onChanged { _ in
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            })
        }
    }
}
