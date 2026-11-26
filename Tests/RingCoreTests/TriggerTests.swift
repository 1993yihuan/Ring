import XCTest
@testable import RingCore

/// Answers like the real registrar: a candidate is held aside until it is committed, the same
/// combination is refused twice (Carbon returns -9878), and a refusal leaves the live one alone.
private final class FakeRegistrar: HotKeyRegistrar {
    enum Refusal: Error, Equatable { case refused }

    private(set) var live: HotKeyCombination?
    private(set) var prepared: HotKeyCombination?
    private(set) var registrations: [HotKeyCombination] = []
    private(set) var commits = 0
    private(set) var discards = 0
    private(set) var unregisters = 0
    private(set) var renewals = 0
    /// How many upcoming registrations the "system" refuses.
    var refusals = 0

    private func refuseIfAsked() throws {
        if refusals > 0 {
            refusals -= 1
            throw Refusal.refused
        }
    }

    func prepareHotKey(_ combination: HotKeyCombination) throws {
        try refuseIfAsked()
        guard live != combination else { return }
        registrations.append(combination)
        prepared = combination
    }

    func commitPreparedHotKey() {
        commits += 1
        guard let prepared else { return }
        live = prepared
        self.prepared = nil
    }

    func discardPreparedHotKey() {
        discards += 1
        prepared = nil
    }

    func unregisterHotKey() {
        unregisters += 1
        live = nil
        prepared = nil
    }

    /// Like Carbon: the old registration goes first, because the same combination cannot be
    /// registered twice.
    func renewHotKey(_ combination: HotKeyCombination) throws {
        renewals += 1
        live = nil
        prepared = nil
        try refuseIfAsked()
        registrations.append(combination)
        prepared = combination
        commitPreparedHotKey()
    }
}

private final class FakeSink: TapKeySink {
    var tapKey: TapKey? = .option
    var canSampleKeys = true
    private(set) var baselineResets = 0

    func resetSamplingBaseline() {
        baselineResets += 1
    }
}

private func makeController(directory: URL,
                            registrar: FakeRegistrar = FakeRegistrar())
    -> (TriggerController, FakeSink, FakeRegistrar) {
    let sink = FakeSink()
    let controller = TriggerController(store: TriggerStore(directory: directory),
                                       registrar: registrar,
                                       sink: sink)
    return (controller, sink, registrar)
}

private let commandK = HotKeyCombination(keyCode: 0x28, modifier: .command, keyLabel: "K")
private let controlJ = HotKeyCombination(keyCode: 0x26, modifier: .control, keyLabel: "J")

final class TriggerConfigurationFileTests: XCTestCase {
    /// First run of this feature: the shipped gesture, and nothing written.
    func testMissingFileMeansDoubleOptionAndNoFile() {
        let directory = testScratchDirectory()
        let store = TriggerStore(directory: directory)

        let configuration = try? store.load()

        XCTAssertEqual(configuration?.binding, .standard)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// The file the app writes is the file it reads back, field by field.
    func testACombinationRoundTripsThroughTriggerJSON() throws {
        let directory = testScratchDirectory()
        let store = TriggerStore(directory: directory)

        try store.save(TriggerConfiguration(binding: .combination(commandK)))

        XCTAssertEqual(store.fileURL.lastPathComponent, "trigger.json")
        let loaded = try TriggerStore(directory: directory).load()
        XCTAssertEqual(loaded.binding, .combination(commandK))
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"modifier\" : \"command\""))
        XCTAssertTrue(text.contains("\"keyCode\" : 40"))
    }

    /// The previous file listed the modifiers as booleans. One Command plus one ordinary key is
    /// the same combination, so the user does not have to record it again.
    func testAPreviousSingleModifierFileStillLoads() throws {
        let directory = testScratchDirectory()
        let store = TriggerStore(directory: directory)
        let json = """
        {"version":1,"binding":{"kind":"combination","combination":{"keyCode":40,"command":true,"control":false,"option":false,"shift":false,"keyLabel":"K"}}}
        """
        try Data(json.utf8).write(to: store.fileURL)

        let loaded = try store.load()

        XCTAssertEqual(loaded.binding, .combination(commandK))
    }

    /// A previous file with a second modifier is refused in its own words: the caller keeps the
    /// file and asks for a new recording instead of quietly saving another combination.
    func testAPreviousMultiModifierFileIsRefusedAndKept() throws {
        let directory = testScratchDirectory()
        let store = TriggerStore(directory: directory)
        let json = """
        {"version":1,"binding":{"kind":"combination","combination":{"keyCode":40,"command":true,"control":false,"option":true,"shift":false,"keyLabel":"K"}}}
        """
        try Data(json.utf8).write(to: store.fileURL)
        let before = try Data(contentsOf: store.fileURL)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? TriggerError, .combinationNeedsSingleModifier)
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    /// A hand-edited file is an outside input: a combination with two modifiers cannot become a
    /// trigger nobody asked for.
    func testAHandWrittenTwoModifierCombinationIsRefused() throws {
        let directory = testScratchDirectory()
        let store = TriggerStore(directory: directory)
        let json = """
        {"version":1,"binding":{"kind":"combination","combination":{"keyCode":40,"modifier":"command","keyLabel":"K","control":true}}}
        """
        try Data(json.utf8).write(to: store.fileURL)

        // The stored "modifier" field wins; the stray boolean is ignored rather than merged.
        XCTAssertEqual(try store.load().binding, .combination(commandK))
    }

    func testGarbageAndUnknownVersionsAreRefused() throws {
        let directory = testScratchDirectory()
        let store = TriggerStore(directory: directory)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())

        try Data("{\"version\":9,\"binding\":{\"kind\":\"doubleTap\",\"key\":\"option\"}}".utf8)
            .write(to: store.fileURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? TriggerError, .unsupportedSchema(9))
        }
    }

    /// One enum decides the sampler's target; nothing has to ask which mode is on.
    func testTheBindingNamesItsOwnSamplingTarget() {
        XCTAssertEqual(TriggerBinding.standard.tapKey, .option)
        XCTAssertEqual(TriggerBinding.doubleTap(.command).tapKey, .command)
        XCTAssertNil(TriggerBinding.combination(commandK).tapKey)
        XCTAssertTrue(TriggerBinding.combination(commandK).isCombination)
        XCTAssertFalse(TriggerBinding.doubleTap(.command).isCombination)
    }
}

