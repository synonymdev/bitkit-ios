@testable import Bitkit
import SwiftUI
import XCTest

@MainActor
final class InitializingWalletViewTests: XCTestCase {
    func testSlowRetryWaitsForRunningNodeBeforeCompleting() async {
        let state = InitializationTestState()
        var completionCount = 0
        let completion = expectation(description: "Wallet initialization completes")
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: InitializationTestView(state: state) {
            completionCount += 1
            completion.fulfill()
        })
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        state.nodeLifecycleState = .errorStarting(cause: URLError(.notConnectedToInternet))
        try? await Task.sleep(for: .milliseconds(100))
        state.nodeLifecycleState = .initializing
        try? await Task.sleep(for: .seconds(6))
        XCTAssertEqual(completionCount, 0)

        state.nodeLifecycleState = .running
        await fulfillment(of: [completion], timeout: 6)
        XCTAssertEqual(completionCount, 1)
    }
}

@MainActor
private final class InitializationTestState: ObservableObject {
    @Published var nodeLifecycleState: NodeLifecycleState = .initializing
}

private struct InitializationTestView: View {
    @ObservedObject var state: InitializationTestState
    let onComplete: () -> Void

    var body: some View {
        if case .errorStarting = state.nodeLifecycleState {
            Color.clear
        } else {
            InitializingWalletView(nodeLifecycleState: $state.nodeLifecycleState, onComplete: onComplete)
        }
    }
}
