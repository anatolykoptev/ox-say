import XCTest
@testable import DictationCore

final class ProduceModelsTests: XCTestCase {
    /// A status summary as the daemon marshals it (vproject.Summary).
    private func summary(status: String, title: String = "Chapter one", done: Int = 3, total: Int = 10,
                         error: String? = nil, wav: String? = nil, reviewChunks: Int = 0) -> Data {
        var chunks = (0..<total).map { ["index": $0, "status": "ok"] as [String: Any] }
        for i in 0..<reviewChunks { chunks[i]["status"] = "review" }
        var obj: [String: Any] = [
            "id": "20261015-120000-abcd", "title": title, "status": status, "seed": 1,
            "progress": ["chunks_total": total, "chunks_done": done, "renders": done, "elapsed_s": 5.0, "eta_s": 9.0],
            "outputs": wav.map { ["wav": $0, "duration_s": 61.5] as [String: Any] } ?? [String: Any](),
            "chunks": chunks, "notes": [],
        ]
        if let error { obj["error"] = error }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: request

    func testCreateBodyUsesTheDaemonsKeys() throws {
        let body = ProduceRequest.createBody(script: "Привет, мир.", title: " Глава 1 ", voice: "ru-anna", format: .short)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["script"] as? String, "Привет, мир.")
        XCTAssertEqual(json["title"] as? String, "Глава 1")
        XCTAssertEqual(json["voice"] as? String, "ru-anna")
        XCTAssertEqual(json["preset"] as? String, "reels")
        XCTAssertEqual(Set(json.keys), ["script", "title", "voice", "preset"])
    }

