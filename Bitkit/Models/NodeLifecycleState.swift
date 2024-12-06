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
    case initializing

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
        case .initializing:
            return "Setting up wallet..."
        }
    }

    var systemImage: String {
        switch self {
        case .stopped:
            return "bolt.badge.xmark"
        case .starting:
            return "bolt.badge.clock"
        case .running:
            return "bolt.badge.checkmark.fill"
        case .stopping:
            return "bolt.badge.xmark"
        case .errorStarting:
            return "bolt.trianglebadge.exclamationmark.fill"
        case .initializing:
            return "bolt.badge.clock.fill"
        }
    }

    static func == (lhs: NodeLifecycleState, rhs: NodeLifecycleState) -> Bool {
        switch (lhs, rhs) {
        case (.stopped, .stopped),
             (.starting, .starting),
             (.running, .running),
             (.stopping, .stopping),
             (.initializing, .initializing):
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
