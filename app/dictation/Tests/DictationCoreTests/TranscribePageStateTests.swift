import XCTest
@testable import DictationCore

final class TranscribePageStateTests: XCTestCase {
    func testAFailedReadIsNeverAnEmptyList() {
        XCTAssertEqual(TranscribePageState.of(load: .failed("x"), hasItems: false, working: nil), .offline("x"))
        XCTAssertEqual(TranscribePageState.of(load: .loaded, hasItems: true, working: "Интервью"), .working(name: "Интервью"))
    }

    func testTheOtherStates() {
        XCTAssertEqual(TranscribePageState.of(load: .loading, hasItems: false, working: nil), .loading)
        XCTAssertEqual(TranscribePageState.of(load: .loading, hasItems: true, working: nil), .list(stale: nil))
        XCTAssertEqual(TranscribePageState.of(load: .loaded, hasItems: false, working: nil), .empty)
        XCTAssertEqual(TranscribePageState.of(load: .loaded, hasItems: true, working: nil), .list(stale: nil))
        XCTAssertEqual(TranscribePageState.of(load: .failed("x"), hasItems: true, working: nil), .list(stale: "x"),
                       "a failed refresh keeps the last good list")
    }

    func testAFileOverTheUploadCapIsRefusedBeforeUpload() {
        XCTAssertNotNil(TranscribeFileCheck.problem(bytes: Int64(TranscribeFileCheck.maxBytes) + 1, ext: "wav", text: { $0.rawValue }))
        XCTAssertNil(TranscribeFileCheck.problem(bytes: 10, ext: "mp4", text: { $0.rawValue }), "video is read through ffmpeg")
        XCTAssertNotNil(TranscribeFileCheck.problem(bytes: 10, ext: "pdf", text: { $0.rawValue }))
        XCTAssertNil(TranscribeFileCheck.problem(bytes: Int64(TranscribeFileCheck.maxBytes), ext: "WAV", text: { $0.rawValue }), "exactly the cap passes; the extension is case-blind")
        XCTAssertNotNil(TranscribeFileCheck.problem(bytes: 0, ext: "wav", text: { $0.rawValue }), "an empty file is unreadable")
    }

    func testTheTooBigSentenceNamesTheCap() {
        let sentence = TranscribeFileCheck.problem(bytes: Int64(TranscribeFileCheck.maxBytes) + 1, ext: "m4a", text: { _ in "over %@ MB" })
        XCTAssertEqual(sentence, "over 200 MB")
    }

    func testFormatsAndTheirButtons() {
        XCTAssertEqual(TranscriptFormat.srt.fileExtension, "srt")
        XCTAssertEqual(TranscriptFormat.text.fileExtension, "txt")
        XCTAssertEqual(TranscriptFormat.vtt.fileExtension, "vtt")
        XCTAssertEqual(TranscriptFormat.json.fileExtension, "json")
        XCTAssertEqual(TranscriptFormat.oxJSON.rawValue, "ox_json")
        XCTAssertEqual(TranscriptFormat.text.simpleLabelKey, .transcribeText)
        XCTAssertEqual(TranscriptFormat.srt.simpleLabelKey, .transcribeSubtitles)
        XCTAssertNil(TranscriptFormat.vtt.simpleLabelKey)
        XCTAssertNil(TranscriptFormat.json.simpleLabelKey)
    }

    func testTheFileNameIsTheTitleWithoutPathCharacters() {
        XCTAssertEqual(TranscriptFormat.srt.fileName(forTitle: "Интервью 12/30: часть 1"), "Интервью 12-30- часть 1.srt")
        XCTAssertEqual(TranscriptFormat.text.fileName(forTitle: "   ", fallback: "Transcript"), "Transcript.txt")
    }

    func testAnEntrySubtitleIsMinutesAndDay() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let e = TranscriptEntry(id: "20261030-101010-abcdef", title: "x", created: Date(timeIntervalSince1970: 1_793_354_000),
                                seconds: 720, engine: "parakeet")
        let s = e.subtitle(locale: Locale(identifier: "en"), calendar: cal, text: { _ in "%@ min" })
        XCTAssertEqual(s, "12 min · October 30")
        let short = TranscriptEntry(id: e.id, title: "x", created: e.created, seconds: 20, engine: "parakeet")
        XCTAssertTrue(short.subtitle(locale: Locale(identifier: "en"), calendar: cal, text: { _ in "%@ min" }).hasPrefix("1 min"), "never 0 min")
    }
}
