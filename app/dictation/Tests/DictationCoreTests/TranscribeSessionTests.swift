import XCTest
@testable import DictationCore

@MainActor
final class TranscribeSessionTests: XCTestCase {
    private func entry(_ n: Int, title: String = "t") -> TranscriptEntry {
        TranscriptEntry(id: String(format: "20261030-10101%d-abcdef", n), title: title, created: Date(timeIntervalSince1970: 1_793_354_000 + Double(n)),
                        seconds: 60, engine: "parakeet")
    }

    private func session(list: @escaping () async throws -> [TranscriptEntry] = { [] },
                         transcribe: ((URL, String, Double?) async throws -> TranscriptEntry)? = nil,
                         text: ((String, TranscriptFormat) async throws -> Data)? = nil,
                         delete: ((String) async throws -> Void)? = nil) -> TranscribeSession {
        return TranscribeSession(ops: TranscribeOps(
            list: list,
            transcribe: transcribe ?? { _, title, _ in TranscriptEntry(id: "20261030-101019-abcdef", title: title, created: Date(), seconds: 1, engine: "parakeet") },
            text: text ?? { _, _ in Data() },
            delete: delete ?? { _ in },
            duration: { _ in 12 }), text: { $0.rawValue })
    }

    /// The journey: drop a file -> one upload with the file's name as the title -> the new transcript is first and selected,
    /// and the page shows "working" while it runs.
    func testADroppedFileIsSentAndTheNewTranscriptIsSelected() async {
        var seenWorking: String?
        var sent: (URL, String, Double?)?
        var s: TranscribeSession!
        s = session(transcribe: { url, title, seconds in
            sent = (url, title, seconds)
            seenWorking = await s.working
            return TranscriptEntry(id: "20261030-101019-abcdef", title: title, created: Date(), seconds: 12, engine: "parakeet")
        })
        await s.reload()
        let notice = await s.submit(URL(fileURLWithPath: "/tmp/Интервью.m4a"), bytes: 10)
        XCTAssertNil(notice)
        XCTAssertEqual(sent?.0.path, "/tmp/Интервью.m4a")
        XCTAssertEqual(sent?.1, "Интервью")
        XCTAssertEqual(sent?.2, 12, "the measured duration reaches the upload")
        XCTAssertEqual(seenWorking, "Интервью")
        XCTAssertEqual(s.entries.first?.id, "20261030-101019-abcdef")
        XCTAssertEqual(s.selectedID, "20261030-101019-abcdef")
        XCTAssertNil(s.working)
        XCTAssertEqual(s.pageState, .list(stale: nil))
    }

    func testAFailedUploadShowsAReadableErrorAndStoresNothing() async {
        let old = entry(1)
        let s = session(list: { [old] }, transcribe: { _, _, _ in throw StudioError.refused(status: 500, message: "the speech engine failed") })
        await s.reload()
        s.select(old.id)
        let notice = await s.submit(URL(fileURLWithPath: "/tmp/a.wav"), bytes: 10)
        XCTAssertEqual(notice, "the speech engine failed")
        XCTAssertEqual(s.entries, [old])
        XCTAssertEqual(s.selectedID, old.id, "the selection stays where it was")
        XCTAssertNil(s.working, "the row stops working")
    }

    func testTheDaemonOfflineIsSaidNotShownAsAnEmptyList() async {
        let s = session(list: { throw StudioError.daemonUnreachable })
        await s.reload()
        guard case .offline(let sentence) = s.pageState else { return XCTFail("want offline, got \(s.pageState)") }
        XCTAssertEqual(sentence, L10nKey.studioErrorUnreachable.rawValue)
    }

    func testAFailedRefreshKeepsTheListWithAStaleLine() async {
        var fail = false
        let s = session(list: { if fail { throw StudioError.timedOut }; return [self.entry(1)] })
        await s.reload()
        fail = true
        await s.reload()
        XCTAssertEqual(s.pageState, .list(stale: L10nKey.studioErrorTimedOut.rawValue))
        XCTAssertEqual(s.entries.count, 1)
    }

