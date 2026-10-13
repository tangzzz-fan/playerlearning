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
        // `.failed` 是**唯一一条与源态无关**的边：只要播放器已经动过，任何时刻都可能收到失败。
        // 曾把 `.idle` / `.readyToPlay` / `.paused` / `.finished` → `.failed` 列为非法，
        // 后果不是"更严格"，而是**失败被静默吞掉** —— 装配层对非 `.applied` 直接 `return`，
        // 于是内核报了失败、事件流里却什么都没有，UI 永远停在原状态（见 docs/03 §Phase 2 反转记录）。
        if newState == .failed {
            return true
        }
        return switch (current, newState) {
        case (.idle, .preparing):
            true
        case (.preparing, .readyToPlay):
            true
        case (.readyToPlay, .playing), (.readyToPlay, .preparing), (.readyToPlay, .idle):
            true
        case (.playing, .paused), (.playing, .finished),
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
