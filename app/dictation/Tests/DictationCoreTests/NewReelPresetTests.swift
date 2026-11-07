import XCTest
@testable import DictationCore

final class NewReelPresetTests: XCTestCase {
    func testNewReelIsTheReelsPresetWithOneVariantAndReferenceClone() {
        XCTAssertEqual(NewReelPreset.format.preset, "reels")
        XCTAssertEqual(NewReelPreset.options().takes, 1)
        XCTAssertEqual(NewReelPreset.options().cloneMode, "reference")
    }
}

extension NewReelPresetTests {
    func testAReelStartsAsAShortProjectAndALongOneIsUntouched() throws {
        let reel = try XCTUnwrap(SpeakStudio.start(text: "Привет, мир.", reel: true))
        XCTAssertEqual(reel.format, .short)
        XCTAssertEqual(reel.options, NewReelPreset.options())
        let plain = try XCTUnwrap(SpeakStudio.start(text: "Привет, мир."))
        XCTAssertEqual(plain.format, .long)
        XCTAssertEqual(plain.options.cloneMode, "reference")
        XCTAssertNil(plain.options.takes)
    }

    func testTheOfferToKeepTheFirstPartAppearsOnlyForAStudioTextOverTheCap() {
        let over = String(repeating: "а", count: ScriptLimit.maxCharacters + 1)
        XCTAssertTrue(SpeakStudio.offersFirstPart(text: over, engine: .studio))
        XCTAssertFalse(SpeakStudio.offersFirstPart(text: "short", engine: .studio))
        XCTAssertFalse(SpeakStudio.offersFirstPart(text: over, engine: .fast), "the fast voice has its own cap and no trim")
    }
}