    func testASecondFileWhileOneRunsIsRefusedWithoutAnUpload() async {
        var uploads = 0
        var gate: CheckedContinuation<Void, Never>?
        let s = session(transcribe: { _, title, _ in
            uploads += 1
            await withCheckedContinuation { gate = $0 }
            return TranscriptEntry(id: "20261030-101019-abcdef", title: title, created: Date(), seconds: 1, engine: "parakeet")
        })
        let first = Task { await s.submit(URL(fileURLWithPath: "/tmp/a.wav"), bytes: 10) }
        var spins = 0
        while gate == nil, spins < 10_000 { spins += 1; await Task.yield() }
        let second = await s.submit(URL(fileURLWithPath: "/tmp/b.wav"), bytes: 10)
        XCTAssertEqual(second, L10nKey.transcribeBusy.rawValue)
        XCTAssertEqual(uploads, 1)
        gate?.resume()
        let done = await first.value
        XCTAssertNil(done)
    }

    func testAFileThatIsTooBigOrNotMediaNeverStartsAnUpload() async {
        var uploads = 0
        let s = session(transcribe: { _, _, _ in uploads += 1; throw StudioError.badResponse })
        let big = await s.submit(URL(fileURLWithPath: "/tmp/a.wav"), bytes: Int64(TranscribeFileCheck.maxBytes) + 1)
        let pdf = await s.submit(URL(fileURLWithPath: "/tmp/a.pdf"), bytes: 10)
        XCTAssertNotNil(big)
        XCTAssertNotNil(pdf)
        XCTAssertEqual(uploads, 0)
        XCTAssertNil(s.working)
    }

    /// A list read that began before the upload landed must not wipe the new row when it answers late.
    func testALateListReadDoesNotDropAFreshTranscript() async {
        var gate: CheckedContinuation<Void, Never>?
        var first = true
        let s = session(list: {
            if first { first = false; await withCheckedContinuation { gate = $0 } }
            return []
        })
        let read = Task { await s.reload() }
        var spins = 0
        while gate == nil, spins < 10_000 { spins += 1; await Task.yield() }
        _ = await s.submit(URL(fileURLWithPath: "/tmp/a.wav"), bytes: 10)
        gate?.resume()
        await read.value
        XCTAssertEqual(s.entries.count, 1)
        XCTAssertEqual(s.selectedID, s.entries.first?.id)
    }

