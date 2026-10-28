import XCTest
@testable import DictationCore

/// #191.6 — every Studio task owns its own pill slot. Two tasks at once (a voice
/// being designed while a document is read) must not clear each other's pill.
final class TaskPillsTests: XCTestCase {
    private func twoTasks() -> TaskPills {
        var pills = TaskPills()
        pills.begin(task: "reading", text: "Reading the document…", owner: 5)
        pills.begin(task: "designing", text: "Designing a voice…", owner: 6)
        return pills
    }

    /// The older task ends while the newer one still shows: the pill stays.
    /// Mutation: TaskPills.end ignores the task id (one shared slot) -> RED.
    func testTheOlderTaskEndingLeavesTheNewerTasksPill() {
        var pills = twoTasks()
        let ended = pills.end(task: "reading", current: 6, dictation: .idle)
        XCTAssertNil(ended.reveal)
        var slot = ended.slot
        XCTAssertEqual(slot.end(current: 6, dictation: .idle), .leave, "task A ending took task B's pill down")
        XCTAssertEqual(pills.liveTasks, ["designing"])
    }

    /// The newer task ends first: the pill shows the task still live instead of going blank.
    func testTheNewerTaskEndingRevealsTheOlderOne() {
        var pills = twoTasks()
        let ended = pills.end(task: "designing", current: 6, dictation: .idle)
        XCTAssertEqual(ended.reveal?.task, "reading")
        XCTAssertEqual(ended.reveal?.text, "Reading the document…")
        // The show of the revealed text takes a new overlay owner; its slot re-begins on it.
        pills.begin(task: "reading", text: "Reading the document…", owner: 7)
        XCTAssertEqual(pills.liveTasks, ["reading"], "re-beginning a live task must not duplicate it")
        var last = pills.end(task: "reading", current: 7, dictation: .idle).slot
        XCTAssertEqual(last.end(current: 7, dictation: .idle), .finish)
    }

    /// The last task ends: the pill comes down.
    func testTheOnlyTaskEndingFinishes() {
        var pills = TaskPills()
        pills.begin(task: "reading", text: "Reading…", owner: 3)
        let ended = pills.end(task: "reading", current: 3, dictation: .idle)
        XCTAssertNil(ended.reveal)
        var slot = ended.slot
        XCTAssertEqual(slot.end(current: 3, dictation: .idle), .finish)
    }

    /// A dictation runs: no reveal, the plain slot rule restores the dictation's look.
    func testNoRevealWhileADictationRuns() {
        var pills = twoTasks()
        let ended = pills.end(task: "designing", current: 6, dictation: .recording)
        XCTAssertNil(ended.reveal)
        var slot = ended.slot
        XCTAssertEqual(slot.end(current: 6, dictation: .recording), .restore(.listening))
    }

    /// Another owner (a speak) took the pill: the ended task leaves it, no reveal.
    func testNoRevealWhenAnotherOwnerTookThePill() {
        var pills = twoTasks()
        let ended = pills.end(task: "designing", current: 9, dictation: .idle)
        XCTAssertNil(ended.reveal)
        var slot = ended.slot
        XCTAssertEqual(slot.end(current: 9, dictation: .idle), .leave)
    }

    /// An end for a task that never began (or already ended) does nothing.
    func testAnUnknownTaskEndIsInert() {
        var pills = TaskPills()
        let ended = pills.end(task: "ghost", current: 1, dictation: .idle)
        XCTAssertNil(ended.reveal)
        var slot = ended.slot
        XCTAssertEqual(slot.end(current: 1, dictation: .idle), .leave)
        pills.begin(task: "a", text: "A", owner: 1)
        _ = pills.end(task: "a", current: 1, dictation: .idle)
        let again = pills.end(task: "a", current: 1, dictation: .idle)
        XCTAssertNil(again.reveal)
        var spent = again.slot
        XCTAssertEqual(spent.end(current: 1, dictation: .idle), .leave, "a second end of the same task must be inert")
    }
}