    func testCreateBodyLeavesOutAnEmptyTitleAndVoice() throws {
        let body = ProduceRequest.createBody(script: "Text.", title: "  ", voice: nil, format: .long)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["script", "preset"])
        XCTAssertEqual(json["preset"] as? String, "youtube")
    }

    func testFormatsMapToTheDaemonsPresets() {
        XCTAssertEqual(ProduceFormat.short.preset, "reels")
        XCTAssertEqual(ProduceFormat.long.preset, "youtube")
        XCTAssertEqual(ProduceFormat.short.title, "Reels / Shorts (short)")
        XCTAssertEqual(ProduceFormat.long.title, "YouTube (long)")
    }

    func testResumeBodyAllowsTheBattery() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: ProduceRequest.resumeOnBatteryBody()) as? [String: Any])
        XCTAssertEqual(json["allow_battery"] as? Bool, true)
    }

    // MARK: decoding every real state

    func testEveryDaemonStateDecodes() throws {
        let words: [(String, ProduceStatus)] = [
            ("running", .running), ("waiting_for_dictation", .waitingForDictation),
            ("paused_on_battery", .pausedOnBattery), ("review", .review), ("done", .done),
            ("failed", .failed), ("cancelled", .cancelled), ("interrupted", .interrupted),
        ]
        for (word, expected) in words {
            let job = try XCTUnwrap(ProduceJob.decode(summary(status: word)), word)
            XCTAssertEqual(job.status, expected, word)
        }
        XCTAssertEqual(ProduceStatus("something_new"), .unknown("something_new"))
    }

    func testJobFieldsDecode() throws {
        let job = try XCTUnwrap(ProduceJob.decode(summary(status: "review", done: 10, total: 10, wav: "/Users/a/Movies/ox-say/Chapter one.wav", reviewChunks: 2)))
        XCTAssertEqual(job.id, "20261015-120000-abcd")
        XCTAssertEqual(job.title, "Chapter one")
        XCTAssertEqual(job.partsDone, 10)
        XCTAssertEqual(job.partsTotal, 10)
        XCTAssertEqual(job.partsToReview, 2)
        XCTAssertEqual(job.outputPath, "/Users/a/Movies/ox-say/Chapter one.wav")
        XCTAssertEqual(job.outputFolder?.path, "/Users/a/Movies/ox-say")
    }

    func testFailedJobCarriesTheDaemonsReason() throws {
        let job = try XCTUnwrap(ProduceJob.decode(summary(status: "failed", error: "the disk is full")))
        XCTAssertEqual(job.error, "the disk is full")
        XCTAssertNil(job.outputPath)
    }

    func testListIsNewestFirstAndNullMeansNone() throws {
        let list = Data(#"{"projects":[{"id":"b","title":"B","status":"running","progress":{"chunks_total":4,"chunks_done":1},"outputs":{},"chunks":[]},{"id":"a","title":"A","status":"done","progress":{},"outputs":{"wav":"/x/A.wav"},"chunks":[]}]}"#.utf8)
        XCTAssertEqual(ProduceJob.decodeList(list)?.map(\.id), ["b", "a"])
        XCTAssertEqual(ProduceJob.decodeList(Data(#"{"projects":null}"#.utf8)), [])
        XCTAssertNil(ProduceJob.decodeList(Data("nope".utf8)))
    }

    // MARK: polling and text

    /// Mutation: make ProduceStatus.isTerminal answer false for every state -> RED.
    func testPollingStopsExactlyWhenTheJobIsOver() throws {
        for word in ["review", "done", "failed", "cancelled", "interrupted"] {
            let job = try XCTUnwrap(ProduceJob.decode(summary(status: word)))
            XCTAssertFalse(ProduceText.shouldKeepPolling(job), "\(word) is terminal: polling must stop")
            XCTAssertTrue(job.status.isTerminal, word)
        }
        for word in ["running", "waiting_for_dictation", "paused_on_battery", "something_new"] {
            let job = try XCTUnwrap(ProduceJob.decode(summary(status: word)))
            XCTAssertTrue(ProduceText.shouldKeepPolling(job), "\(word) is still working: polling must go on")
        }
    }

    func testPollIntervalIsFiveSeconds() {
        XCTAssertEqual(ProduceText.pollInterval, 5)
    }

    func testProgressRowTexts() throws {
        func row(_ status: String, done: Int = 3, total: Int = 10, review: Int = 0) -> String {
            ProduceText.progressRow(ProduceJob.decode(summary(status: status, done: done, total: total, reviewChunks: review))!)
        }
        XCTAssertEqual(row("running"), "“Chapter one” — 3 of 10 parts")
        XCTAssertEqual(row("running", done: 0, total: 0), "“Chapter one” — starting…")
        XCTAssertEqual(row("paused_on_battery"), "“Chapter one” — paused — on battery power")
        XCTAssertEqual(row("waiting_for_dictation"), "“Chapter one” — paused — you are dictating")
        XCTAssertEqual(row("done"), "“Chapter one” — ready")
        XCTAssertEqual(row("review", review: 1), "“Chapter one” — ready — 1 part needs a listen")
        XCTAssertEqual(row("review", review: 3), "“Chapter one” — ready — 3 parts need a listen")
        XCTAssertEqual(row("failed"), "“Chapter one” — failed")
    }

    func testFinishAlerts() throws {
        let done = try XCTUnwrap(ProduceJob.decode(summary(status: "done", wav: "/Users/a/Movies/ox-say/Chapter one.wav")))
        let ready = try XCTUnwrap(ProduceText.finishAlert(done))
        XCTAssertEqual(ready.title, "Voiceover ready")
        XCTAssertEqual(ready.text, "Saved as Chapter one.wav.")
        let review = try XCTUnwrap(ProduceJob.decode(summary(status: "review", wav: "/x/Ch.wav", reviewChunks: 2)))
        XCTAssertEqual(ProduceText.finishAlert(review)?.text, "Saved as Ch.wav. 2 parts need a listen. They are in the folder.")
        let failed = try XCTUnwrap(ProduceJob.decode(summary(status: "failed", error: "the disk is full")))
        XCTAssertEqual(ProduceText.finishAlert(failed)?.title, "The voiceover failed")
        XCTAssertEqual(ProduceText.finishAlert(failed)?.text, "the disk is full")
        let cancelled = try XCTUnwrap(ProduceJob.decode(summary(status: "cancelled")))
        XCTAssertNil(ProduceText.finishAlert(cancelled))
    }
}
