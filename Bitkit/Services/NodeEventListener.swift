import Foundation
import LDKNode

@MainActor
final class NodeEventListener {
    private var task: Task<Void, Never>?
    private var isTransitioning = false

    private enum LifecycleError: Error {
        case transitionInProgress
    }

    func start(node: Node, onEvent: @escaping (Event) async -> Void) async throws {
        guard !isTransitioning, task == nil else { throw LifecycleError.transitionInProgress }
        isTransitioning = true
        defer { isTransitioning = false }
        try await ServiceQueue.background(.ldk) { try node.start() }
        listen(node: node, onEvent: onEvent)
    }

    func stop(node: Node, onEvent: @escaping (Event) async -> Void) async throws {
        guard !isTransitioning else { throw LifecycleError.transitionInProgress }
        isTransitioning = true
        defer { isTransitioning = false }
        let previous = task
        previous?.cancel()
        await previous?.value
        task = nil

        do {
            try await ServiceQueue.background(.ldk) {
                do {
                    try node.stop()
                } catch NodeError.NotRunning {
                    // An unsuccessful start leaves a node without a running event consumer.
                }
            }
        } catch {
            if previous != nil {
                listen(node: node, onEvent: onEvent)
            }
            throw error
        }
    }

    private func listen(node: Node, onEvent: @escaping (Event) async -> Void) {
        task = Task {
            while !Task.isCancelled {
                // The pinned UniFFI nextEventAsync wait ignores Swift cancellation. Polling
                // keeps empty-queue waits cancellable and binds this consumer to one node.
                let event = try? await ServiceQueue.background(.ldk) { () -> Event? in
                    guard let event = node.nextEvent() else { return nil }
                    do {
                        try node.eventHandled()
                    } catch {
                        Logger.error(error, context: "node.eventHandled()")
                    }
                    return event
                }
                if let event {
                    // Finish delivery of an already acknowledged event before stop can return.
                    await onEvent(event)
                } else {
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch { return }
                }
            }
        }
    }
}