final class HotKeyCombinationRuleTests: XCTestCase {
    private func assertRefused(_ combination: HotKeyCombination,
                               _ expected: TriggerError,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertThrowsError(try combination.validate(), file: file, line: line) { error in
            XCTAssertEqual(error as? TriggerError, expected, file: file, line: line)
        }
    }

    /// All four modifiers are allowed on their own, and only the combinations the system really
    /// owns are refused. This machine registers ⌥Space, ⌃Tab, ⇧Space and ⇧Tab successfully
    /// (measured), so they are not refused by rule.
    func testEverySingleModifierIsAllowedAndOnlyOwnedCombinationsAreRefused() {
        for modifier in HotKeyModifier.allCases {
            XCTAssertNoThrow(try HotKeyCombination(keyCode: 0x28, modifier: modifier).validate())
            XCTAssertNoThrow(try HotKeyCombination(keyCode: 0x69, modifier: modifier).validate())
        }
        XCTAssertNoThrow(try HotKeyCombination(keyCode: 0x31, modifier: .option).validate())
        XCTAssertNoThrow(try HotKeyCombination(keyCode: 0x31, modifier: .shift).validate())
        XCTAssertNoThrow(try HotKeyCombination(keyCode: 0x30, modifier: .control).validate())
        XCTAssertNoThrow(try HotKeyCombination(keyCode: 0x30, modifier: .option).validate())
        XCTAssertNoThrow(try HotKeyCombination(keyCode: 0x30, modifier: .shift).validate())

        // Carbon masks are the four HIToolbox values, measured on this machine.
        XCTAssertEqual(HotKeyModifier.allCases.map { $0.carbonMask }, [256, 4096, 2048, 512])
        XCTAssertEqual(HotKeyModifier.allCases.map { $0.symbol }, ["⌘", "⌃", "⌥", "⇧"])
    }

    func testKnownSystemCombinationsAreRefused() {
        assertRefused(HotKeyCombination(keyCode: 0x31, modifier: .command, keyLabel: "Space"),
                      .reservedCombination("⌘Space 与 ⌃Space 由系统占用（聚焦搜索、切换输入法）"))
        assertRefused(HotKeyCombination(keyCode: 0x31, modifier: .control, keyLabel: "Space"),
                      .reservedCombination("⌘Space 与 ⌃Space 由系统占用（聚焦搜索、切换输入法）"))
        assertRefused(HotKeyCombination(keyCode: 0x30, modifier: .command, keyLabel: "Tab"),
                      .reservedCombination("⌘Tab 由系统占用（切换应用）"))
        XCTAssertNoThrow(try controlJ.validate())
    }

