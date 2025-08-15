import Foundation
import SwiftUI

@MainActor
final class SessionManager: ObservableObject {
    @Published var id = UUID()
    // When true, the next AppScene instance should skip showing the splash
    @Published var skipSplashOnce = false

    func bump() {
        id = UUID()
    }
}
