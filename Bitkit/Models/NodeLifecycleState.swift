//
//  NodeLifecycleState.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/04.
//

import LDKNode

enum NodeLifecycleState: String {
    case stopped
    case starting
    case running
    case stopping

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
        }
    }
}
