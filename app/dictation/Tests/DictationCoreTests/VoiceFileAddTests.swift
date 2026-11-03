import Foundation
import XCTest
@testable import DictationCore

/// The file sheet's decisions (VoiceFileAdd): what the form holds, what «Добавить» is allowed to send, and what
/// survives a refused add. The daemon call itself is StudioClient's.
final class VoiceFileAddTests: XCTestCase {
    private let en = ShippedStrings.localizer("en")

    private func draft() -> VoiceFileAdd {
        VoiceFileAdd(fileName: "Интервью 2026.m4a", audioPath: "/Users/me/Интервью 2026.m4a",
                     seconds: 12, bytes: 240000, ext: "m4a", studioInstalled: false)
    }

    /// The name field starts as the file's name without the extension; the person may then type over it.
    func testTheLabelStartsAsTheFileName() {
        XCTAssertEqual(draft().label, "Интервью 2026")
        XCTAssertEqual(VoiceFileAdd(fileName: "clip.wav", audioPath: "/x/clip.wav",
                                    seconds: 5, bytes: 100, ext: "wav", studioInstalled: false).label, "clip")
        XCTAssertEqual(VoiceFileAdd(fileName: "take.two.m4a", audioPath: "/x/take.two.m4a",
                                    seconds: 5, bytes: 100, ext: "m4a", studioInstalled: false).label, "take.two")
    }

    /// «Добавить» sends the slug id, the cleaned label, the clip's absolute path and the trimmed ref text; the add
    /// is then in flight.
    func testSubmitBuildsTheDaemonRequest() {
        var d = draft()
        d.edit(label: "  Мой голос ", refText: "  текст из записи  ")
        let req = d.submit(taken: [])
        XCTAssertEqual(req, VoiceFileAdd.Request(id: "moy-golos", label: "Мой голос",
                                               audioPath: "/Users/me/Интервью 2026.m4a",
                                               refText: "текст из записи"))
        XCTAssertTrue(d.sending)
        XCTAssertNil(d.problem)
    }

    /// A label that names an existing voice — by the id it slugs to, or by the label itself case-insensitively — is
    /// refused before upload; `taken` holds ids and lower-cased labels, the same rule «Описать словами» follows.
    func testATakenNameIsRefusedBeforeUpload() {
        for name in ["anna", "Studio Mara", "STUDIO MARA"] {
            var d = draft()
            d.edit(label: name, refText: "")
            XCTAssertNil(d.submit(taken: ["anna", "studio mara", "warm-narrator"], text: en), name)
            XCTAssertEqual(d.problem, en(.designProblemNameTaken), name)
            XCTAssertFalse(d.sending)
        }
        // A close-but-new name derives a fresh id and goes.
        var ok = draft()
        ok.edit(label: "anna two", refText: "")
        XCTAssertEqual(ok.submit(taken: ["anna"], text: en)?.id, "anna-two")
    }

    /// A label the daemon would reject never reaches it.
    func testAnInvalidLabelIsRefused() {
        var d = draft()
        d.edit(label: "   ", refText: "")
        XCTAssertNil(d.submit(taken: [], text: en))
        XCTAssertEqual(d.problem, en(.voicesRenameInvalid))
        XCTAssertFalse(d.sending)
    }

    /// A file the check refuses never uploads — the same sentence the sheet shows eagerly comes back on submit.
    func testARefusedFileNeverUploads() {
        var d = VoiceFileAdd(fileName: "greeting.m4a", audioPath: "/x/greeting.m4a",
                             seconds: 2, bytes: 100, ext: "m4a", studioInstalled: false)
        XCTAssertNotNil(d.fileProblem)
        XCTAssertNil(d.submit(taken: [], text: en))
        XCTAssertEqual(d.problem, en(.fileProblemTooShort))
        XCTAssertFalse(d.sending)
    }

    /// The daemon's 400/409 sentence lands in the sheet; the file, the label and the ref text all stay typed.
    func testADaemonRefusalKeepsTheInput() {
        var d = draft()
        d.edit(label: "Мой голос", refText: "слова")
        _ = d.submit(taken: [])
        d.refused("the clip could not be decoded")
        XCTAssertFalse(d.sending)
        XCTAssertEqual(d.problem, "the clip could not be decoded")
        XCTAssertEqual(d.label, "Мой голос")
        XCTAssertEqual(d.refText, "слова")
        XCTAssertEqual(d.audioPath, "/Users/me/Интервью 2026.m4a")
    }

    /// While the add is in flight the sheet may not close (a refused answer's sentence would land nowhere) and a
    /// second «Добавить» sends nothing.
    func testSendingBlocksCloseAndResubmit() {
        var d = draft()
        _ = d.submit(taken: [])
        XCTAssertFalse(d.mayClose)
        XCTAssertNil(d.submit(taken: []))
        d.refused("no")
        XCTAssertTrue(d.mayClose)
        XCTAssertNotNil(d.problem)
        // After a refusal a corrected label can be sent again.
        d.edit(label: "Другой голос", refText: d.refText)
        XCTAssertNotNil(d.submit(taken: []))
        XCTAssertNil(d.problem)
        XCTAssertTrue(d.sending)
    }
}
