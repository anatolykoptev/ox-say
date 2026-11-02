import Foundation
import XCTest
@testable import DictationCore

final class VoiceLibraryTests: XCTestCase {
    /// A daemon answer as it ships today: a labelled recording, a designed
    /// voice (designed_from + engine, no source), and a voice older than
    /// labels and sources alike. The first `created` is fractional, as Go's
    /// time.Time actually marshals.
    private let json = Data(#"{"voices":[{"name":"moy-golos","label":"Мой голос","created":"2026-10-28T10:00:00.123456Z","source":"recorded"},{"name":"diktor","designed_from":"спокойный диктор","engine":"voxcpm2","created":"2026-10-29T10:00:00Z"},{"name":"old","created":"2026-09-01T10:00:00Z"}]}"#.utf8)

    /// Mutation F3: VoiceLibrary.decode, `?? name` removed -> RED (unlabelled
    /// voices come out labelled "").
    func testDecodeUsesTheLabelAndFallsBackToTheId() {
        let list = try! XCTUnwrap(VoiceEntry.decodeList(json))
        XCTAssertEqual(list.map(\.label), ["Мой голос", "diktor", "old"])
        XCTAssertEqual(list.map(\.kind), [.recorded, .designed("спокойный диктор"), .other])
        XCTAssertEqual(list.map(\.id), ["moy-golos", "diktor", "old"])
        XCTAssertEqual(list.map(\.engine), [nil, "voxcpm2", nil])
    }

    /// The subtitle says where the voice came from, in the person's language;
    /// a date belongs only to the kinds where it adds something.
    func testSubtitleSaysHowTheVoiceCameToBe() {
        let ru = Locale(identifier: "ru_RU"); var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let list = VoiceEntry.decodeList(json)!
        let now = ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z")!
        XCTAssertEqual(list[0].subtitle(now: now, locale: ru, calendar: cal, text: ShippedStrings.localizer("ru")), "Записан 28 октября")
        XCTAssertEqual(list[1].subtitle(now: now, locale: ru, calendar: cal, text: ShippedStrings.localizer("ru")), "Создан по описанию")
        XCTAssertEqual(list[2].subtitle(now: now, locale: ru, calendar: cal, text: ShippedStrings.localizer("ru")), "Добавлен 1 сентября")
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(list[0].subtitle(now: now, locale: en, calendar: cal, text: ShippedStrings.localizer("en")), "Recorded October 28")
        XCTAssertEqual(VoiceEntry(id: "f", label: "F", kind: .file)
            .subtitle(now: now, locale: ru, calendar: cal, text: ShippedStrings.localizer("ru")), "Из файла")
    }

    /// A daemon that predates label/source/created still decodes; an entry
    /// with no date is reported as of "now" rather than inventing one.
    func testDecodeToleratesAnOlderDaemonsBareVoice() {
        let bare = Data(#"{"voices":[{"name":"old"}]}"#.utf8)
        let list = try! XCTUnwrap(VoiceEntry.decodeList(bare))
        XCTAssertEqual(list, [VoiceEntry(id: "old", label: "old", kind: .other)])
        let now = ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(list[0].subtitle(now: now, locale: Locale(identifier: "ru_RU"), calendar: cal,
                                        text: ShippedStrings.localizer("ru")), "Добавлен 1 ноября")
    }

    /// A voice whose only extra is a source, and a malformed envelope.
    func testSourceOnlyDecodesAndAMalformedListIsNil() {
        let file = Data(#"{"voices":[{"name":"iz-fayla","source":"file"}],"other":[]}"#.utf8)
        XCTAssertEqual(VoiceEntry.decodeList(file)?.first?.kind, .file)
        XCTAssertNil(VoiceEntry.decodeList(Data(#"{"voices":3}"#.utf8)))
        XCTAssertNil(VoiceEntry.decodeList(Data("not json".utf8)))
    }

    /// Mutation F2: VoicesPageState.of, `.failed` -> `.empty` -> RED.
    func testPageStateNeverShowsAFailedReadAsAnEmptyLibrary() {
        XCTAssertEqual(VoicesPageState.of(load: .failed("x"), hasVoices: false), .unreachable("x"))
        XCTAssertEqual(VoicesPageState.of(load: .failed("x"), hasVoices: true), .list(stale: "x"))
        XCTAssertEqual(VoicesPageState.of(load: .loaded, hasVoices: false), .empty)
        XCTAssertEqual(VoicesPageState.of(load: .loaded, hasVoices: true), .list(stale: nil))
        XCTAssertEqual(VoicesPageState.of(load: .loading, hasVoices: true), .list(stale: nil))
        XCTAssertEqual(VoicesPageState.of(load: .loading, hasVoices: false), .loading)
    }
}
