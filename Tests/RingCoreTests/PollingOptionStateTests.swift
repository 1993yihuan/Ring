import XCTest
@testable import RingCore


final class PollingOptionStateTests: XCTestCase {
    private func snap(_ left: Bool = false, _ right: Bool = false,
                      flag: Bool? = nil, other: Bool = false,
                      keys: UInt64 = 0) -> OptionPollSnapshot {
        OptionPollSnapshot(leftDown: left, rightDown: right,
                           aggregateFlag: flag ?? (left || right),
                           otherModifiers: other, keyDownCount: keys)
    }

    func testLeftDoubleTapTriggersOnSecondDownAndReleasesAfterLongHold() {
        var poll = PollingOptionState()
        var gesture = OptionDoubleTapRecognizer()
        XCTAssertTrue(poll.consume(snap()).isEmpty)
        let steps: [(OptionPollSnapshot, TimeInterval, OptionDoubleTapRecognizer.Outcome)] = [
            (snap(true), 1000, .none),
            (snap(), 1000.06, .none),
            (snap(true), 1000.16, .triggered(.left)),
            (snap(true), 1010, .none),
            (snap(), 1010.01, .released(.left))
        ]
        for (sample, time, expected) in steps {
            let events = poll.consume(sample)
            let actual = events.map { gesture.handle($0, at: time) }
            if expected == .none {
                XCTAssertTrue(actual.isEmpty || actual == [.none])
            } else {
                XCTAssertEqual(actual, [expected])
            }
        }
    }

    func testRightSideDoubleTap() {
        var poll = PollingOptionState()
        _ = poll.consume(snap())
        XCTAssertEqual(poll.consume(snap(false, true)), [.optionDown(.right)])
        XCTAssertEqual(poll.consume(snap()), [.optionUp(.right)])
        XCTAssertEqual(poll.consume(snap(false, true)), [.optionDown(.right)])
        XCTAssertEqual(poll.consume(snap()), [.optionUp(.right)])
    }

    func testInitiallyHeldOptionNeedsReleaseBeforeFirstPress() {
        var poll = PollingOptionState()
        XCTAssertEqual(poll.consume(snap(true)), [])
        XCTAssertEqual(poll.consume(snap(true)), [])
        XCTAssertEqual(poll.consume(snap()), [])
        XCTAssertEqual(poll.consume(snap(true)), [.optionDown(.left)])
    }

    func testSideSwapInterruptsAndBlocksUntilRelease() {
        var poll = PollingOptionState()
        _ = poll.consume(snap())
        XCTAssertEqual(poll.consume(snap(true)), [.optionDown(.left)])
        XCTAssertEqual(poll.consume(snap(false, true)), [.interference])
        XCTAssertEqual(poll.consume(snap(false, true)), [])
        XCTAssertEqual(poll.consume(snap()), [])
        XCTAssertEqual(poll.consume(snap(false, true)), [.optionDown(.right)])
    }

    func testBothSidesHeldNeverTriggers() {
        var poll = PollingOptionState()
        _ = poll.consume(snap())
        XCTAssertEqual(poll.consume(snap(true, true)), [.interference])
        XCTAssertEqual(poll.consume(snap(true, true)), [])
        XCTAssertEqual(poll.consume(snap()), [])
        XCTAssertEqual(poll.consume(snap(true)), [.optionDown(.left)])
    }

    func testAggregateOnlyOptionIsNotGuessedAsOneSide() {
        var poll = PollingOptionState()
        _ = poll.consume(snap())
        XCTAssertEqual(poll.consume(snap(flag: true)), [.interference])
        XCTAssertEqual(poll.consume(snap(flag: true)), [])
        XCTAssertEqual(poll.consume(snap()), [])
        XCTAssertEqual(poll.consume(snap(true)), [.optionDown(.left)])
    }

    func testOtherModifierBreaksPendingOptionAndBlocksWhileHeld() {
        var poll = PollingOptionState()
        _ = poll.consume(snap())
        XCTAssertEqual(poll.consume(snap(true)), [.optionDown(.left)])
        XCTAssertEqual(poll.consume(snap(true, other: true)), [.interference])
        XCTAssertEqual(poll.consume(snap(true)), [])
        XCTAssertEqual(poll.consume(snap()), [])
        XCTAssertEqual(poll.consume(snap(true)), [.optionDown(.left)])
    }

    func testOtherKeyDownCounterBreaksPendingOption() {
        var poll = PollingOptionState()
        _ = poll.consume(snap(keys: 10))
        XCTAssertEqual(poll.consume(snap(true, keys: 10)), [.optionDown(.left)])
        XCTAssertEqual(poll.consume(snap(true, keys: 11)), [.interference])
        XCTAssertEqual(poll.consume(snap(keys: 11)), [])
        XCTAssertEqual(poll.consume(snap(true, keys: 11)), [.optionDown(.left)])
    }

    /// The physical key and the aggregate flag must agree: a held key the flags do not
    /// report is a conflicting read, never a press.
    func testHardwareDownWithoutTheAggregateFlagIsInterference() {
        var poll = PollingOptionState()
        _ = poll.consume(snap())
        XCTAssertEqual(poll.consume(snap(true, flag: false)), [.interference])
        XCTAssertEqual(poll.consume(snap()), [])
        XCTAssertEqual(poll.consume(snap(true)), [.optionDown(.left)])
    }

    func testNoEventsFromUnchangedSamples() {
        // An unrelated key after a new clean interval is a separate cancellation.
        var poll = PollingOptionState()
        _ = poll.consume(snap())
        for _ in 0..<120 { XCTAssertEqual(poll.consume(snap()), []) }
    }

    func testResetCannotSynthesizeAnExistingHold() {
        var poll = PollingOptionState()
        _ = poll.consume(snap())
        _ = poll.consume(snap(true))
        poll.reset()
        XCTAssertEqual(poll.consume(snap(true)), [])
        XCTAssertEqual(poll.consume(snap()), [])
    }
}
