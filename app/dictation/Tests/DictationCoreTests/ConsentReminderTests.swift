import XCTest
@testable import DictationCore

final class ConsentReminderTests: XCTestCase {
    private let en = ShippedStrings.localizer("en")
    private let ru = ShippedStrings.localizer("ru")

    private func keep(_ r: MeetingRetention, _ t: (L10nKey) -> String) -> String {
        let body = ConsentReminder.body(retention: r, text: t)
        XCTAssertFalse(body.contains("%"), "every placeholder filled: \(body)")
        XCTAssertFalse(body.contains("MISSING"))
        return body
    }

    /// The reminder states the retention the user actually has.
    /// Mutation: ConsentReminder.body, `retention.days` -> `30` -> RED (7 and 90 name 30 days).
    func testTheReminderNamesTheRealRetention() {
        XCTAssertTrue(keep(.week, en).contains("keeps the audio for 7 days"))
        XCTAssertTrue(keep(.month, en).contains("keeps the audio for 30 days"))
        XCTAssertTrue(keep(.quarter, en).contains("keeps the audio for 90 days"))
        XCTAssertTrue(keep(.forever, en).contains("keeps the audio until you delete it"))
        XCTAssertFalse(keep(.forever, en).contains("days"))
        XCTAssertTrue(keep(.week, ru).contains("хранит звук 7 дней"))
        XCTAssertTrue(keep(.month, ru).contains("хранит звук 30 дней"))
        XCTAssertTrue(keep(.quarter, ru).contains("хранит звук 90 дней"))
        XCTAssertTrue(keep(.forever, ru).contains("хранит звук, пока вы его не удалите"))
        XCTAssertFalse(keep(.forever, ru).contains("дней"))
    }

    /// Nothing is claimed about the notes folder, which the user may sync.
    func testNoClaimThatNothingLeavesTheMac() {
        for r in MeetingRetention.allCases {
            XCTAssertTrue(keep(r, en).contains("ox-say sends nothing anywhere."))
            XCTAssertTrue(keep(r, ru).contains("ox-say ничего никуда не отправляет."))
            XCTAssertFalse(keep(r, en).contains("leaves your Mac"))
        }
    }
}
