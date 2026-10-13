import XCTest
@testable import PlayerCore

final class PlayerStateMachineTests: XCTestCase {
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
        (.failed, .idle)
    ]

    private let illegalTransitions: [(PlayerState, PlayerState)] = [
        (.idle, .playing),
        (.idle, .paused),
        (.idle, .readyToPlay),
        (.idle, .finished),
        (.idle, .failed),
        (.preparing, .playing),
        (.preparing, .paused),
        (.preparing, .idle),
        (.readyToPlay, .paused),
        (.readyToPlay, .finished),
        (.readyToPlay, .failed),
        (.playing, .readyToPlay),
        (.paused, .readyToPlay),
        (.paused, .failed),
        (.finished, .playing),
        (.finished, .paused),
        (.finished, .failed),
        (.failed, .playing),
        (.failed, .paused),
        (.failed, .finished)
    ]

    func testStartsIdle() {
        XCTAssertEqual(PlayerStateMachine().state, .idle)
    }

    func testAcceptsInitialState() {
        XCTAssertEqual(PlayerStateMachine(state: .playing).state, .playing)
    }

    func testLegalTransitionsAreApplied() {
        for (from, to) in legalTransitions {
            var machine = PlayerStateMachine(state: from)

            let outcome = machine.transition(to: to)

            XCTAssertEqual(outcome, .applied, "\(from) → \(to) 应被接受")
            XCTAssertEqual(machine.state, to, "\(from) → \(to) 后状态应为 \(to)")
        }
    }

    func testIllegalTransitionsAreRejectedWithoutSideEffects() {
        for (from, to) in illegalTransitions {
            var machine = PlayerStateMachine(state: from)

            let outcome = machine.transition(to: to)

            XCTAssertEqual(outcome, .rejected, "\(from) → \(to) 应被拒绝")
            XCTAssertEqual(machine.state, from, "\(from) → \(to) 被拒后状态不应改变")
        }
    }

    func testSameStateIsUnchangedRatherThanRejected() {
        for state in allStates {
            var machine = PlayerStateMachine(state: state)

            let outcome = machine.transition(to: state)

            XCTAssertEqual(outcome, .unchanged, "\(state) → \(state) 应为无变化")
            XCTAssertEqual(machine.state, state)
        }
    }

    func testCanTransitionMatchesTransitionOutcomeAcrossAllStatePairs() {
        for from in allStates {
            for to in allStates {
                var machine = PlayerStateMachine(state: from)

                let allowed = machine.canTransition(to: to)
                let outcome = machine.transition(to: to)

                XCTAssertEqual(allowed, outcome == .applied, "\(from) → \(to) 的查询与实际结果应一致")
            }
        }
    }

    func testCanTransitionIsFalseForSameState() {
        let machine = PlayerStateMachine(state: .playing)

        XCTAssertFalse(machine.canTransition(to: .playing))
    }

    func testCanTransitionDoesNotMutateState() {
        let machine = PlayerStateMachine(state: .readyToPlay)

        _ = machine.canTransition(to: .playing)

        XCTAssertEqual(machine.state, .readyToPlay)
    }

    func testRejectionLeavesMachineUsable() {
        var machine = PlayerStateMachine(state: .idle)

        _ = machine.transition(to: .playing)
        let outcome = machine.transition(to: .preparing)

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(machine.state, .preparing)
    }

    private var allStates: [PlayerState] {
        [.idle, .preparing, .readyToPlay, .playing, .paused, .finished, .failed]
    }
}
