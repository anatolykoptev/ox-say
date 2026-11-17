import Foundation
import XCTest
@testable import DictationCore

/// The Glossary page's evidence cell: a candidate shows its progress toward activation, any other pair the plain
/// count, and the tooltip says where the sightings came from. Both languages are read from the shipped .lproj files.
final class GlossaryProgressTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func withLocale(_ code: String, _ body: () -> Void) {
        let saved = L10nBundle.bundle
        defer { L10nBundle.bundle = saved }
        guard let bundle = Bundle(path: packageRoot.appendingPathComponent("Resources/\(code).lproj").path) else {
            return XCTFail("no \(code).lproj")
        }
        L10nBundle.bundle = bundle
        body()
    }

    private func pair(_ status: GlossaryStatus, sightings: Int, dictation: Int = 0, needed: Int) -> GlossaryPair {
        GlossaryPair(id: "a1", heard: "зорбекс", meant: "Zorbax", status: status, seen: 1,
                     sightings: sightings, seenDictation: dictation, needed: needed)
    }

    /// Mutation: GlossaryPair.progressText, return String(sightings) for every status -> RED.
    func testACandidateShowsProgressTowardActivation() {
        withLocale("en") { XCTAssertEqual(pair(.candidate, sightings: 1, needed: 2).progressText, "1 of 2") }
        withLocale("ru") { XCTAssertEqual(pair(.candidate, sightings: 1, needed: 2).progressText, "1 из 2") }
        withLocale("en") { XCTAssertEqual(pair(.candidate, sightings: 2, needed: 3).progressText, "2 of 3") }
    }

    func testOtherPairsAndAnOlderDaemonShowThePlainCount() {
        withLocale("en") {
            XCTAssertEqual(pair(.active, sightings: 4, needed: 2).progressText, "4")
            XCTAssertEqual(pair(.rejected, sightings: 1, needed: 2).progressText, "1")
            XCTAssertEqual(pair(.candidate, sightings: 1, needed: 0).progressText, "1")
        }
    }

    /// A borrowed activation can leave a candidate with more sentences than its own threshold: never «3 of 2».
    func testProgressNeverExceedsWhatIsNeeded() {
        withLocale("en") { XCTAssertEqual(pair(.candidate, sightings: 5, needed: 2).progressText, "2 of 2") }
    }

    func testTheTooltipSplitsDictationFromAgents() {
        withLocale("en") {
            XCTAssertEqual(pair(.candidate, sightings: 3, dictation: 2, needed: 2).provenanceText,
                           "Heard again in dictation: 2. Filed by assistants: 1.")
        }
        withLocale("ru") {
            XCTAssertEqual(pair(.candidate, sightings: 3, dictation: 2, needed: 2).provenanceText,
                           "Снова услышано в диктовке: 2. Предложено ассистентами: 1.")
        }
    }

    /// The list row carries the new fields; a row from an older daemon without them reads as 0.
    func testDecodeReadsSightingsSeenDictationAndNeeded() throws {
        let rows = #"{"pairs":[{"id":"a1","heard":"x","meant":"y","status":"candidate","seen":1,"sightings":["aa","bb"],"seen_dictation":1,"needed":3},"#
            + #"{"id":"a2","heard":"p","meant":"q","status":"active","seen":2}]}"#
        let got = try XCTUnwrap(GlossaryPair.decodeList(Data(rows.utf8)))
        XCTAssertEqual([got[0].sightings, got[0].seenDictation, got[0].needed], [2, 1, 3])
        XCTAssertEqual([got[1].sightings, got[1].seenDictation, got[1].needed], [0, 0, 0])
    }
}
