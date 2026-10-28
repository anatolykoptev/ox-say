import XCTest
@testable import DictationCore

/// #293 item 2 — the Russian remote-clipboard notice fills the pill's three
/// lines and used to hide after a flat 4 s.
final class PillTimingTests: XCTestCase {
    private func localized(_ key: String, _ lang: String) -> String? {
        // Resources live next to the package; read the .strings file directly.
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/\(lang).lproj/Localizable.strings")
        guard let dict = NSDictionary(contentsOf: path) as? [String: String] else { return nil }
        return dict[key]
    }

    /// A short message keeps the old 4 s.
    func testAShortMessageKeepsFourSeconds() {
        XCTAssertEqual(PillTiming.messageSeconds(characters: 0), 4)
        XCTAssertEqual(PillTiming.messageSeconds(characters: 40), 4)
    }

    /// Longer text stays longer, monotonically, up to a cap.
    /// Mutation: return the flat base in PillTiming.messageSeconds -> RED.
    func testALongerMessageStaysLonger() {
        let a = PillTiming.messageSeconds(characters: 100)
        let b = PillTiming.messageSeconds(characters: 130)
        XCTAssertGreaterThan(a, 4)
        XCTAssertGreaterThan(b, a)
    }

    /// Never longer than the cap, whatever the text.
    /// Mutation: drop the min(cap) -> RED.
    func testTheDelayIsCapped() {
        XCTAssertEqual(PillTiming.messageSeconds(characters: 100_000), PillTiming.maxMessageSeconds)
        XCTAssertLessThanOrEqual(PillTiming.maxMessageSeconds, 12)
    }

    /// The real Russian notice (the longest) gets at least ~15 chars/second of
    /// reading time and more than the flat 4 s.
    func testTheRussianRemoteClipboardNoticeHasTimeToRead() throws {
        let ru = try XCTUnwrap(localized("notice.selection_remote_clipboard", "ru"))
        let seconds = PillTiming.messageSeconds(characters: ru.count)
        XCTAssertGreaterThan(seconds, 4)
        XCTAssertGreaterThanOrEqual(seconds * 20, Double(ru.count), "under 20 chars/second is too fast to read")
    }
}
