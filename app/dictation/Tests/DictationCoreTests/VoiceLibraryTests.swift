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
        XCTAssertEqual(list[0].subtitle(locale: ru, calendar: cal, text: ShippedStrings.localizer("ru")), "Записан 28 октября")
        XCTAssertEqual(list[1].subtitle(locale: ru, calendar: cal, text: ShippedStrings.localizer("ru")), "Создан по описанию")
        XCTAssertEqual(list[2].subtitle(locale: ru, calendar: cal, text: ShippedStrings.localizer("ru")), "Добавлен 1 сентября")
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(list[0].subtitle(locale: en, calendar: cal, text: ShippedStrings.localizer("en")), "Recorded October 28")
        XCTAssertEqual(VoiceEntry(id: "f", label: "F", kind: .file)
            .subtitle(locale: ru, calendar: cal, text: ShippedStrings.localizer("ru")), "Из файла")
    }

    /// No `created` — or Go's zero time, which a Time with no value marshals as
    /// "0001-01-01T00:00:00Z" — means no date in the line, in both languages and
    /// for both kinds that carry one. Never today's date, never "1 January".
    /// Mutation F6: VoiceLibrary.subtitle, `knownCreated` -> `created` -> RED.
    func testNoDateOrGoZeroTimeShowsNoDate() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let zero = Data(#"{"voices":[{"name":"a","source":"recorded","created":"0001-01-01T00:00:00Z"},{"name":"b","created":"0001-01-01T00:00:00Z"},{"name":"c","source":"recorded"},{"name":"d"}]}"#.utf8)
        let list = try! XCTUnwrap(VoiceEntry.decodeList(zero))
        let ru = list.map { $0.subtitle(locale: Locale(identifier: "ru_RU"), calendar: cal, text: ShippedStrings.localizer("ru")) }
        let en = list.map { $0.subtitle(locale: Locale(identifier: "en_US"), calendar: cal, text: ShippedStrings.localizer("en")) }
        XCTAssertEqual(ru, ["Записан", "Добавлен", "Записан", "Добавлен"])
        XCTAssertEqual(en, ["Recorded", "Added", "Recorded", "Added"])
        // The same when the entry is built in code with year 1.
        let year1 = ISO8601DateFormatter().date(from: "0001-01-01T00:00:00Z")
        XCTAssertEqual(VoiceEntry(id: "z", label: "Z", kind: .recorded, created: year1)
            .subtitle(locale: Locale(identifier: "en_US"), calendar: cal, text: ShippedStrings.localizer("en")), "Recorded")
    }

    /// A daemon that predates label/source/created still decodes; an entry
    /// with no date shows no date rather than inventing one.
    func testDecodeToleratesAnOlderDaemonsBareVoice() {
        let bare = Data(#"{"voices":[{"name":"old"}]}"#.utf8)
        let list = try! XCTUnwrap(VoiceEntry.decodeList(bare))
        XCTAssertEqual(list, [VoiceEntry(id: "old", label: "old", kind: .other)])
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(list[0].subtitle(locale: Locale(identifier: "ru_RU"), calendar: cal,
                                        text: ShippedStrings.localizer("ru")), "Добавлен")
    }

    /// A voice whose only extra is a source, and a malformed envelope.
    func testSourceOnlyDecodesAndAMalformedListIsNil() {
        let file = Data(#"{"voices":[{"name":"iz-fayla","source":"file"}],"other":[]}"#.utf8)
        XCTAssertEqual(VoiceEntry.decodeList(file)?.first?.kind, .file)
        XCTAssertNil(VoiceEntry.decodeList(Data(#"{"voices":3}"#.utf8)))
        XCTAssertNil(VoiceEntry.decodeList(Data(#"{"voices":"x"}"#.utf8)))
        XCTAssertNil(VoiceEntry.decodeList(Data(#"{"voices":{}}"#.utf8)))
        XCTAssertNil(VoiceEntry.decodeList(Data("not json".utf8)))
    }

    /// An empty library is not a failed read. The daemon's List() returns a nil
    /// slice with no voices, which handleListVoices (internal/daemon/http.go)
    /// writes as `{"voices":null}`; a daemon that omits the key writes `{}`.
    /// Both, and `[]`, are an empty list that reaches the empty state.
    /// Mutation F1: VoiceLibrary.decodeList, `?? []` on the voices lookup removed -> RED.
    func testAnEmptyLibraryDecodesToEmptyAndReachesTheEmptyState() {
        for body in [#"{"voices":null}"#, #"{"voices":[]}"#, "{}"] {
            let list = VoiceEntry.decodeList(Data(body.utf8))
            XCTAssertEqual(list, [], body)
            XCTAssertEqual(VoicesPageState.of(load: .loaded, hasVoices: !(list ?? [VoiceEntry(id: "x", label: "x", kind: .other)]).isEmpty),
                           .empty, body)
        }
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

    /// What a picker row reads: the label of a renamed voice, not its id; an id that names no entry — or an entry
    /// whose label is empty — falls back to the id itself. The pick and the tag keep the id either way.
    /// Mutation: `[VoiceEntry].title(for:)` -> `id` -> RED.
    func testAPickerTitleIsTheLabelOrTheId() {
        let entries = [VoiceEntry(id: "warm-narrator", label: "Calm narrator", kind: .recorded),
                       VoiceEntry(id: "empty", label: "", kind: .other)]
        XCTAssertEqual(entries.title(for: "warm-narrator"), "Calm narrator")
        XCTAssertEqual(entries.title(for: "gone"), "gone")
        XCTAssertEqual(entries.title(for: "empty"), "empty")
    }
}