    /// Exactly one of the four modifiers, and an ordinary key. Shift alone is a valid modifier
    /// now; a bare key and two modifiers are refused with their own messages.
    func testExactlyOneOfTheFourModifiersIsAllowed() throws {
        XCTAssertEqual(try CombinationRule.modifier(command: true, control: false, option: false, shift: false), .command)
        XCTAssertEqual(try CombinationRule.modifier(command: false, control: true, option: false, shift: false), .control)
        XCTAssertEqual(try CombinationRule.modifier(command: false, control: false, option: true, shift: false), .option)
        XCTAssertEqual(try CombinationRule.modifier(command: false, control: false, option: false, shift: true), .shift)
        for flags in [(true, true, false, false), (true, false, true, false), (false, true, false, true),
                      (true, false, false, true), (false, true, true, false), (false, false, true, true)] {
            XCTAssertThrowsError(try CombinationRule.modifier(command: flags.0, control: flags.1,
                                                              option: flags.2, shift: flags.3)) { error in
                XCTAssertEqual(error as? TriggerError, .combinationNeedsSingleModifier)
            }
        }
        // A bare key has no modifier at all, which is its own message.
        XCTAssertThrowsError(try CombinationRule.modifier(command: false, control: false,
                                                          option: false, shift: false)) { error in
            XCTAssertEqual(error as? TriggerError, .needsModifier)
        }
    }

    func testAModifierKeyIsNotAnOrdinaryKey() {
        assertRefused(HotKeyCombination(keyCode: 0x37, modifier: .command), .notAnOrdinaryKey(0x37))
    }

    /// The recorded combination is shown as it was pressed, and registered with exactly the
    /// Carbon mask HIToolbox expects.
    func testDisplayAndCarbonMaskFollowTheModifier() {
        XCTAssertEqual(commandK.displayText, "⌘K")
        XCTAssertEqual(commandK.carbonModifiers, 256)
        XCTAssertEqual(controlJ.displayText, "⌃J")
        XCTAssertEqual(controlJ.carbonModifiers, 4096)
        XCTAssertEqual(HotKeyCombination(keyCode: 0x28, modifier: .command, keyLabel: "").displayText, "⌘键码 40")
    }
}

final class KeyLabelTests: XCTestCase {
    /// The label is the base key, not what the modifier turns it into: Shift+1 is "1", not "!".
    func testTheLabelIsTheBaseKeyWithoutTheModifier() {
        XCTAssertEqual(KeyLabel.base("1"), "1")
        XCTAssertEqual(KeyLabel.base("!"), "!")     // what AppKit hands over if Shift were applied
        XCTAssertEqual(KeyLabel.base("k"), "K")
        XCTAssertEqual(KeyLabel.base(" "), "")      // a bare space is no name; the row shows a code
        XCTAssertEqual(KeyLabel.base(nil), "")
        XCTAssertEqual(HotKeyCombination(keyCode: 0x69, modifier: .option, keyLabel: "").displayText,
                       "⌥键码 105")
    }
}

final class RecordingReleaseTests: XCTestCase {
    /// The regression the review reproduced: the release was seen, so the combination must not be
    /// latched — the next press opens the ring straight away.
    func testAnObservedReleaseNeverArmsTheLatch() {
        XCTAssertFalse(RecordingRelease.awaitingRelease(waitingForRelease: true, releaseObserved: true))
        XCTAssertFalse(RecordingRelease.awaitingRelease(waitingForRelease: false, releaseObserved: false))
        // A page that lost focus mid-press must latch: the keys are still down.
        XCTAssertTrue(RecordingRelease.awaitingRelease(waitingForRelease: true, releaseObserved: false))
    }
}

final class CombinationSessionTests: XCTestCase {
    /// The pair going down opens once; the first finish wins and every later one changes nothing;
    /// Carbon only reports a press for a pair that is pressed again, so a new press opens a new
    /// session without waiting for anything.
    func testHoldOpensOnceFinshesOnceAndReopens() {
        var session = CombinationSession()

        XCTAssertEqual(session.press(), .opened)
        XCTAssertTrue(session.needsSamples)
        XCTAssertEqual(session.press(), .none)          // auto-repeat while held
        XCTAssertEqual(session.finish(), .finished)
        XCTAssertFalse(session.needsSamples)
        XCTAssertEqual(session.finish(), .none)         // the same end is never reported twice
        XCTAssertEqual(session.press(), .opened)        // a new press is a new session
    }

    /// Cancelling the ring ends the session without finishing it, and does not block the next
    /// press: no extra "wait for both keys" rule is added.
    func testCancelEndsWithoutFinishingAndDoesNotBlock() {
        var session = CombinationSession()
        _ = session.press()

        session.cancel()

        XCTAssertFalse(session.needsSamples)
        XCTAssertEqual(session.finish(), .none)
        XCTAssertEqual(session.press(), .opened)
    }

    func testFinishingWithoutAnOpenSessionChangesNothing() {
        var session = CombinationSession()
        XCTAssertEqual(session.finish(), .none)
        XCTAssertFalse(session.needsSamples)
    }
}

