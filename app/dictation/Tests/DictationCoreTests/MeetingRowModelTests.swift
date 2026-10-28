import XCTest
@testable import DictationCore

final class MeetingRowModelTests: XCTestCase {
    private func info(_ status: MeetingInfo.Status, pending: String? = nil) -> MeetingInfo {
        MeetingInfo(id: "x", status: status, notesPending: pending)
    }

    /// Every daemon status reads as one of the plain lines; a finished meeting without notes is "Transcript only".
    /// Mutation: MeetingRowModel.status, return .ready for .transcribed -> RED.
    func testStatusLines() {
        XCTAssertEqual(MeetingRowModel.status(of: info(.recording)), .recording)
        XCTAssertEqual(MeetingRowModel.status(of: info(.queued)), .waiting)
        XCTAssertEqual(MeetingRowModel.status(of: info(.transcribing)), .transcribing)
        XCTAssertEqual(MeetingRowModel.status(of: info(.summarizing)), .writingNotes)
        XCTAssertEqual(MeetingRowModel.status(of: info(.done)), .ready)
        XCTAssertEqual(MeetingRowModel.status(of: info(.failed)), .failed)
        XCTAssertEqual(MeetingRowModel.status(of: info(.transcribed, pending: "model_missing")), .transcriptOnly)
        XCTAssertTrue(MeetingStatusLine.writingNotes.isBusy)
        XCTAssertFalse(MeetingStatusLine.ready.isBusy)
    }

    func testDurations() {
        let t: (L10nKey) -> String = { $0.rawValue }
        XCTAssertNil(MeetingRowModel.duration(nil, text: t))
        XCTAssertEqual(MeetingRowModel.duration(20, text: t), "meeting.duration.sec")
        XCTAssertEqual(MeetingRowModel.duration(42 * 60, text: { _ in "%d min" }), "42 min")
        XCTAssertEqual(MeetingRowModel.duration(65 * 60, text: { _ in "%d h %d min" }), "1 h 5 min")
    }

    func testTheDaemonsDurationIsDecoded() {
        let json = #"{"meetings":[{"id":"a","status":"done","duration_s":2520.5},{"id":"b","status":"recording"}]}"#
        let list = MeetingInfo.decodeList(Data(json.utf8))
        XCTAssertEqual(list?.first?.durationSeconds, 2520.5)
        XCTAssertNil(list?.last?.durationSeconds)
    }

    func testDayGroupsSplitByCalendarDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 18))!
        func m(_ id: String, _ daysAgo: Int, hour: Int) -> MeetingInfo {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: now)!
            return MeetingInfo(id: id, started: cal.date(bySettingHour: hour, minute: 0, second: 0, of: day), status: .done)
        }
        let groups = MeetingRowModel.groups([m("a", 0, hour: 17), m("b", 0, hour: 9), m("c", 1, hour: 11), m("d", 5, hour: 8)],
                                            now: now, locale: Locale(identifier: "en_US"), calendar: cal, text: { $0.rawValue })
        XCTAssertEqual(groups.map(\.title), ["meetings.day.today", "meetings.day.yesterday", "October 21"])
        XCTAssertEqual(groups.map { $0.meetings.map(\.id) }, [["a", "b"], ["c"], ["d"]])
    }

    func testNotesAndTranscriptAreReadAsTheDaemonWritesThem() {
        let notes = NotesDocument.parse("# T\n\n## Summary\n\nText here.\n\n## Action items\n\n- [ ] Anna — Do it — Friday\n- [ ] free text\n\n## Decisions\n\n- One\n")
        XCTAssertEqual(notes.sections.map(\.title), ["Summary", "Action items", "Decisions"])
        XCTAssertEqual(notes.sections[1].items, [.action(who: "Anna", what: "Do it", when: "Friday"),
                                                 .action(who: "", what: "free text", when: "")])
        XCTAssertEqual(notes.sections[2].items, [.bullet("One")])
        let turns = TranscriptTurn.parse("# T\n\n**You** [0:04]: Hello: there\n\n**Anna** [1:02:03]: Hi\n")
        XCTAssertEqual(turns.map(\.speaker), ["You", "Anna"])
        XCTAssertEqual(turns.map(\.time), ["0:04", "1:02:03"])
        XCTAssertEqual(turns[0].text, "Hello: there")
    }

    /// The daemon escapes per rune; a backslash before a special that is followed by a combining mark must still go.
    /// Mutation: MeetingRowModel.unescaped, iterate `name` (Characters) instead of `name.unicodeScalars` -> RED.
    func testUnescapeWorksPerScalarNotPerCharacter() {
        let acute = "\u{301}"
        XCTAssertEqual(TranscriptTurn.unescaped("a\\*" + acute + "b"), "a*" + acute + "b")
        XCTAssertEqual(TranscriptTurn.unescaped("\\_" + acute), "_" + acute)
        XCTAssertEqual(TranscriptTurn.unescaped("x\\#" + acute, extra: "#"), "x#" + acute)
        // The plain cases are unchanged.
        XCTAssertEqual(TranscriptTurn.unescaped("Ann \\*B\\*"), "Ann *B*")
        XCTAssertEqual(TranscriptTurn.unescaped("a\\\\b"), "a\\b")
        XCTAssertEqual(TranscriptTurn.unescaped("a\\qb"), "a\\qb", "a backslash before a non-special stays")
        XCTAssertEqual(TranscriptTurn.unescaped("end\\"), "end\\")
        XCTAssertEqual(TranscriptTurn.unescaped("Zoë 🎤 \\[x\\]"), "Zoë 🎤 [x]")
    }
}
