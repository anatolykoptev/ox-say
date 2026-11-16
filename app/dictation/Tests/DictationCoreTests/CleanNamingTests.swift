import XCTest
@testable import DictationCore

final class CleanNamingTests: XCTestCase {
    private func name(_ path: String, picture: Bool? = nil) -> String {
        CleanNaming.defaultOutput(for: URL(fileURLWithPath: path), picture: picture)
    }

    /// Mutation: CleanNaming.defaultOutput returns the input's own file name -> RED (first assertion).
    func testNamingNeverProposesTheInput() {
        XCTAssertEqual(name("/x/Интервью.mov"), "Интервью-clean.mov")
        XCTAssertEqual(name("/x/a.mp3"), "a-clean.mp3")
        XCTAssertNotEqual(name("/x/a-clean.mp3"), "a-clean.mp3")
        XCTAssertEqual(name("/x/a-clean.mp3"), "a-clean-2.mp3")
        XCTAssertEqual(name("/x/a-clean-2.mp3"), "a-clean-3.mp3")
    }

    /// The daemon refuses a name whose kind does not fit the file: the proposal never asks for one.
    func testTheProposedExtensionIsOneTheDaemonWrites() {
        XCTAssertEqual(name("/x/voice.aac"), "voice-clean.m4a")
        XCTAssertEqual(name("/x/clip.avi"), "clip-clean.mkv")
        XCTAssertEqual(name("/x/talk.MOV"), "talk-clean.MOV")
        // An .mp4 that the app measured as having no picture is audio, and an audio name cannot end in .mp4.
        XCTAssertEqual(name("/x/talk.mp4", picture: false), "talk-clean.m4a")
        XCTAssertEqual(name("/x/talk.mp4", picture: true), "talk-clean.mp4")
        XCTAssertEqual(name("/x/talk.wav", picture: true), "talk-clean.mkv")
        for ext in CleanNaming.audioExtensions + CleanNaming.videoExtensions {
            let out = name("/x/f.\(ext)")
            XCTAssertTrue(CleanNaming.outputExtensions(picture: CleanNaming.hasPicture(URL(fileURLWithPath: "/x/f.\(ext)"), measured: nil))
                .contains(URL(fileURLWithPath: out).pathExtension), out)
        }
    }

    func testOnlyMediaFilesAreOffered() {
        XCTAssertNil(CleanFileCheck.problem(ext: "MOV"))
        XCTAssertNil(CleanFileCheck.problem(ext: "mp3"))
        XCTAssertNotNil(CleanFileCheck.problem(ext: "pdf"))
        XCTAssertNotNil(CleanFileCheck.problem(ext: ""))
    }
}
