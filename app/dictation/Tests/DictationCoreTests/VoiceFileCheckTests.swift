import Foundation
import XCTest
@testable import DictationCore

/// The pure check behind «Взять из файла»: which picked files may become a voice and which need a warning. The app
/// measures the clip (AVURLAsset for the duration, the file's size for readability) and hands the numbers in; the
/// daemon's own limits are the rule — 3 s minimum, a stored reference keeps at most 20 s (`voices.MaxRefSeconds`),
/// and the studio encoder's window is 30 s (`voxMaxRefSeconds`).
final class VoiceFileCheckTests: XCTestCase {
    private let en = ShippedStrings.localizer("en")
    private let ru = ShippedStrings.localizer("ru")

    /// A clip under 3 s is refused before upload — a voice learns too little of the speaker from it.
    /// Mutation F1: `seconds < minimumSeconds` -> `false` -> RED.
    func testTooShortIsRefused() {
        let problem = VoiceFileCheck.problem(seconds: 2.0, bytes: 48000, ext: "m4a",
                                             studioInstalled: false, text: en)
        XCTAssertNotNil(problem)
        XCTAssertFalse(problem?.hasPrefix("MISSING") ?? true)
        XCTAssertTrue(problem?.contains("3") ?? false, "the sentence names the minimum")
        let problemRU = VoiceFileCheck.problem(seconds: 2.0, bytes: 48000, ext: "m4a",
                                               studioInstalled: true, text: ru)
        XCTAssertNotNil(problemRU)
        XCTAssertFalse(problemRU?.hasPrefix("MISSING") ?? true)
    }

    /// A clip past the reference window is fine to send — the voice keeps only the first 20 s, which the warning says.
    func testLongClipWarnsButPasses() {
        XCTAssertNil(VoiceFileCheck.problem(seconds: 25, bytes: 1200000, ext: "m4a",
                                            studioInstalled: false, text: en))
        let warning = VoiceFileCheck.warning(seconds: 25, studioInstalled: false, text: en)
        XCTAssertNotNil(warning)
        XCTAssertFalse(warning?.hasPrefix("MISSING") ?? true)
        XCTAssertTrue(warning?.contains("20") ?? false, "the warning names the 20 s the voice keeps")
        let warningRU = VoiceFileCheck.warning(seconds: 25, studioInstalled: false, text: ru)
        XCTAssertTrue(warningRU?.contains("20") ?? false)
        XCTAssertFalse(warningRU?.hasPrefix("MISSING") ?? true)
        // The studio voice installed: still warned (the stored reference keeps 20 s either way) and still not refused.
        XCTAssertNil(VoiceFileCheck.problem(seconds: 25, bytes: 1200000, ext: "m4a",
                                            studioInstalled: true, text: en))
        XCTAssertNotNil(VoiceFileCheck.warning(seconds: 25, studioInstalled: true, text: en))
    }

    /// Something that is not an audio clip (the picker's filter passes more than the daemon reads) is refused.
    func testNonAudioIsRefused() {
        for ext in ["pdf", "txt", "docx", "zip", ""] {
            let problem = VoiceFileCheck.problem(seconds: 10, bytes: 1000, ext: ext,
                                                 studioInstalled: false, text: en)
            XCTAssertNotNil(problem, ext)
            XCTAssertFalse(problem?.hasPrefix("MISSING") ?? true)
        }
    }

    /// A duration the app could not measure (the local decode failed) is not refused locally: the daemon's own 400
    /// sentence is what the sheet shows when it answers.
    func testUnknownDurationOnlyWarnsWhenDecodeFailsLater() {
        XCTAssertNil(VoiceFileCheck.problem(seconds: nil, bytes: 1200000, ext: "m4a",
                                            studioInstalled: false, text: en))
        XCTAssertNil(VoiceFileCheck.warning(seconds: nil, studioInstalled: false, text: en))
        let daemonSentence = "the clip could not be decoded"
        let error = StudioError.refused(status: 400, message: daemonSentence)
        XCTAssertEqual(StudioError.plain(error, text: en), daemonSentence,
                       "the daemon's own words reach the sheet unchanged")
    }

    /// The accepted list is exactly what the plan fixes — the formats the daemon's ffmpeg decodes — and an
    /// upper-cased extension still counts (".M4A" from a camera).
    func testTheAcceptedExtensionsAreTheDaemonList() {
        XCTAssertEqual(VoiceFileCheck.audioExtensions,
                       ["wav", "mp3", "m4a", "aif", "aiff", "flac", "caf", "ogg", "opus", "mp4", "mov"])
        for ext in VoiceFileCheck.audioExtensions {
            XCTAssertNil(VoiceFileCheck.problem(seconds: 10, bytes: 1000, ext: ext,
                                                studioInstalled: false, text: en), ext)
            XCTAssertNil(VoiceFileCheck.problem(seconds: 10, bytes: 1000, ext: ext.uppercased(),
                                                studioInstalled: false, text: en), ext)
        }
    }

    /// An unreadable or empty file is refused even when everything else is fine.
    func testUnreadableIsRefused() {
        for bytes in [Int64(0), -1] {
            let problem = VoiceFileCheck.problem(seconds: 10, bytes: bytes, ext: "wav",
                                                 studioInstalled: false, text: en)
            XCTAssertNotNil(problem, "bytes=\(bytes)")
            XCTAssertFalse(problem?.hasPrefix("MISSING") ?? true)
        }
    }

    /// The boundaries: exactly the minimum passes, exactly the reference window warns nothing.
    func testTheBoundaries() {
        XCTAssertNil(VoiceFileCheck.problem(seconds: VoiceFileCheck.minimumSeconds, bytes: 1, ext: "wav",
                                            studioInstalled: false, text: en))
        XCTAssertNil(VoiceFileCheck.warning(seconds: VoiceFileCheck.minimumSeconds, studioInstalled: false, text: en))
        XCTAssertNil(VoiceFileCheck.warning(seconds: 20.0, studioInstalled: false, text: en))
        XCTAssertNotNil(VoiceFileCheck.warning(seconds: 20.1, studioInstalled: false, text: en))
    }

    /// Past the studio encoder's window the add is refused — but only where that engine exists: a fast-only daemon
    /// still accepts the clip and cuts it at 20 s (the warning says so).
    func testPastTheStudioWindowIsRefusedOnlyWithTheStudioVoice() {
        XCTAssertNil(VoiceFileCheck.problem(seconds: 35, bytes: 1000, ext: "wav",
                                            studioInstalled: false, text: en))
        XCTAssertNotNil(VoiceFileCheck.warning(seconds: 35, studioInstalled: false, text: en))
        let problem = VoiceFileCheck.problem(seconds: 35, bytes: 1000, ext: "wav",
                                             studioInstalled: true, text: en)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("30") ?? false, "the refusal names the studio window")
        // The refusal stands, so no warning is needed.
        XCTAssertNil(VoiceFileCheck.warning(seconds: 35, studioInstalled: true, text: en))
    }
}
