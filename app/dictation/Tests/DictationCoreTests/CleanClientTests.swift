import XCTest
@testable import DictationCore

final class CleanClientTests: XCTestCase {
    private let ok = #"{"out_path":"/tmp/o.mov","video":true,"input_seconds":180,"elapsed_s":14.2,"wet":0.85,"stereo":"mid","sample_rate":48000,"channels":2}"#

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request?.httpBody)) as? [String: Any])
    }

    /// The wire half: the paths, the default mix and a refusal to overwrite go to POST /v1/audio/clean.
    /// Mutation: CleanClient.swift `"overwrite": overwrite` -> `"overwrite": true` -> RED (the overwrite assertion).
    func testCleanBodyCarriesPathsAndTheDefaultMix() async throws {
        let (client, seen) = StudioClientFake.fake(body: ok)
        let r = try await client.cleanVoice(input: URL(fileURLWithPath: "/tmp/i.mov"), output: URL(fileURLWithPath: "/tmp/o.mov"), timeout: 1800)
        let sent = try body(seen())
        XCTAssertEqual(seen()?.url?.path, "/v1/audio/clean")
        XCTAssertEqual(seen()?.httpMethod, "POST")
        XCTAssertEqual(sent["in_path"] as? String, "/tmp/i.mov")
        XCTAssertEqual(sent["out_path"] as? String, "/tmp/o.mov")
        XCTAssertEqual(sent["wet"] as? Double, 0.85)
        XCTAssertEqual(sent["stereo"] as? String, "mid")
        XCTAssertEqual(sent["overwrite"] as? Bool, false)
        XCTAssertEqual(seen()?.timeoutInterval, 1800)
        XCTAssertEqual(r, CleanResult(outPath: "/tmp/o.mov", video: true, inputSeconds: 180, elapsedSeconds: 14.2))
    }

    func testOverwriteIsSentOnlyWhenAsked() async throws {
        let (client, seen) = StudioClientFake.fake(body: ok)
        _ = try await client.cleanVoice(input: URL(fileURLWithPath: "/a.mov"), output: URL(fileURLWithPath: "/b.mov"), overwrite: true, timeout: 1)
        let sent = try body(seen())
        XCTAssertEqual(sent["overwrite"] as? Bool, true)
    }

    /// Every code the daemon sends maps to one problem with its own words in both languages: never the daemon's English.
    /// Mutation: CleanProblem.of, `case "forbidden_path"` -> `.failed` -> RED (forbidden row).
    func testEachDaemonRefusalIsItsOwnPlainProblem() async {
        let table: [(Int, String, CleanProblem)] = [
            (409, "busy", .busy), (503, "busy", .busySystem), (503, "gpu_busy", .gpuBusy),
            (503, "models_downloading", .modelDownloading), (503, "models_download_failed", .modelDownloadFailed),
            (503, "models_missing", .notInstalled), (503, "models_unusable", .notInstalled), (503, "engine_missing", .notInstalled),
            (503, "os_too_old", .osTooOld), (507, "disk_space", .diskFull), (502, "engine_output", .diskFull),
            (409, "exists", .outputExists), (409, "same_file", .sameFile), (403, "forbidden_path", .forbidden),
            (404, "not_found", .notFound), (422, "no_audio", .noAudio), (422, "unsupported_channels", .channels),
            (422, "too_long", .tooLong), (400, "invalid_request", .badOutput), (504, "engine_timeout", .timedOut),
            (503, "engine_interrupted", .interrupted), (502, "engine_failed", .failed), (502, "model_wrong_answer", .failed),
        ]
        for (status, code, want) in table {
            let (client, _) = StudioClientFake.fake(status: status, body: #"{"error":{"message":"RAW ENGLISH SENTENCE","code":"\#(code)"}}"#)
            do {
                _ = try await client.cleanVoice(input: URL(fileURLWithPath: "/a.mov"), output: URL(fileURLWithPath: "/b.mov"), timeout: 1)
                XCTFail("\(code) did not throw")
            } catch let error as CleanError {
                XCTAssertEqual(error.problem, want, "\(status) \(code)")
                XCTAssertFalse(error.problem.sentence().contains("RAW ENGLISH"), code)
            } catch {
                XCTFail("\(code): \(error)")
            }
        }
    }

    /// A refusal without a usable body still says something plain, and a full disk is told by its status.
    func testABodylessRefusalIsPlain() {
        XCTAssertEqual(CleanProblem.of(status: 500, code: nil), .failed)
        XCTAssertEqual(CleanProblem.of(status: 507, code: nil), .diskFull)
        XCTAssertEqual(CleanProblem.of(status: 403, code: "something_new"), .failed)
    }

    func testEveryProblemHasWordsInBothLanguages() {
        let all: [CleanProblem] = [.busy, .busySystem, .gpuBusy, .modelDownloading, .modelDownloadFailed, .notInstalled, .osTooOld,
                                   .diskFull, .outputExists, .sameFile, .forbidden, .notFound, .noAudio, .channels, .tooLong,
                                   .badOutput, .timedOut, .interrupted, .failed]
        let keys = Set(all.map(\.key))
        XCTAssertEqual(keys.count, all.count, "two problems share one sentence")
    }

    func testACancelledRequestIsACancelNotAFailure() async {
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            let client = StudioClient(send: { _ in throw error })
            do {
                _ = try await client.cleanVoice(input: URL(fileURLWithPath: "/a.mov"), output: URL(fileURLWithPath: "/b.mov"), timeout: 1)
                XCTFail("no throw")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
        }
    }

    func testTransportFailuresAreStudioErrors() async {
        for (thrown, want) in [(URLError(.timedOut), StudioError.timedOut), (URLError(.cannotConnectToHost), StudioError.daemonUnreachable)] {
            let client = StudioClient(send: { _ in throw thrown })
            do {
                _ = try await client.cleanVoice(input: URL(fileURLWithPath: "/a.mov"), output: URL(fileURLWithPath: "/b.mov"), timeout: 1)
                XCTFail("no throw")
            } catch {
                XCTAssertEqual(error as? StudioError, want)
            }
        }
    }

    func testTheTimeoutHasAFloorAndScalesWithTheFile() {
        XCTAssertEqual(StudioClient.cleanTimeout(forSeconds: nil), 1800)
        XCTAssertEqual(StudioClient.cleanTimeout(forSeconds: 600), 1800)
        XCTAssertEqual(StudioClient.cleanTimeout(forSeconds: 4 * 3600), 7200)
    }
}
