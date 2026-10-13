import Testing
@testable import PlayerCore

@Suite
struct PlayerStateMachineTests {
    private let legalTransitions: [(PlayerState, PlayerState)] = [
        (.idle, .preparing),
        (.preparing, .readyToPlay),
        (.preparing, .failed),
        (.readyToPlay, .playing),
        (.readyToPlay, .preparing),
        (.readyToPlay, .idle),
        (.playing, .paused),
        (.playing, .finished),
        (.playing, .failed),
        (.playing, .preparing),
        (.playing, .idle),
        (.paused, .playing),
        (.paused, .finished),
        (.paused, .preparing),
        (.paused, .idle),
        (.finished, .preparing),
        (.finished, .idle),
        (.failed, .preparing),
        (.failed, .idle),
        (.idle, .failed),
        (.readyToPlay, .failed),
        (.paused, .failed),
        (.finished, .failed),
    ]

    private let illegalTransitions: [(PlayerState, PlayerState)] = [
        (.idle, .playing),
        (.idle, .paused),
        (.idle, .readyToPlay),
        (.idle, .finished),
        (.preparing, .playing),
        (.preparing, .paused),
        (.preparing, .idle),
        (.readyToPlay, .paused),
        (.readyToPlay, .finished),
        (.playing, .readyToPlay),
        (.paused, .readyToPlay),
        (.finished, .playing),
        (.finished, .paused),
        (.failed, .playing),
        (.failed, .paused),
        (.failed, .finished),
    ]

    @Test
    func testStartsIdle() {
        #expect(PlayerStateMachine().state == .idle)
    }

    @Test
    func testAcceptsInitialState() {
        #expect(PlayerStateMachine(state: .playing).state == .playing)
    }

    @Test
    func testLegalTransitionsAreApplied() {
        for (from, to) in legalTransitions {
            var machine = PlayerStateMachine(state: from)

            let outcome = machine.transition(to: to)

            #expect(outcome == .applied, "\(from) → \(to) 应被接受")
            #expect(machine.state == to, "\(from) → \(to) 后状态应为 \(to)")
        }
    }

    @Test
    func testIllegalTransitionsAreRejectedWithoutSideEffects() {
        for (from, to) in illegalTransitions {
            var machine = PlayerStateMachine(state: from)

            let outcome = machine.transition(to: to)

            #expect(outcome == .rejected, "\(from) → \(to) 应被拒绝")
            #expect(machine.state == from, "\(from) → \(to) 被拒后状态不应改变")
        }
    }

    @Test
    func testFailureIsReachableFromEveryState() {
        for from in allStates {
            var machine = PlayerStateMachine(state: from)

            let outcome = machine.transition(to: .failed)

            #expect(
                outcome != .rejected,
                "\(from) → .failed 不得被拒绝：装配层对非 .applied 是静默 return，被拒的失败会从事件流里消失，UI 永远停在原状态"
            )
            #expect(machine.state == .failed, "\(from) → .failed 后状态应为 .failed")
        }
    }

    @Test
    func testSameStateIsUnchangedRatherThanRejected() {
        for state in allStates {
            var machine = PlayerStateMachine(state: state)

            let outcome = machine.transition(to: state)

            #expect(outcome == .unchanged, "\(state) → \(state) 应为无变化")
            #expect(machine.state == state)
        }
    }

    @Test
    func testCanTransitionMatchesTransitionOutcomeAcrossAllStatePairs() {
        for from in allStates {
            for to in allStates {
                var machine = PlayerStateMachine(state: from)

                let allowed = machine.canTransition(to: to)
                let outcome = machine.transition(to: to)

                #expect(allowed == (outcome == .applied), "\(from) → \(to) 的查询与实际结果应一致")
            }
        }
    }

    @Test
    func testCanTransitionIsFalseForSameState() {
        let machine = PlayerStateMachine(state: .playing)

        #expect(!machine.canTransition(to: .playing))
    }

    @Test
    func testCanTransitionDoesNotMutateState() {
        let machine = PlayerStateMachine(state: .readyToPlay)

        _ = machine.canTransition(to: .playing)

        #expect(machine.state == .readyToPlay)
    }

    @Test
    func testRejectionLeavesMachineUsable() {
        var machine = PlayerStateMachine(state: .idle)

        _ = machine.transition(to: .playing)
        let outcome = machine.transition(to: .preparing)

        #expect(outcome == .applied)
        #expect(machine.state == .preparing)
    }

    private var allStates: [PlayerState] {
        [.idle, .preparing, .readyToPlay, .playing, .paused, .finished, .failed]
    }
}
