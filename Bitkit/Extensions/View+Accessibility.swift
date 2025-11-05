import SwiftUI

extension View {
    @ViewBuilder
    func accessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier, !identifier.isEmpty {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
