@testable import Bitkit
import SwiftUI
import XCTest

@MainActor
final class PaykitContactKeysObserverTests: XCTestCase {
    func testStableKeysDoNotReplayWhenBodyRebuilds() async throws {
        let state = ContactKeysTestState(publicKeys: ["alice", "bob"])
        var received: [[String]] = []
        var bodyCount = 0
        let window = host(state: state, onBody: { bodyCount += 1 }) { received.append($0) }
        defer { unmount(window) }
        try await settle()

        for revision in 1 ... 5 {
            state.revision = revision
            state.publicKeys = revision.isMultiple(of: 2) ? ["alice", "bob"] : ["bob", "alice"]
            try await settle()
        }

        XCTAssertGreaterThan(bodyCount, 5)
        XCTAssertEqual(received, [["alice", "bob"]])
    }

    func testInitialEmptyKeysAndMembershipChangesAreDelivered() async throws {
        let state = ContactKeysTestState(publicKeys: [])
        var received: [[String]] = []
        let window = host(state: state) { received.append($0) }
        defer { unmount(window) }
        try await settle()

        for keys in [["alice"], ["bob", "alice"], ["bob"], []] {
            state.publicKeys = keys
            try await settle()
        }

        XCTAssertEqual(received, [[], ["alice"], ["alice", "bob"], ["bob"], []])
    }

    func testCallbackStateUpdatesDoNotRetriggerContactPreparation() async throws {
        let state = ContactKeysTestState(publicKeys: ["alice"])
        var preparationCount = 0
        var bodyCount = 0
        let window = host(state: state, onBody: { bodyCount += 1 }) { _ in
            preparationCount += 1
            if preparationCount < 5 {
                Task { @MainActor in state.revision += 1 }
            }
        }
        defer { unmount(window) }
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertGreaterThan(bodyCount, 1)
        XCTAssertEqual(preparationCount, 1)
    }

    private func host(
        state: ContactKeysTestState,
        onBody: @escaping () -> Void = {},
        onKeysChange: @escaping ([String]) -> Void
    ) -> UIWindow {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: ContactKeysTestView(
            state: state,
            onBody: onBody,
            onKeysChange: onKeysChange
        ))
        window.makeKeyAndVisible()
        return window
    }

    private func unmount(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }
}

@MainActor
private final class ContactKeysTestState: ObservableObject {
    @Published var publicKeys: [String]
    @Published var revision = 0

    init(publicKeys: [String]) {
        self.publicKeys = publicKeys
    }
}

private struct ContactKeysTestView: View {
    @ObservedObject var state: ContactKeysTestState
    let onBody: () -> Void
    let onKeysChange: ([String]) -> Void

    var body: some View {
        let _ = onBody()
        Text("Revision \(state.revision)")
            .modifier(PaykitContactKeysObserver(publicKeys: state.publicKeys, onChange: onKeysChange))
    }
}
