import XCTest
@testable import DictationCore

final class ProduceModelsTests: XCTestCase {
    private let en = ShippedStrings.localizer("en")
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
        XCTAssertEqual(ProduceFormat.short.title(text: en), "Reels / Shorts (short)")
        XCTAssertEqual(ProduceFormat.long.title(text: en), "YouTube (long)")
    }

    func testResumeBodyAllowsTheBattery() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: ProduceRequest.resumeOnBatteryBody()) as? [String: Any])
        XCTAssertEqual(json["allow_battery"] as? Bool, true)
    }

    /// The reel's create: one take per chunk and the reference clone path, on
    /// top of the fields the Studio menu already sends.
    func testCreateBodyWithTakesAndCloneModeCarriesBoth() throws {
        let body = ProduceRequest.createBody(script: "S.", title: "", voice: nil, format: .short,
                                             takes: 1, cloneMode: "reference")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["takes"] as? Int, 1)
        XCTAssertEqual(json["clone_mode"] as? String, "reference")
        XCTAssertEqual(json["script"] as? String, "S.")
        XCTAssertEqual(json["preset"] as? String, "reels")
        XCTAssertEqual(Set(json.keys), ["script", "preset", "takes", "clone_mode"])
    }

    /// The new tuning knobs go out only when set — the daemon's strict
    /// decoder answers 400 to a key it does not know.
    /// Mutation: `if let loudness { body["loudness_lufs"] }` removed -> RED.
    func testCreateBodyCarriesTheOptionalKnobsOnlyWhenSet() throws {
        let plain = ProduceRequest.createBody(script: "x", title: "", voice: nil, format: .short)
        let plainJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: AnyHashable])
        XCTAssertEqual(plainJSON, ["script": "x", "preset": "reels"])
        let tuned = try XCTUnwrap(JSONSerialization.jsonObject(
            with: ProduceRequest.createBody(script: "x", title: "", voice: nil, format: .short,
                                            loudness: -16, steps: 8, seed: 4127, outPath: "/tmp/out.wav")) as? [String: Any])
        XCTAssertEqual(tuned["loudness_lufs"] as? Double, -16)
        XCTAssertEqual(tuned["inference_timesteps"] as? Int, 8)
        XCTAssertEqual(tuned["seed"] as? Int, 4127)
        XCTAssertEqual(tuned["out_path"] as? String, "/tmp/out.wav")
    }

    /// The previous createBody, verbatim: the oracle the byte check compares
    /// against. It must run in this process — a [String: Any] dictionary's
    /// order is per-process, so a literal baked elsewhere cannot match.
    /// Frozen copy: do not update it when createBody changes — the drift
    /// between this baseline and the live function is exactly what the
    /// byte-identical test watches for.
    private func mainCreateBody(script: String, title: String, voice: String?, format: ProduceFormat) -> Data {
        var body: [String: Any] = ["script": script, "preset": format.preset]
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { body["title"] = trimmed }
        if let voice, !voice.isEmpty { body["voice"] = voice }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// Without the new options the body is byte-identical to the previous
    /// version's — the same call through the frozen function above, here in
    /// process. Mutation: always emit clone_mode -> RED.
    func testCreateBodyWithoutTheNewFieldsIsByteIdentical() {
        for (script, title, voice, format) in [("Привет, мир.", " Глава 1 ", "ru-anna" as String?, ProduceFormat.short),
                                               ("S.", "", nil, .long),
                                               ("T.", "t", "", .short)] {
            XCTAssertEqual(ProduceRequest.createBody(script: script, title: title, voice: voice, format: format),
                           mainCreateBody(script: script, title: title, voice: voice, format: format),
                           "script=\(script) title=\(title) voice=\(voice ?? "nil")")
        }
    }

    /// Swift Dictionary order is hashed per instance, so an unsorted
    /// serialisation of equal dictionaries differs between calls (issue #467:
    /// "92 bytes" is not equal to "92 bytes" on CI). Every produce/design body
    /// must come out with sorted keys, every time. Mutation: drop `.sortedKeys`
    /// from `createBody` -> RED.
    func testRequestBodiesSerialiseWithSortedKeysEveryTime() {
        let create = #"{"clone_mode":"x","inference_timesteps":8,"loudness_lufs":-18,"out_path":"o","preset":"reels","script":"S","seed":1,"takes":2,"title":"t","voice":"v"}"#
        let delivery = #"{"chunks":[{"n":1,"pace":1.5,"pause_after":0.5,"style":"calm"}],"loudness_lufs":-18}"#
        let design = #"{"description":"d","takes":3,"text":"t"}"#
        let save = #"{"name":"n","replace":true,"take":"t"}"#
        for _ in 0..<200 {
            XCTAssertEqual(String(decoding: ProduceRequest.createBody(
                script: "S", title: "t", voice: "v", format: .short, takes: 2, cloneMode: "x",
                loudness: -18, steps: 8, seed: 1, outPath: "o"), as: UTF8.self), create)
            XCTAssertEqual(String(decoding: ProduceRequest.deliveryBody(
                entries: [DeliveryEntry(n: 1, style: "calm", pauseAfter: 0.5, pace: 1.5)], loudness: -18), as: UTF8.self), delivery)
            XCTAssertEqual(String(decoding: ProduceRequest.chunkBody(["action": "a", "n": 1, "style": "s"]), as: UTF8.self),
                           #"{"action":"a","n":1,"style":"s"}"#)
            XCTAssertEqual(String(decoding: DesignRequest.body(description: "d", text: "t"), as: UTF8.self), design)
            XCTAssertEqual(String(decoding: DesignRequest.saveBody(name: "n", take: "t", replace: true), as: UTF8.self), save)
        }
    }

    /// A loudness-only delivery is `{"chunks":[],"loudness_lufs":…}` — the
    /// daemon allows the empty batch only because loudness is set.
    func testDeliveryBodyCarriesLoudnessAlone() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: ProduceRequest.deliveryBody(entries: [], loudness: -18)) as? [String: Any])
        XCTAssertEqual(json["loudness_lufs"] as? Double, -18)
        XCTAssertEqual((json["chunks"] as? [Any])?.count, 0)
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

    // MARK: chunks, duration, the live answer

    /// The summary's chunks carry index and status; per-phrase progress is
    /// built from them, so they must be on the job, not just counted.
    func testJobDecodesItsChunks() throws {
        let job = try XCTUnwrap(ProduceJob.decode(summary(status: "running", done: 1, total: 3,
                                                         wav: "/x/a.wav", reviewChunks: 0)))
        XCTAssertEqual(job.chunks, [ProduceChunk(index: 0, status: .ok),
                                    ProduceChunk(index: 1, status: .ok),
                                    ProduceChunk(index: 2, status: .ok)])
        XCTAssertEqual(job.durationS, 61.5)
    }

    /// Chunk status words beyond the three known ones stay open: a status the
    /// daemon adds later must not read as done.
    func testChunkStatusWordsDecode() {
        XCTAssertEqual(ProduceChunkState("pending"), .pending)
        XCTAssertEqual(ProduceChunkState("ok"), .ok)
        XCTAssertEqual(ProduceChunkState("review"), .review)
        XCTAssertEqual(ProduceChunkState("whatever_next"), .unknown("whatever_next"))
        XCTAssertTrue(ProduceChunkState("whatever_next").isOpen)
        XCTAssertFalse(ProduceChunkState("ok").isOpen)
        XCTAssertFalse(ProduceChunkState("review").isOpen)
    }

    /// The one field only the chunk detail carries: the script paragraph the
    /// chunk belongs to (vproject.Chunk.Paragraph, embedded in chunkDetailOut).
    func testAChunkDetailDecodesItsParagraph() throws {
        let data = Data(#"{"index":2,"paragraph":1,"status":"ok","text":"Дальше.","spoken":"дальше","take_files":{}}"#.utf8)
        let detail = try XCTUnwrap(ProduceChunkDetail.decode(data))
        XCTAssertEqual(detail.index, 2)
        XCTAssertEqual(detail.paragraph, 1)
        XCTAssertEqual(detail.status, .ok)
        XCTAssertEqual(detail.text, "Дальше.")
    }

    /// A real `GET /v1/produce/{id}` answer — the fixture is vproject.Summary
    /// marshaled by the daemon's own encoder: `eta_s` always present, `error`
    /// absent (omitempty), a summary chunk's `pick`/`user_pick`/`reasons`
    /// following their own rules.
    func testDecodesALiveProduceStatus() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("produce-status-live.json")
        let data = try Data(contentsOf: url)
        let job = try XCTUnwrap(ProduceJob.decode(data), "the daemon's own status answer must decode")
        XCTAssertEqual(job.chunks.map(\.index), Array(0..<job.partsTotal))
        XCTAssertEqual(job.chunks.count, job.partsTotal)
        // The fields the UI consumes: the duration line, the export's source
        // path and each chunk's status driving its phrase row.
        XCTAssertEqual(job.durationS, 6.98)
        XCTAssertEqual(job.outputPath, "/tmp/ox-say-probe/out/тестовый-ролик/тестовый-ролик.wav")
        XCTAssertEqual(job.chunks.map(\.status), [.ok, .review])
        XCTAssertEqual(job.partsToReview, 1)
    }

    /// The same probe's chunk detail (`GET /v1/produce/{id}/chunks/{n}` —
    /// chunkDetailOut): a real paragraph index, take keys and the take_files
    /// map; `style`, `pace` and `user_pick` arrive only when set.
    func testDecodesALiveChunkDetail() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("produce-chunk-live.json")
        let data = try Data(contentsOf: url)
        let detail = try XCTUnwrap(ProduceChunkDetail.decode(data), "the daemon's own chunk detail must decode")
        XCTAssertEqual(detail.index, 0)
        XCTAssertEqual(detail.paragraph, 0)
        XCTAssertEqual(detail.status, .ok)
        XCTAssertEqual(detail.text, "Привет! Сегодня расскажу, как собрать ролик за минуту.")
        XCTAssertEqual(detail.style, "тепло")
        XCTAssertEqual(detail.pace, 1.1)
        XCTAssertEqual(detail.pauseAfter, 1)
        XCTAssertEqual(detail.pick, "e688f984b0e912816fad90e2")
        XCTAssertEqual(detail.takeKeys, ["e688f984b0e912816fad90e2"])
        XCTAssertEqual(detail.takeFiles["e688f984b0e912816fad90e2"],
                       "/tmp/ox-say-probe/produce/20261016-151944-f07629/takes/e688f984b0e912816fad90e2.wav")
    }

    /// The bulk route wraps the same object in `{"chunks":[…]}`: decode must
    /// take the wrapper, keep the detail's fields, and read a null list as
    /// empty — never as a decode failure.
    func testDecodesTheLiveChunkInsideTheBulkWrapper() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("produce-chunk-live.json")
        let one = try Data(contentsOf: url)
        var wrapped = Data(#"{"chunks":["#.utf8)
        wrapped.append(one)
        wrapped.append(Data(#"]}"#.utf8))
        let list = try XCTUnwrap(StudioClient.decodeChunks(wrapped))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].takeKeys, ["e688f984b0e912816fad90e2"])
        XCTAssertEqual(list[0].paragraph, 0)
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
            ProduceText.progressRow(ProduceJob.decode(summary(status: status, done: done, total: total, reviewChunks: review))!, text: en)
        }
        XCTAssertEqual(row("running"), "“Chapter one” — 3 of 10 done")
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
        let ready = try XCTUnwrap(ProduceText.finishAlert(done, text: en))
        XCTAssertEqual(ready.title, "Voiceover ready")
        XCTAssertEqual(ready.text, "Saved as Chapter one.wav.")
        let review = try XCTUnwrap(ProduceJob.decode(summary(status: "review", wav: "/x/Ch.wav", reviewChunks: 2)))
        XCTAssertEqual(ProduceText.finishAlert(review, text: en)?.text, "Saved as Ch.wav. 2 parts need a listen. They are in the folder.")
        let failed = try XCTUnwrap(ProduceJob.decode(summary(status: "failed", error: "the disk is full")))
        XCTAssertEqual(ProduceText.finishAlert(failed, text: en)?.title, "The voiceover failed")
        XCTAssertEqual(ProduceText.finishAlert(failed, text: en)?.text, "the disk is full")
        let cancelled = try XCTUnwrap(ProduceJob.decode(summary(status: "cancelled")))
        XCTAssertNil(ProduceText.finishAlert(cancelled, text: en))
    }

    /// A loudness-only re-assembly that fails keeps the old status and reports
    /// why (internal/daemon/produce.go `outcome`): a done or review job with a
    /// non-empty error is not a saved result — the alert must say the change
    /// did not happen, never "Saved".
    /// Mutation: finishAlert without the `job.error` check on .done -> RED.
    func testAFinishedJobThatStillCarriesAnErrorIsNotCalledSaved() throws {
        let done = try XCTUnwrap(ProduceJob.decode(summary(status: "done", error: "ffmpeg quit", wav: "/x/Ch.wav")))
        let alert = try XCTUnwrap(ProduceText.finishAlert(done, text: en))
        XCTAssertEqual(alert.title, "The voiceover failed")
        XCTAssertEqual(alert.text, "ffmpeg quit")
        let review = try XCTUnwrap(ProduceJob.decode(summary(status: "review", error: "ffmpeg quit", wav: "/x/Ch.wav", reviewChunks: 2)))
        XCTAssertEqual(ProduceText.finishAlert(review, text: en)?.title, "The voiceover failed")
    }
}
