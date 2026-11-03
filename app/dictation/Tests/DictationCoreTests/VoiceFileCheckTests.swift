import Foundation
import XCTest
@testable import DictationCore

/// The pure check behind «Взять из файла»: which picked files may become a voice and which need a warning. The app
/// measures the clip (AVURLAsset for the duration, the file's size for readability) and hands the numbers in; the
/// daemon's own limits are the rule — 3 s minimum, and a stored reference keeps at most the first 20 s
/// (`voices.MaxRefSeconds`), so no clip is refused on length alone.
final class VoiceFileCheckTests: XCTestCase {
    private let en = ShippedStrings.localizer("en")
    private let ru = ShippedStrings.localizer("ru")

    /// A clip under 3 s is refused before upload — a voice learns too little of the speaker from it.
    /// Mutation F1: `seconds < minimumSeconds` -> `false` -> RED.
    func testTooShortIsRefused() {
        let problem = VoiceFileCheck.problem(seconds: 2.0, bytes: 48000, ext: "m4a", text: en)
        XCTAssertNotNil(problem)
        XCTAssertFalse(problem?.hasPrefix("MISSING") ?? true)
        XCTAssertTrue(problem?.contains("3") ?? false, "the sentence names the minimum")
        let problemRU = VoiceFileCheck.problem(seconds: 2.0, bytes: 48000, ext: "m4a", text: ru)
        XCTAssertNotNil(problemRU)
        XCTAssertFalse(problemRU?.hasPrefix("MISSING") ?? true)
    }

    /// A clip past the reference window is fine to send — the voice keeps only the first 20 s, which the warning says.
    func testLongClipWarnsButPasses() {
        XCTAssertNil(VoiceFileCheck.problem(seconds: 25, bytes: 1200000, ext: "m4a", text: en))
        let warning = VoiceFileCheck.warning(seconds: 25, text: en)
        XCTAssertNotNil(warning)
        XCTAssertFalse(warning?.hasPrefix("MISSING") ?? true)
        XCTAssertTrue(warning?.contains("20") ?? false, "the warning names the 20 s the voice keeps")
        let warningRU = VoiceFileCheck.warning(seconds: 25, text: ru)
        XCTAssertTrue(warningRU?.contains("20") ?? false)
        XCTAssertFalse(warningRU?.hasPrefix("MISSING") ?? true)
    }

    /// No clip is refused on length alone — a 2-minute interview goes too: the daemon decodes only its first ~21 s
    /// and stores at most 20 s, which the warning says. Nothing in the check branches on the studio voice: the
    /// daemon's 30 s encoder window never binds on an add (the stored reference is already ≤20 s).
    /// Mutation: reintroduce a length refusal (`seconds > X { return … }`) -> RED.
    func testNoClipIsRefusedOnLengthAlone() {
        for seconds in [120.0, 3600.0] {
            XCTAssertNil(VoiceFileCheck.problem(seconds: seconds, bytes: 1000000, ext: "wav", text: en),
                         "seconds=\(seconds)")
            let warning = VoiceFileCheck.warning(seconds: seconds, text: en)
            XCTAssertNotNil(warning, "seconds=\(seconds)")
            XCTAssertTrue(warning?.contains("20") ?? false)
        }
    }

    /// Something that is not an audio clip (the picker's filter passes more than the daemon reads) is refused.
    func testNonAudioIsRefused() {
        for ext in ["pdf", "txt", "docx", "zip", ""] {
            let problem = VoiceFileCheck.problem(seconds: 10, bytes: 1000, ext: ext, text: en)
            XCTAssertNotNil(problem, ext)
            XCTAssertFalse(problem?.hasPrefix("MISSING") ?? true)
        }
    }

    /// A duration the app could not measure (the local decode failed) is not refused locally: the daemon's own 400
    /// sentence is what the sheet shows when it answers.
    func testUnknownDurationOnlyWarnsWhenDecodeFailsLater() {
        XCTAssertNil(VoiceFileCheck.problem(seconds: nil, bytes: 1200000, ext: "m4a", text: en))
        XCTAssertNil(VoiceFileCheck.warning(seconds: nil, text: en))
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
            XCTAssertNil(VoiceFileCheck.problem(seconds: 10, bytes: 1000, ext: ext, text: en), ext)
            XCTAssertNil(VoiceFileCheck.problem(seconds: 10, bytes: 1000, ext: ext.uppercased(), text: en), ext)
        }
    }

    /// An unreadable or empty file is refused even when everything else is fine.
    func testUnreadableIsRefused() {
        for bytes in [Int64(0), -1] {
            let problem = VoiceFileCheck.problem(seconds: 10, bytes: bytes, ext: "wav", text: en)
            XCTAssertNotNil(problem, "bytes=\(bytes)")
            XCTAssertFalse(problem?.hasPrefix("MISSING") ?? true)
        }
    }

    /// The boundaries: exactly the minimum passes, exactly the reference window warns nothing.
    func testTheBoundaries() {
        XCTAssertNil(VoiceFileCheck.problem(seconds: VoiceFileCheck.minimumSeconds, bytes: 1, ext: "wav", text: en))
        XCTAssertNil(VoiceFileCheck.warning(seconds: VoiceFileCheck.minimumSeconds, text: en))
        XCTAssertNil(VoiceFileCheck.warning(seconds: 20.0, text: en))
        XCTAssertNotNil(VoiceFileCheck.warning(seconds: 20.1, text: en))
    }
}
