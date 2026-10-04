import XCTest
@testable import DictationCore

final class SpeechClientTests: XCTestCase {
    /// A canned response plus the request it answered, for assertions.
    private func fakeSend(data: Data, status: Int = 200) -> (SpeechClient, () -> URLRequest?) {
        var seen: URLRequest?
        let client = SpeechClient(send: { request in
            seen = request
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        })
        return (client, { seen })
    }

    func testSpeakPostsJsonToTheSpeechRoute() async throws {
        let (client, lastRequest) = fakeSend(data: Data([1, 2, 3]))
        let audio = try await client.speak("привет", voice: "vd-ru-native")
        XCTAssertEqual(audio, Data([1, 2, 3]))
        let request = try XCTUnwrap(lastRequest())
        XCTAssertEqual(request.url?.path, "/v1/audio/speech")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["input"] as? String, "привет")
        XCTAssertEqual(json["voice"] as? String, "vd-ru-native")
        XCTAssertEqual(json["response_format"] as? String, "wav")
    }

    func testSpeakLeavesTheVoiceOutWhenNoneIsPicked() async throws {
        let (client, lastRequest) = fakeSend(data: Data([1]))
        _ = try await client.speak("hello")
        let body = try XCTUnwrap(lastRequest()?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["voice"])
    }

    func testHttpErrorBecomesSpeechError() async {
        let (client, _) = fakeSend(data: Data("{\"error\":{\"message\":\"too long\"}}".utf8), status: 400)
        do {
            _ = try await client.speak("hello")
            XCTFail("a 400 must throw")
        } catch let error as SpeechError {
            guard case .http(400, _) = error else { return XCTFail("want .http(400), got \(error)") }
        } catch {
            XCTFail("want SpeechError, got \(error)")
        }
    }

    func testEmptyBodyIsBadResponse() async {
        let (client, _) = fakeSend(data: Data())
        do {
            _ = try await client.speak("hello")
            XCTFail("an empty body must throw")
        } catch let error as SpeechError {
            XCTAssertEqual(error, .badResponse)
        } catch {
            XCTFail("want SpeechError, got \(error)")
        }
    }

    func testTimeoutBecomesTimedOut() async {
        let client = SpeechClient { _ in throw URLError(.timedOut) }
        do {
            _ = try await client.speak("hello")
            XCTFail("a timeout must throw")
        } catch let error as SpeechError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("want SpeechError, got \(error)")
        }
    }

    func testVoicesParsesTheDaemonList() async throws {
        let (client, lastRequest) = fakeSend(data: Data(#"{"voices":[{"name":"ben"},{"name":"vd-ru-male"}]}"#.utf8))
        let voices = try await client.voices()
        XCTAssertEqual(voices, ["ben", "vd-ru-male"])
        XCTAssertEqual(lastRequest()?.url?.path, "/v1/audio/voices")
    }

    /// The service turns an unusable selection into an error before the
    /// request: mutation — drop the trim/empty check in `SpeechClient.input`
    /// and this is RED (an empty selection would burn a synthesis).
    func testInputRejectsEmptyAndWhitespaceOnly() {
        XCTAssertNil(SpeechClient.input(""))
        XCTAssertNil(SpeechClient.input("   \n\t  "))
        XCTAssertEqual(SpeechClient.input("  text  "), "text")
    }
}