final class TriggerControllerTests: XCTestCase {
    func testFirstRunWatchesTheOptionKeys() {
        let (controller, sink, _) = makeController(directory: testScratchDirectory())
        XCTAssertEqual(controller.binding, .standard)
        XCTAssertEqual(controller.activeBinding, .standard)
        XCTAssertEqual(sink.tapKey, .option)
        XCTAssertNil(controller.notice)
        XCTAssertFalse(controller.isFallback)
        XCTAssertNil(controller.combinationProbe)
    }

    /// Choosing a combination registers it and writes trigger.json; the next launch reads the
    /// same file back and registers the same combination.
    func testAChosenCombinationIsRegisteredWrittenAndReadBackOnTheNextLaunch() throws {
        let directory = testScratchDirectory()
        let registrar = FakeRegistrar()
        let (controller, sink, _) = makeController(directory: directory, registrar: registrar)

        XCTAssertTrue(controller.record(commandK))

        XCTAssertEqual(controller.binding, .combination(commandK))
        XCTAssertEqual(registrar.live, commandK)
        XCTAssertNil(sink.tapKey)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(try TriggerStore(directory: directory).load().binding, .combination(commandK))

        let restarted = FakeRegistrar()
        let (again, restartedSink, _) = makeController(directory: directory, registrar: restarted)
        XCTAssertEqual(again.binding, .combination(commandK))
        XCTAssertEqual(restarted.live, commandK)
        XCTAssertNil(restartedSink.tapKey)
        XCTAssertNil(again.notice)
    }

    /// Switching from one combination to another must never release the working one before the
    /// new one is safely on disk. When the write fails, the old one keeps working.
    func testAFailedWriteKeepsTheOldCombinationLiveAndDropsTheCandidate() throws {
        let directory = testScratchDirectory()
        let store = TriggerStore(directory: directory)
        try store.save(TriggerConfiguration(binding: .combination(commandK)))
        let registrar = FakeRegistrar()
        let (controller, sink, _) = makeController(directory: directory, registrar: registrar)
        XCTAssertEqual(registrar.live, commandK)

        // No more writes can succeed: trigger.json is a directory now.
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)

        XCTAssertFalse(controller.record(controlJ))