    /// «Субтитры» saves what the daemon returned for format=srt, named after the title.
    func testSavingSubtitlesWritesWhatTheDaemonReturnedForSRT() async throws {
        var asked: (String, TranscriptFormat)?
        let srt = Data("1\n00:00:00,000 --> 00:00:01,000\nраз\n".utf8)
        let e = entry(1, title: "Интервью")
        let s = session(list: { [e] }, text: { id, format in asked = (id, format); return srt })
        await s.reload()
        let file = try await s.file(id: e.id, format: .srt)
        XCTAssertEqual(asked?.0, e.id)
        XCTAssertEqual(asked?.1, .srt)
        XCTAssertEqual(file.name, "Интервью.srt")
        XCTAssertEqual(file.data, srt)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID()).srt")
        defer { try? FileManager.default.removeItem(at: out) }
        try file.write(to: out)
        let used = try XCTUnwrap(try? Data(contentsOf: out))
        XCTAssertEqual(used, srt)
    }

    func testAFileForAnUnknownTranscriptThrows() async {
        let s = session(text: { _, _ in throw StudioError.refused(status: 404, message: "no such transcript") })
        do { _ = try await s.file(id: "20261030-101010-abcdef", format: .text); XCTFail("must throw") } catch {}
    }

    func testDeleteRemovesTheRowAndAFailedDeleteKeepsIt() async {
        let a = entry(1), b = entry(2)
        var fail = true
        var deleted: [String] = []
        let s = session(list: { [b, a] }, delete: { id in deleted.append(id); if fail { throw StudioError.refused(status: 500, message: "disk full") } })
        await s.reload()
        s.select(b.id)
        let refused = await s.delete(id: b.id)
        XCTAssertEqual(refused, "disk full")
        XCTAssertEqual(s.entries.map(\.id), [b.id, a.id])
        fail = false
        let ok = await s.delete(id: b.id)
        XCTAssertNil(ok)
        XCTAssertEqual(s.entries.map(\.id), [a.id])
        XCTAssertNil(s.selectedID, "a deleted row is not selected")
        XCTAssertEqual(deleted, [b.id, b.id])
    }

    func testTheLastDeleteLeavesAnEmptyPageNotAnError() async {
        let a = entry(1)
        let s = session(list: { [a] })
        await s.reload()
        _ = await s.delete(id: a.id)
        XCTAssertEqual(s.pageState, .empty)
    }

    /// The size check follows the daemon's own cap, not a built-in one.
    /// Mutation: TranscribeSession.swift, `limit: limits().maxBytes` -> the built-in default -> RED.
    func testTheCapFollowsTheDaemon() async {
        var uploads = 0
        let s = TranscribeSession(ops: TranscribeOps(list: { [] }, transcribe: { _, t, _ in
            uploads += 1
            return TranscriptEntry(id: "20261030-101019-abcdef", title: t, created: Date(), seconds: 1, engine: "p")
        }, text: { _, _ in Data() }, delete: { _ in }), limits: { TranscribeLimits(maxBytes: 5 << 20, daemonTimeout: 600) }, text: { $0.rawValue })
        let over = await s.submit(URL(fileURLWithPath: "/tmp/a.wav"), bytes: 6 << 20)
        XCTAssertEqual(over, L10nKey.transcribeProblemTooBig.rawValue)
        XCTAssertEqual(uploads, 0)
        let fits = await s.submit(URL(fileURLWithPath: "/tmp/a.wav"), bytes: 5 << 20)
        XCTAssertNil(fits)
        XCTAssertEqual(uploads, 1)
    }

    /// A file that passed the check and then grew: the client's streaming stop surfaces as the size sentence and nothing is stored.
    func testAFileThatGrewPastTheCapSaysTheSizeSentenceAndStoresNothing() async {
        let s = session(transcribe: { _, _, _ in throw StudioError.fileTooLarge(megabytes: 200) })
        let notice = await s.submit(URL(fileURLWithPath: "/tmp/a.wav"), bytes: 10)
        XCTAssertEqual(notice, L10nKey.transcribeProblemTooBig.rawValue)
        XCTAssertTrue(s.entries.isEmpty)
        XCTAssertNil(s.working)
    }

    /// The title is one line the daemon takes: line breaks become spaces and a long name is cut at 200.
    /// Mutation: TranscribeFileCheck.title, return `name` unchanged -> RED.
    func testTheTitleIsOneLineWithinTheDaemonsCap() async {
        var titles: [String] = []
        let s = session(transcribe: { _, title, _ in
            titles.append(title)
            return TranscriptEntry(id: "20261030-101019-abcdef", title: title, created: Date(), seconds: 1, engine: "p")
        })
        _ = await s.submit(URL(fileURLWithPath: "/tmp/a\nb\r\n  c.wav"), bytes: 10)
        XCTAssertEqual(titles.last, "a b c")
        XCTAssertEqual(TranscribeFileCheck.title(fromFileName: String(repeating: "я", count: 300)).count, 200)
    }

    /// Cancelling the save panel is nothing to report; a write that was asked for and failed is.
    /// Mutation: TranscribeSession.swift finishSave, `guard confirmed, let url else { return false }` -> RED.
    func testACancelledSaveIsNotAFailure() throws {
        let file = TranscriptFile(name: "a.srt", data: Data("x".utf8))
        XCTAssertNil(file.finishSave(confirmed: false, url: URL(fileURLWithPath: "/tmp/a.srt")))
        XCTAssertNil(file.finishSave(confirmed: true, url: nil))
        XCTAssertEqual(file.finishSave(confirmed: true, url: URL(fileURLWithPath: "/nonexistent-dir-\(UUID())/a.srt")), false)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID()).srt")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(file.finishSave(confirmed: true, url: out), true)
        let written = try Data(contentsOf: out)
        XCTAssertEqual(written, Data("x".utf8))
    }
}
