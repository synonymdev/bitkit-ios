import SwiftUI
import UIKit

extension ScrollView {
    public func dismissKeyboardOnScroll() -> some View {
        return self.scrollDismissesKeyboard(.interactively)
    }
}