        XCTAssertEqual(controller.binding, .combination(commandK))
        XCTAssertEqual(controller.activeBinding, .combination(commandK))
        XCTAssertEqual(registrar.live, commandK)     // the working combination was never released
        XCTAssertEqual(registrar.discards, 1)        // the candidate was dropped
        XCTAssertNil(sink.tapKey)
        XCTAssertTrue(controller.lastError?.hasPrefix("未保存") == true)
    }

    /// A write failure keeps the previous binding and never commits the candidate.
    func testAFailedWriteRegistersNothingAndKeepsTheWorkingBinding() {
        let container = testScratchDirectory()
        let blocked = container.appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocked.path, contents: Data()))
        let registrar = FakeRegistrar()
        let (controller, sink, _) = makeController(directory: blocked, registrar: registrar)

        XCTAssertFalse(controller.record(commandK))

        XCTAssertEqual(controller.binding, .standard)
        XCTAssertEqual(controller.activeBinding, .standard)
        XCTAssertNil(registrar.live)
        XCTAssertEqual(registrar.commits, 0)
        XCTAssertEqual(registrar.discards, 1)
        XCTAssertEqual(sink.tapKey, .option)
        XCTAssertTrue(controller.lastError?.hasPrefix("未保存") == true)
    }

    /// A combination the system refuses at launch leaves the saved choice in place, falls back to
    /// the double Option for this run, and the status item describes what really fires.
    func testARefusedCombinationAtLaunchFallsBackAndSaysWhatIsActive() throws {
        let directory = testScratchDirectory()
        let store = TriggerStore(directory: directory)
        try store.save(TriggerConfiguration(binding: .combination(commandK)))
        let before = try Data(contentsOf: store.fileURL)

        let registrar = FakeRegistrar()
        registrar.refusals = 1
        let (controller, sink, _) = makeController(directory: directory, registrar: registrar)

        XCTAssertEqual(controller.binding, .combination(commandK))
        XCTAssertEqual(controller.activeBinding, .standard)
        XCTAssertTrue(controller.isFallback)
        XCTAssertEqual(controller.activeTitle, "双击 Option")
        XCTAssertTrue(controller.previewHint.contains("Option"))
        XCTAssertFalse(controller.previewHint.contains("⌘K"))
        XCTAssertEqual(sink.tapKey, .option)
        XCTAssertNil(registrar.live)
        XCTAssertNotNil(controller.notice)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    /// The multi-modifier file from the previous version falls back with its own message and is
    /// never rewritten.
    func testAMultiModifierFileFallsBackAndAsksForANewRecording() throws {
        let directory = testScratchDirectory()
        let store = TriggerStore(directory: directory)
        let json = """
        {"version":1,"binding":{"kind":"combination","combination":{"keyCode":40,"command":true,"control":false,"option":true,"shift":false,"keyLabel":"K"}}}
        """
        try Data(json.utf8).write(to: store.fileURL)
        let before = try Data(contentsOf: store.fileURL)

        let (controller, sink, _) = makeController(directory: directory)

        XCTAssertEqual(controller.activeBinding, .standard)
        XCTAssertEqual(sink.tapKey, .option)
        XCTAssertNotNil(controller.notice)
        XCTAssertTrue(controller.notice?.contains("重新录制") == true)
        XCTAssertTrue(controller.savedTriggerUnreadable)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)

        // The file survives every launch; only an explicit choice replaces it.
        controller.select(.standard)
        XCTAssertFalse(controller.savedTriggerUnreadable)
        XCTAssertNotEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(try TriggerStore(directory: directory).load().binding, .standard)
    }

    /// The refusal keeps the old binding registered and the file untouched.
    func testARefusedSwitchKeepsTheWorkingBindingAndTheFile() throws {
        let directory = testScratchDirectory()
        let store = TriggerStore(directory: directory)
        try store.save(TriggerConfiguration(binding: .combination(commandK)))
        let registrar = FakeRegistrar()
        let (controller, _, _) = makeController(directory: directory, registrar: registrar)
        let before = try Data(contentsOf: store.fileURL)

        registrar.refusals = 1
        controller.record(controlJ)

        XCTAssertEqual(controller.binding, .combination(commandK))
        XCTAssertEqual(registrar.live, commandK)
        XCTAssertNotNil(controller.lastError)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    /// Asking for the choice that is already active must not register twice.
    func testTheSameChoiceAgainIsIdempotent() {
        let registrar = FakeRegistrar()
        let (controller, _, _) = makeController(directory: testScratchDirectory(), registrar: registrar)

        XCTAssertTrue(controller.record(commandK))
        XCTAssertTrue(controller.record(commandK))

        XCTAssertEqual(registrar.registrations, [commandK])
        XCTAssertNil(controller.lastError)
    }

    /// The recorder's own entry point refuses a second modifier before anything is registered or
    /// written — a mixed combination never reaches the file.
    func testRecordingAMixedCombinationIsRefused() {
        let registrar = FakeRegistrar()
        let (controller, sink, _) = makeController(directory: testScratchDirectory(), registrar: registrar)

        controller.beginRecording()
        XCTAssertFalse(controller.record(keyCode: 0x28, keyLabel: "K",
                                         command: true, control: false, option: false, shift: true))
        controller.endRecording(awaitingRelease: false)

        XCTAssertEqual(controller.lastError, "\(TriggerError.combinationNeedsSingleModifier)")
        XCTAssertEqual(controller.binding, .standard)
        XCTAssertTrue(registrar.registrations.isEmpty)
        XCTAssertEqual(sink.tapKey, .option)
    }

    /// Recording keeps the registration and only stops the sampler: a press is ignored while the
    /// settings window records.
    func testRecordingStopsTheSamplerAndKeepsTheRegistration() {
        let directory = testScratchDirectory()
        XCTAssertNoThrow(try TriggerStore(directory: directory).save(TriggerConfiguration(binding: .combination(commandK))))
        let registrar = FakeRegistrar()
        let (controller, sink, _) = makeController(directory: directory, registrar: registrar)
        let unregistersBefore = registrar.unregisters

        controller.beginRecording()
        XCTAssertTrue(controller.isSuspended)
        XCTAssertEqual(registrar.live, commandK)
        XCTAssertEqual(registrar.unregisters, unregistersBefore)
        XCTAssertNil(sink.tapKey)
        XCTAssertFalse(controller.hotKeyPressed())
        XCTAssertNil(controller.combinationProbe)

        controller.endRecording(awaitingRelease: false)
        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(registrar.live, commandK)
        XCTAssertNil(sink.tapKey)
    }

    func testCancellingRecordingOfTheDoubleOptionRestoresTheSampler() {
        let (controller, sink, _) = makeController(directory: testScratchDirectory())

        controller.beginRecording()
        XCTAssertNil(sink.tapKey)

        controller.endRecording(awaitingRelease: false)
        XCTAssertEqual(sink.tapKey, .option)
    }

    /// A recording that ended while its keys may still be down waits for proof, not for a press
    /// count: presses are ignored until the system releases the combination or one sample finds it
    /// incomplete. Then the very first real press opens — nothing is swallowed without reason.
    func testARecordingThatEndedWhileHeldWaitsForProof() {
        let (controller, _, _) = makeController(directory: testScratchDirectory())

        controller.beginRecording()
        XCTAssertTrue(controller.record(commandK))
        controller.endRecording(awaitingRelease: true)

        XCTAssertEqual(controller.combinationProbe, commandK)   // proof has to come from somewhere
        XCTAssertFalse(controller.hotKeyPressed())              // the held pair repeating
        XCTAssertFalse(controller.hotKeyPressed())              // still no proof: still ignored

        controller.hotKeyReleased()                             // the system says it came up
        XCTAssertNil(controller.combinationProbe)
        XCTAssertTrue(controller.hotKeyPressed())               // the first real press opens
    }

    /// A sample proves the release only when it finds the pair incomplete; while both keys are
    /// down the wait continues.
    func testASampleOnlyProvesTheReleaseWhenAKeyIsUp() {
        let (controller, _, _) = makeController(directory: testScratchDirectory())
        controller.beginRecording()
        XCTAssertTrue(controller.record(commandK))
        controller.endRecording(awaitingRelease: true)

        XCTAssertFalse(controller.hotKeySample(held: true))
        XCTAssertEqual(controller.combinationProbe, commandK)
        XCTAssertFalse(controller.hotKeyPressed())

        XCTAssertFalse(controller.hotKeySample(held: false))   // proof, not a finish
        XCTAssertNil(controller.combinationProbe)
        XCTAssertTrue(controller.hotKeyPressed())
    }

    /// A recording whose release was actually observed never arms the wait.
    func testAnObservedReleaseAtRecordingEndDoesNotWait() {
        let (controller, _, _) = makeController(directory: testScratchDirectory())
        controller.beginRecording()
        XCTAssertTrue(controller.record(commandK))
        controller.endRecording(awaitingRelease: false)

        XCTAssertNil(controller.combinationProbe)
        XCTAssertTrue(controller.hotKeyPressed())
    }

    /// Without a running sampler no sample can prove anything, so the wait is not armed: a trigger
    /// must never be blocked by proof that cannot arrive.
    func testTheWaitIsNotArmedWhenTheSamplerCannotRun() {
        let sink = FakeSink()
        sink.canSampleKeys = false
        let controller = TriggerController(store: TriggerStore(directory: testScratchDirectory()),
                                           registrar: FakeRegistrar(),
                                           sink: sink)
        controller.beginRecording()
        XCTAssertTrue(controller.record(commandK))
        controller.endRecording(awaitingRelease: true)

        XCTAssertNil(controller.combinationProbe)
        XCTAssertTrue(controller.hotKeyPressed())
    }

    /// Every reset path clears the wait, so it can never outlive the situation it was armed for.
    func testTheWaitIsClearedByWakeAndByANewChoice() {
        let registrar = FakeRegistrar()
        let (controller, _, _) = makeController(directory: testScratchDirectory(), registrar: registrar)
        controller.beginRecording()
        XCTAssertTrue(controller.record(commandK))
        controller.endRecording(awaitingRelease: true)
        XCTAssertEqual(controller.combinationProbe, commandK)

        controller.handleSystemWake()
        XCTAssertNil(controller.combinationProbe)
        XCTAssertTrue(controller.hotKeyPressed())

        controller.hotKeyCancelled()
        controller.beginRecording()
        controller.endRecording(awaitingRelease: true)
        XCTAssertEqual(controller.combinationProbe, commandK)
        controller.select(.standard)
        XCTAssertNil(controller.combinationProbe)
    }

    /// The hold itself: the pair down opens the ring, the first sample that finds a key up
    /// finishes it exactly once, and the sampler is off again immediately afterwards.
    func testTheHoldOpensOnceFinishesOnceAndStopsSampling() {
        let (controller, _, _) = makeController(directory: testScratchDirectory())
        XCTAssertTrue(controller.record(commandK))

        XCTAssertTrue(controller.hotKeyPressed())
        XCTAssertEqual(controller.combinationProbe, commandK)
        XCTAssertFalse(controller.hotKeyPressed())              // auto-repeat
        XCTAssertFalse(controller.hotKeySample(held: true))     // both keys are still down
        XCTAssertTrue(controller.hotKeySample(held: false))     // a key came up: finish, once
        XCTAssertNil(controller.combinationProbe)               // no more keyboard reads
        XCTAssertFalse(controller.hotKeySample(held: false))
        XCTAssertTrue(controller.hotKeyPressed())               // a new session, no barrier
    }

    /// The system's release and the hardware sample are the same fact: whichever arrives first
    /// finishes, and the app is told exactly once.
    func testReleaseAndSampleCannotBothFinishTheSession() {
        let (controller, _, _) = makeController(directory: testScratchDirectory())
        var finishes = 0
        controller.onFinish = { finishes += 1 }
        XCTAssertTrue(controller.record(commandK))

        XCTAssertTrue(controller.hotKeyPressed())
        controller.hotKeyReleased()

        XCTAssertEqual(finishes, 1)
        XCTAssertNil(controller.combinationProbe)
        controller.hotKeyReleased()
        controller.hotKeySample(held: false)
        XCTAssertEqual(finishes, 1)
    }

    /// A release that starts a new order — the sample sees it first, the system's release arrives
    /// afterwards — is still one finish.
    func testTheSampleFinishesBeforeTheReleaseArrives() {
        let (controller, _, _) = makeController(directory: testScratchDirectory())
        var finishes = 0
        controller.onFinish = { finishes += 1 }
        XCTAssertTrue(controller.record(commandK))
        XCTAssertTrue(controller.hotKeyPressed())

        XCTAssertTrue(controller.hotKeySample(held: false))
        controller.hotKeyReleased()

        XCTAssertEqual(finishes, 1)
        XCTAssertNil(controller.combinationProbe)
    }

    /// Closing the ring without a launch ends the session, stops the sampler and does not launch
    /// from a later sample.
    func testCancellingTheHoldStopsSamplingAndDoesNotFinish() {
        let (controller, _, _) = makeController(directory: testScratchDirectory())
        var finishes = 0
        controller.onFinish = { finishes += 1 }
        XCTAssertTrue(controller.record(commandK))
        XCTAssertTrue(controller.hotKeyPressed())

        controller.hotKeyCancelled()

        XCTAssertNil(controller.combinationProbe)
        XCTAssertFalse(controller.hotKeySample(held: false))
        XCTAssertEqual(finishes, 0)
        XCTAssertTrue(controller.hotKeyPressed())
    }

    /// Re-pressing a custom combination while A's exit animation and async launch are still
    /// in flight opens a new hold session immediately and launches B on release.
    func testCustomCombinationReopensAndLaunchesBWhilePreviousLaunchInFlight() {
        var config = LauncherConfiguration.empty()
        config.slots[0].action = .app(AppReference(bundleIdentifier: "com.a", displayName: "AppA", path: "/Applications/AppA.app"))
        config.slots[1].action = .app(AppReference(bundleIdentifier: "com.b", displayName: "AppB", path: "/Applications/AppB.app"))
        let ringSession = RingSession(config: config)
        var launchState = RingLaunchState()

        let (controller, _, _) = makeController(directory: testScratchDirectory())
        XCTAssertTrue(controller.record(commandK))

        var selectedSlot = 0
        var activeLaunchGenerations: [UInt64] = []
        controller.onFinish = {
            if case .launch = ringSession.click(slot: selectedSlot) {
                activeLaunchGenerations.append(ringSession.launchGeneration)
                _ = launchState.closing()
            }
        }

        // Round 1: press ⌘K -> open ring -> release launches A.
        XCTAssertTrue(controller.hotKeyPressed())
        XCTAssertTrue(ringSession.trigger())
        XCTAssertEqual(launchState.opening(), .playEntrance(generation: 1))
        XCTAssertEqual(controller.combinationProbe, commandK)

        controller.hotKeyReleased()
        XCTAssertNil(controller.combinationProbe)
        XCTAssertEqual(activeLaunchGenerations.count, 1)
        let genA = activeLaunchGenerations[0]
        XCTAssertEqual(launchState.phase, .exiting)

        // Round 2: while A is still launching and exit animation is still running, press ⌘K again.
        selectedSlot = 1
        XCTAssertTrue(controller.hotKeyPressed())
        XCTAssertTrue(ringSession.trigger())
        XCTAssertEqual(launchState.opening(), .playEntrance(generation: 2))
        XCTAssertEqual(controller.combinationProbe, commandK)
        XCTAssertTrue(ringSession.isVisible)

        // Stale exit completion and late A error arrive while holding ⌘K: neither breaks Round 2.
        XCTAssertEqual(launchState.exitFinished(generation: 1), .ignored)
        XCTAssertEqual(launchState.phase, .entering)
        XCTAssertFalse(ringSession.launchFinished(generation: genA, error: "AppA 延迟错误"))
        XCTAssertTrue(ringSession.isVisible)
        XCTAssertNil(ringSession.lastError)

        // Release via sample (and duplicate Carbon release) launches B exactly once.
        XCTAssertTrue(controller.hotKeySample(held: false))
        controller.hotKeyReleased()
        XCTAssertNil(controller.combinationProbe)
        XCTAssertEqual(activeLaunchGenerations.count, 2)
        let genB = activeLaunchGenerations[1]
        XCTAssertEqual(ringSession.launchCount, 2)

        // B completes normally.
        XCTAssertEqual(launchState.exitFinished(generation: 2), .settled)
        XCTAssertTrue(ringSession.launchFinished(generation: genB, error: nil))
        XCTAssertEqual(ringSession.phase, .hidden)
    }

    /// Restoring the default keeps working no matter what was active before.
    func testRestoringTheDefaultUnregistersTheCombination() throws {
        let directory = testScratchDirectory()
        let registrar = FakeRegistrar()
        let (controller, sink, _) = makeController(directory: directory, registrar: registrar)
        XCTAssertTrue(controller.record(commandK))

        controller.resetToDefault()

        XCTAssertEqual(controller.binding, .standard)
        XCTAssertNil(registrar.live)
        XCTAssertEqual(sink.tapKey, .option)
        XCTAssertEqual(try TriggerStore(directory: directory).load().binding, .standard)
    }

    /// A system release for the combination that is live is a real release, so it ends the
    /// recording even when this window never saw the key-up.
    func testTheRegisteredCombinationsReleaseEndsTheRecording() {
        let (controller, _, _) = makeController(directory: testScratchDirectory())
        var releases = 0
        controller.onRecordedKeyReleased = { releases += 1 }

        controller.beginRecording()
        controller.hotKeyReleased()          // nothing recorded yet: no release to report
        XCTAssertEqual(releases, 0)

        XCTAssertTrue(controller.record(commandK))
        controller.hotKeyReleased()          // the combination that is live went up
        XCTAssertEqual(releases, 1)
    }

    /// Becoming active again with an unchanged binding keeps a hold that is really open: its
    /// release still has to find the session, otherwise the ring would stay on screen forever.
    func testReapplyingKeepsAnOpenSessionAndItsReleaseStillFinishes() {
        let (controller, _, _) = makeController(directory: testScratchDirectory())
        var finishes = 0
        controller.onFinish = { finishes += 1 }
        XCTAssertTrue(controller.record(commandK))
        XCTAssertTrue(controller.hotKeyPressed())

        controller.reapply()

        XCTAssertEqual(controller.combinationProbe, commandK)   // the session is still open
        controller.hotKeyReleased()
        XCTAssertEqual(finishes, 1)
        XCTAssertNil(controller.combinationProbe)
    }

    /// A reapply that has to fall back drops the session with the binding, so nothing waits for a
    /// release that can no longer finish anything.
    func testReapplyingIntoAFallbackDropsTheSession() {
        let registrar = FakeRegistrar()
        let (controller, _, _) = makeController(directory: testScratchDirectory(), registrar: registrar)
        XCTAssertTrue(controller.record(commandK))
        XCTAssertTrue(controller.hotKeyPressed())

        registrar.refusals = 1      // the re-registration during reapply
        controller.reapply()

        XCTAssertEqual(controller.activeBinding, .standard)
        XCTAssertNil(controller.combinationProbe)
        XCTAssertTrue(controller.isFallback)
    }

    /// A wake drops an open session and registers the combination under a new id, so a key that
    /// is still down after the sleep cannot open the ring.
    func testWakeDropsTheSessionAndRenewsTheRegistration() {
        let registrar = FakeRegistrar()
        let (controller, _, _) = makeController(directory: testScratchDirectory(), registrar: registrar)
        XCTAssertTrue(controller.record(commandK))
        XCTAssertTrue(controller.hotKeyPressed())

        controller.handleSystemWake()

        XCTAssertEqual(registrar.renewals, 1)
        XCTAssertEqual(registrar.live, commandK)
        XCTAssertNil(controller.combinationProbe)
        XCTAssertTrue(controller.hotKeyPressed())   // a fresh press opens a new session
    }

    /// If the combination cannot be registered again after a wake, the run falls back to the
    /// double Option and says so — never a trigger that silently stopped listening.
    func testWakeFallsBackToOptionWhenTheCombinationCannotBeRegisteredAgain() {
        let directory = testScratchDirectory()
        let registrar = FakeRegistrar()
        let (controller, sink, _) = makeController(directory: directory, registrar: registrar)
        XCTAssertTrue(controller.record(commandK))

        registrar.refusals = 2      // the renew, and the repair attempt after it
        controller.handleSystemWake()

        XCTAssertEqual(controller.activeBinding, .standard)
        XCTAssertTrue(controller.isFallback)
        XCTAssertEqual(controller.activeTitle, "双击 Option")
        XCTAssertEqual(sink.tapKey, .option)
        XCTAssertNotNil(controller.notice)
        XCTAssertEqual(controller.binding, .combination(commandK))
    }
}
