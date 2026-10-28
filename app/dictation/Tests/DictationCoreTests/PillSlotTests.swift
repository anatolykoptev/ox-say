import XCTest
@testable import DictationCore

/// #191 items 1-2: a task that puts a pill up begins a slot and ends it; one
/// helper decides, so one site can be gated and tested.
final class PillSlotTests: XCTestCase {
    /// The ordinary path: begin right after the show, end while the pill is
    /// still ours and nothing dictates -> the pill comes down, and the slot
    /// is spent so a second end does nothing.
    /// Mutation: PillSlot.end returns `.leave` for `.idle` -> RED.
    func testEndFinishesTheOwnPillWhenIdleAndSpendsTheSlot() {
        var slot = PillSlot()
        slot.begin(owner: 4)
        XCTAssertEqual(slot.end(current: 4, dictation: .idle), .finish)
        XCTAssertEqual(slot.end(current: 4, dictation: .idle), .leave, "the slot is spent after the end")
    }

    /// A slot that never began has nothing to take down.
    func testAnEndWithoutABeginLeavesThePill() {
        var slot = PillSlot()
        XCTAssertEqual(slot.end(current: 4, dictation: .idle), .leave)
    }

    /// Another owner took the pill since: the late end must not hide it.
    /// Mutation: drop the `owner == current` comparison in PillSlot.end -> RED.
    func testEndLeavesAPillAnotherOwnerTook() {
        var slot = PillSlot()
        slot.begin(owner: 4)
        XCTAssertEqual(slot.end(current: 5, dictation: .idle), .leave)
        XCTAssertEqual(slot.end(current: 5, dictation: .recording), .leave,
                       "a stale slot must not even restore a look")
    }

    /// #191.2 — the task's label is still on the pill when its completion
    /// lands mid-dictation: the finish is refused AND the dictation's look is
    /// put back, instead of "Speaking…" staying until the key is up.
    /// Mutation: PillSlot.end returns `.leave` for a running dictation -> RED.
    func testARefusedEndPutsTheDictationLookBack() {
        var recording = PillSlot()
        recording.begin(owner: 7)
        XCTAssertEqual(recording.end(current: 7, dictation: .recording), .restore(.listening))
        var transcribing = PillSlot()
        transcribing.begin(owner: 7)
        XCTAssertEqual(transcribing.end(current: 7, dictation: .transcribing), .restore(.working))
    }

    /// The look follows the controller's state.
    func testTheLookIsDerivedFromTheDictationState() {
        XCTAssertNil(PillDictationLook(dictation: .idle))
        XCTAssertEqual(PillDictationLook(dictation: .recording), .listening)
        XCTAssertEqual(PillDictationLook(dictation: .transcribing), .working)
    }

    /// The slot also gates the playback show (a reply landing mid-dictation).
    func testMayTakeOverOnlyWhileOursAndIdle() {
        var slot = PillSlot()
        slot.begin(owner: 2)
        XCTAssertTrue(slot.stillOurs(current: 2, dictation: .idle))
        XCTAssertFalse(slot.stillOurs(current: 3, dictation: .idle))
        XCTAssertFalse(slot.stillOurs(current: 2, dictation: .recording))
    }
}
