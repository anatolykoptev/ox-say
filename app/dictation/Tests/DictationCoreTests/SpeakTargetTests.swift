import XCTest
@testable import DictationCore

/// A voiceover the window is told to open is asked of the daemon, never of the cached list (PR #511 review, round 2).
final class SpeakTargetTests: XCTestCase {
    private func job(_ id: String) -> ProduceJob { ProduceJob(id: id, title: id, status: .done, outputPath: "/x/\(id).wav") }

    private func fakeDaemon(has: Set<String>, calls: @escaping (String) -> Void = { _ in }) -> (String) async throws -> ProduceJob {
        { id in
            calls(id)
            guard has.contains(id) else { throw StudioError.refused(status: 404, message: "no such project") }
            return self.job(id)
        }
    }

    /// Cached list [A], the notification names B, which exists: B is fetched, not pruned.
    func testAProjectMissingFromTheCachedListIsFetchedNotPruned() async {
        let outcome = await SpeakTarget.resolve(id: "B", cached: [job("A")], fetch: fakeDaemon(has: ["A", "B"]))
        XCTAssertEqual(outcome, .fetched(job("B")))
    }

    /// C does not exist on the daemon: it is dropped (the page keeps its selection, which is not this function's to touch).
    func testAProjectTheDaemonDoesNotHaveIsGone() async {
        let outcome = await SpeakTarget.resolve(id: "C", cached: [job("A")], fetch: fakeDaemon(has: ["A", "B"]))
        XCTAssertEqual(outcome, .gone)
        let down = await SpeakTarget.resolve(id: "C", cached: [], fetch: { _ in throw StudioError.daemonUnreachable })
        XCTAssertEqual(down, .gone, "no answer opens nothing")
    }

    func testAProjectOnTheListNeedsNoRead() async {
        var asked: [String] = []
        let outcome = await SpeakTarget.resolve(id: "A", cached: [job("A")], fetch: fakeDaemon(has: ["A"]) { asked.append($0) })
        XCTAssertEqual(outcome, .cached)
        XCTAssertTrue(asked.isEmpty)
    }

    /// The fetched project joins the list ahead of the others (the daemon's list is capped at the newest 20).
    func testAFetchedProjectJoinsTheListOnce() {
        XCTAssertEqual(SpeakList.overlay(projects: [job("A")], followed: job("B")).map(\.id), ["B", "A"])
        XCTAssertEqual(SpeakList.overlay(projects: [job("A"), job("B")], followed: job("B")).map(\.id), ["A", "B"])
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/\(path)"), encoding: .utf8)
    }

    /// The window's own wiring: a route that arrives through `apply` is resolved by the daemon; only the restored id of the last
    /// run waits for the first fresh list.
    func testTheWindowResolvesARouteWithTheDaemonAndARestoredIDWithTheList() throws {
        let window = try source("OxSayDictation/MainWindowSource.swift")
        XCTAssertTrue(window.contains("if let id = route.speakID { speakSource.showProject(id) }"))
        XCTAssertTrue(window.contains("if let id = restored.speakID { speakSource.openProject(id) }"))
        let speak = try source("OxSayDictation/SpeakSource.swift")
        XCTAssertTrue(speak.contains("SpeakTarget.resolve(id: id, cached: cached, fetch: { try await client.voiceover(id: $0) })"))
        XCTAssertTrue(speak.contains("case .gone: self.model.data.speak.pendingProjectID = nil"))
    }
}
