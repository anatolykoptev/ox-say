import XCTest
@testable import DictationCore

final class TranscribeClientTests: XCTestCase {
    private let id = "20261030-101010-abcdef"

    func testTranscriptsDecodeAndSubtitlesAskForSRT() async throws {
        let (client, seen) = StudioClientFake.fake(body: #"{"transcripts":[{"id":"20261030-101010-abcdef","title":"Интервью","created":"2026-10-30T10:10:10.123456Z","seconds":720,"engine":"parakeet"}]}"#)
        let list = try await client.transcripts()
        XCTAssertEqual(list.first?.seconds, 720)
        XCTAssertEqual(list.first?.title, "Интервью")
        let expected = ISO8601DateFormatter().date(from: "2026-10-30T10:10:10Z")!.addingTimeInterval(0.123456)
        let created = try XCTUnwrap(list.first?.created)
        XCTAssertLessThan(abs(created.timeIntervalSince(expected)), 0.01)
        _ = try? await client.transcriptText(id: list[0].id, format: .srt)
        XCTAssertEqual(seen()?.url?.query, "format=srt")
        XCTAssertEqual(seen()?.url?.path, "/v1/transcripts/\(id)")
    }

    func testAWholeSecondDateAndAMissingListDecode() throws {
        let one = try XCTUnwrap(TranscriptEntry.decodeList(Data(#"{"transcripts":[{"id":"20261030-101010-abcdef","title":"","created":"2026-10-30T10:10:10Z","seconds":1.5,"engine":"whisper","language":"ru"}]}"#.utf8))?.first)
        XCTAssertEqual(one.language, "ru")
        XCTAssertEqual(TranscriptEntry.decodeList(Data(#"{"transcripts":null}"#.utf8)), [])
        XCTAssertNil(TranscriptEntry.decodeList(Data("nope".utf8)))
    }

    func testAnIdThatCouldEscapeThePathIsNotARow() throws {
        let list = try XCTUnwrap(TranscriptEntry.decodeList(Data(#"{"transcripts":[{"id":"../x","title":"t","created":"2026-10-30T10:10:10Z","seconds":1,"engine":"p"},{"id":"20261030-101010-abcdef","title":"ok","created":"2026-10-30T10:10:10Z","seconds":1,"engine":"p"}]}"#.utf8)))
        XCTAssertEqual(list.map(\.title), ["ok"])
    }

    func testDeleteIsADELETEOfThatTranscript() async throws {
        let (client, seen) = StudioClientFake.fake(status: 204, body: "")
        try await client.deleteTranscript(id: id)
        XCTAssertEqual(seen()?.httpMethod, "DELETE")
        XCTAssertEqual(seen()?.url?.path, "/v1/transcripts/\(id)")
    }

    func testTheUploadTimeoutScalesWithTheRecording() {
        XCTAssertEqual(StudioClient.transcribeTimeout(forSeconds: nil), 900)
        XCTAssertEqual(StudioClient.transcribeTimeout(forSeconds: 100), 900)
        XCTAssertEqual(StudioClient.transcribeTimeout(forSeconds: 3600), 7200)
    }

    private struct Upload { var request: URLRequest?; var body: Data? }

    private func uploadClient(status: Int = 201, body: String, error: Error? = nil, seen: @escaping (Upload) -> Void) -> StudioClient {
        StudioClient(send: { _ in throw URLError(.cannotConnectToHost) },
                     upload: { request, file in
                         seen(Upload(request: request, body: try? Data(contentsOf: file)))
                         if let error { throw error }
                         return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
                     })
    }

    private func recording() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID()).wav")
        try Data([9, 8, 7]).write(to: url)
        return url
    }

    /// The journey's wire half: the multipart body carries `file`, `title` and the options the caller gave — and no field
    /// it left out — to POST /v1/transcripts, and the answer is the new entry.
    func testTheUploadPostsTheRightFieldNames() async throws {
        let url = try recording(); defer { try? FileManager.default.removeItem(at: url) }
        var got = Upload()
        let client = uploadClient(body: #"{"id":"20261030-101010-abcdef","title":"Проба","engine":"whisper","language":"ru","created":"2026-10-30T10:10:10Z","seconds":2}"#) { got = $0 }
        let entry = try await client.transcribeFile(url, title: "Проба", engine: "whisper", language: "ru", prompt: nil, seconds: 2)
        XCTAssertEqual(entry.id, id)
        let request = try XCTUnwrap(got.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/transcripts")
        let type = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: try XCTUnwrap(got.body), as: UTF8.self)
        for name in ["file", "title", "model", "language"] { XCTAssertTrue(body.contains("name=\"\(name)\""), name) }
        XCTAssertFalse(body.contains("name=\"prompt\""), "an empty option is not sent")
        XCTAssertTrue(body.contains("name=\"title\"\r\n\r\nПроба\r\n"))
        XCTAssertEqual(request.timeoutInterval, 900)
    }

    func testSimpleModeSendsNoEngineChoice() async throws {
        let url = try recording(); defer { try? FileManager.default.removeItem(at: url) }
        var got = Upload()
        let client = uploadClient(body: #"{"id":"20261030-101010-abcdef","title":"t","engine":"parakeet","created":"2026-10-30T10:10:10Z","seconds":2}"#) { got = $0 }
        _ = try await client.transcribeFile(url, title: "t", engine: nil, language: nil, prompt: nil)
        let body = String(decoding: try XCTUnwrap(got.body), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"model\""))
        XCTAssertFalse(body.contains("name=\"language\""))
    }

    func testTheTempBodyIsRemovedAfterTheUpload() async throws {
        let url = try recording(); defer { try? FileManager.default.removeItem(at: url) }
        var path: String?
        let client = StudioClient(send: { _ in throw URLError(.cannotConnectToHost) }, upload: { request, file in
            path = file.path
            return (Data(#"{"id":"20261030-101010-abcdef","title":"t","engine":"p","created":"2026-10-30T10:10:10Z","seconds":1}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        })
        _ = try await client.transcribeFile(url, title: "t", engine: nil, language: nil, prompt: nil)
        let used = try XCTUnwrap(path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: used), "a 200 MB copy must not linger in tmp")
    }

    func testARefusedUploadCarriesTheDaemonsSentence() async throws {
        let url = try recording(); defer { try? FileManager.default.removeItem(at: url) }
        let client = uploadClient(status: 413, body: #"{"error":{"message":"upload exceeds 200 MB","type":"Request Entity Too Large"}}"#) { _ in }
        do {
            _ = try await client.transcribeFile(url, title: "t", engine: nil, language: nil, prompt: nil)
            XCTFail("a 413 must throw")
        } catch let error as StudioError {
            XCTAssertEqual(error, .refused(status: 413, message: "upload exceeds 200 MB"))
        }
    }

    func testAnUnreachableOrSlowDaemonIsNamed() async throws {
        let url = try recording(); defer { try? FileManager.default.removeItem(at: url) }
        for (thrown, expected) in [(URLError(.cannotConnectToHost), StudioError.daemonUnreachable), (URLError(.timedOut), .timedOut)] {
            let client = uploadClient(body: "", error: thrown) { _ in }
            do {
                _ = try await client.transcribeFile(url, title: "t", engine: nil, language: nil, prompt: nil)
                XCTFail("must throw")
            } catch let error as StudioError { XCTAssertEqual(error, expected) }
        }
    }

    func testAnUnreadableFileNeverReachesTheNetwork() async throws {
        var called = false
        let client = uploadClient(body: "") { _ in called = true }
        do {
            _ = try await client.transcribeFile(URL(fileURLWithPath: "/nonexistent/x.wav"), title: "t", engine: nil, language: nil, prompt: nil)
            XCTFail("must throw")
        } catch let error as StudioError { XCTAssertEqual(error, .fileUnreadable) }
        XCTAssertFalse(called)
    }

    /// The upload timeout and the size cap follow the daemon's own numbers from /status, with today's defaults when it sends none.
    /// Mutation: DaemonStatus.swift, stop reading `stt_timeout_s` (always nil) -> RED.
    func testTheLimitsComeFromTheDaemonStatusWithDefaultsForAnOlderOne() throws {
        let newer = try XCTUnwrap(DaemonStatus.decode(Data(#"{"version":"v1","config":{"stt_timeout_s":1800,"stt_max_upload_mb":77}}"#.utf8)))
        XCTAssertEqual(TranscribeLimits(status: newer), TranscribeLimits(maxBytes: 77 << 20, daemonTimeout: 1800))
        let older = try XCTUnwrap(DaemonStatus.decode(Data(#"{"version":"v1"}"#.utf8)))
        XCTAssertEqual(TranscribeLimits(status: older), .fallback)
        XCTAssertEqual(TranscribeLimits(status: nil), .fallback)
        XCTAssertEqual(TranscribeLimits.fallback, TranscribeLimits(maxBytes: Int64(TranscribeFileCheck.maxBytes), daemonTimeout: 600))
    }

    /// Mutation: TranscribeClient.swift, `transcribeTimeout` ignores `daemonTimeout` (uses 600) -> RED.
    func testTheUploadTimeoutIsTheDaemonsPlusAMargin() async throws {
        XCTAssertEqual(StudioClient.transcribeTimeout(forSeconds: 100, daemonTimeout: 1800), 1800 + StudioClient.uploadMargin)
        XCTAssertEqual(StudioClient.transcribeTimeout(forSeconds: 3600, daemonTimeout: 1800), 7200, "never under twice the recording")
        let url = try recording(); defer { try? FileManager.default.removeItem(at: url) }
        var got = Upload()
        let client = uploadClient(body: #"{"id":"20261030-101010-abcdef","title":"t","engine":"p","created":"2026-10-30T10:10:10Z","seconds":1}"#) { got = $0 }
        _ = try await client.transcribeFile(url, title: "t", engine: nil, language: nil, prompt: nil, seconds: 10,
                                            limits: TranscribeLimits(maxBytes: 1 << 20, daemonTimeout: 1800))
        XCTAssertEqual(got.request?.timeoutInterval, 2100)
    }

    /// A file that is over the daemon's cap when it is staged (it grew after the check) is stopped and never uploaded.
    /// Mutation: TranscribeClient.swift, drop `maxFileBytes: limits.maxBytes` from the MultipartFile.write call -> RED.
    func testAFileOverTheCapAtStagingIsNeverUploaded() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grown-\(UUID()).wav")
        try Data(count: (1 << 20) + 1).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var called = false
        let client = uploadClient(body: "") { _ in called = true }
        do {
            _ = try await client.transcribeFile(url, title: "t", engine: nil, language: nil, prompt: nil,
                                                limits: TranscribeLimits(maxBytes: 1 << 20, daemonTimeout: 600))
            XCTFail("must throw")
        } catch let error as StudioError {
            XCTAssertEqual(error, .fileTooLarge(megabytes: 1))
        }
        XCTAssertFalse(called)
    }

    func testALineBreakInTheTitleNeverReachesTheNetwork() async throws {
        let url = try recording(); defer { try? FileManager.default.removeItem(at: url) }
        var called = false
        let client = uploadClient(body: "") { _ in called = true }
        do {
            _ = try await client.transcribeFile(url, title: "a\r\nb", engine: nil, language: nil, prompt: nil)
            XCTFail("must throw")
        } catch let error as StudioError { XCTAssertEqual(error, .fileUnreadable) }
        XCTAssertFalse(called)
    }
}
