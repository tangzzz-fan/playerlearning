public struct PlayerStateMachine: Sendable {
    public private(set) var state: PlayerState

    public init(state: PlayerState = .idle) {
        self.state = state
    }

    public func canTransition(to newState: PlayerState) -> Bool {
        outcome(for: newState) == .applied
    }

    @discardableResult
    public mutating func transition(to newState: PlayerState) -> PlayerStateTransition {
        let outcome = outcome(for: newState)
        if outcome == .applied {
            state = newState
        }
        return outcome
    }

    private func outcome(for newState: PlayerState) -> PlayerStateTransition {
        if newState == state {
            return .unchanged
        }
        return Self.isLegal(from: state, to: newState) ? .applied : .rejected
    }

    private static func isLegal(from current: PlayerState, to newState: PlayerState) -> Bool {
        switch (current, newState) {
        case (.idle, .preparing):
            true
        case (.preparing, .readyToPlay), (.preparing, .failed):
            true
        case (.readyToPlay, .playing), (.readyToPlay, .preparing), (.readyToPlay, .idle):
            true
        case (.playing, .paused), (.playing, .finished), (.playing, .failed),
             (.playing, .preparing), (.playing, .idle):
            true
        case (.paused, .playing), (.paused, .finished), (.paused, .preparing), (.paused, .idle):
            true
        case (.finished, .preparing), (.finished, .idle):
            true
        case (.failed, .preparing), (.failed, .idle):
            true
        default:
            false
        }
    }
}
