//
//  NodeLifecycleState.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/04.
//

import LDKNode

enum NodeLifecycleState {
    case stopped
    case starting
    case running
    case stopping
    case errorStarting(cause: Error)

    var displayState: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .stopping:
            return "Stopping"
        case .errorStarting(let cause):
            return "Error starting: \(cause.localizedDescription)"
        }
    }

    var debugEmoji: String {
        switch self {
        case .stopped:
            return "❌"
        case .starting:
            return "⏳"
        case .running:
            return "⚡️"
        case .stopping:
            return "🛑"
        case .errorStarting:
            return "❌"
        }
    }

    static func == (lhs: NodeLifecycleState, rhs: NodeLifecycleState) -> Bool {
        switch (lhs, rhs) {
        case (.stopped, .stopped),
             (.starting, .starting),
             (.running, .running),
             (.stopping, .stopping):
            return true
        case (.errorStarting(let lhsCause), .errorStarting(let rhsCause)):
            return lhsCause.localizedDescription == rhsCause.localizedDescription
        default:
            return false
        }
    }

    static func != (lhs: NodeLifecycleState, rhs: NodeLifecycleState) -> Bool {
        return !(lhs == rhs)
    }
}
