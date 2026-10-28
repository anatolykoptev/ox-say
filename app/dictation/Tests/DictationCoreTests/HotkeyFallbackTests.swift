import Foundation
import XCTest
@testable import DictationCore

/// #62: a dictation key that fails to register hands over to the other offered
/// key instead of leaving dictation without one, and says so once.
final class HotkeyFallbackTests: XCTestCase {
    let space = 49, control = 0x1000, option = 0x800
    var ctrl: ShortcutMenu.Choice { ShortcutMenu.Choice(title: "⌃Space", keyCode: space, modifiers: control) }
    var opt: ShortcutMenu.Choice { ShortcutMenu.Choice(title: "⌥Space", keyCode: space, modifiers: option) }
    var offers: [ShortcutMenu.Choice] { [ctrl, opt] }
    var macOwnsCtrl: [SystemShortcut] { [SystemShortcut(keyCode: space, modifiers: control, enabled: true)] }
    var macOwnsOpt: [SystemShortcut] { [SystemShortcut(keyCode: space, modifiers: option, enabled: true)] }

    /// Last session ⌥Space, nothing owned by macOS: the plan relies on ⌥Space.
    private var relaunchOnOpt: ShortcutMenu.Plan {
        ShortcutMenu.plan(stored: nil, active: nil, lastSession: opt, choices: offers, system: [])
    }

    // Mutation: make `next` return nil once the planned key is in `failed`
    // (drop the fallthrough to the other free key) -> RED (a launcher holding
    // ⌥Space leaves dictation with no key while ⌃Space is free).
    func testTheOtherFreeKeyIsTriedWhenThePlannedOneFailsToRegister() {
        let plan = relaunchOnOpt
        XCTAssertEqual(ShortcutMenu.next(plan, failed: []), 1, "the planned key goes first")
        XCTAssertEqual(ShortcutMenu.next(plan, failed: [1]), 0, "⌥Space failed: the free ⌃Space is next")
        XCTAssertNil(ShortcutMenu.next(plan, failed: [1, 0]), "both failed: nothing left to try")
    }

    // Mutation: drop the `isEnabled` test in `next` -> RED (a macOS-owned key
    // would be registered against the system shortcut).
    func testAMacOSOwnedKeyIsNeverTheFallback() {
        let plan = ShortcutMenu.plan(stored: nil, active: nil, lastSession: opt, choices: offers, system: macOwnsCtrl)
        XCTAssertEqual(ShortcutMenu.next(plan, failed: []), 1)
        XCTAssertNil(ShortcutMenu.next(plan, failed: [1]), "⌃Space belongs to macOS: it is not a fallback")
    }

    func testAStoredPickGoesFirstAndStillFallsBack() {
        let plan = ShortcutMenu.plan(stored: ctrl, active: opt, choices: offers, system: [])
        XCTAssertEqual(ShortcutMenu.next(plan, failed: []), 0)
        XCTAssertEqual(ShortcutMenu.next(plan, failed: [0]), 1, "the pick failed to register: the other key still works")
    }

    func testNothingIsTriedWhenEveryKeyIsAMacOSShortcut() {
        let plan = ShortcutMenu.plan(stored: nil, active: nil, choices: offers, system: macOwnsCtrl + macOwnsOpt)
        XCTAssertNil(plan.key)
        XCTAssertNil(ShortcutMenu.next(plan, failed: []))
    }

    // MARK: notices

    private func notices(_ plan: ShortcutMenu.Plan, registered: Int?, failed: [Int]) -> [ShortcutMenu.Notice] {
        ShortcutMenu.registrationNotices(plan: plan, choices: offers, registered: registered, failed: failed)
    }

    func testAFallbackNamesTheKeyDictationIsOnNow() {
        XCTAssertEqual(notices(relaunchOnOpt, registered: 0, failed: [1]),
                       [.fellBack(failed: "⌥Space", now: "⌃Space")])
    }

    func testASuccessfulPlannedKeyIsSilent() {
        XCTAssertEqual(notices(relaunchOnOpt, registered: 1, failed: []), [])
    }

    func testOneKeyTakenWithNoFallbackSaysPickAnother() {
        let plan = ShortcutMenu.plan(stored: nil, active: nil, lastSession: opt, choices: offers, system: macOwnsCtrl)
        XCTAssertEqual(notices(plan, registered: nil, failed: [1]), [.taken("⌥Space")])
    }

    func testEveryKeyTakenSaysSoInsteadOfPickAnother() {
        XCTAssertEqual(notices(relaunchOnOpt, registered: nil, failed: [1, 0]),
                       [.allTaken("⌥Space, ⌃Space")])
    }

    // Mutation: return `[]` early when `registered` is nil, before the macOS
    // part (the old `guard hotKey != nil` shape) -> RED.
    func testTheMacOSNoticeSurvivesAFailedFallbackAndComesFirst() {
        // Stored ⌃Space is now a macOS shortcut; ⌥Space was planned and is taken.
        let plan = ShortcutMenu.plan(stored: ctrl, active: nil, choices: offers, system: macOwnsCtrl)
        XCTAssertEqual(plan.movedFrom, 0)
        XCTAssertEqual(notices(plan, registered: nil, failed: [1]),
                       [.macOSOwns(taken: "⌃Space"), .taken("⌥Space")])
    }

    func testAMacOSMoveThatRegistersSaysWhereDictationWentAndNothingElse() {
        let plan = ShortcutMenu.plan(stored: ctrl, active: nil, choices: offers, system: macOwnsCtrl)
        XCTAssertEqual(notices(plan, registered: 1, failed: []),
                       [.movedByMacOS(taken: "⌃Space", now: "⌥Space")])
    }

    func testOnlyTheMacOSPartsAreFlaggedForTheOncePerKeyGate() {
        XCTAssertTrue(ShortcutMenu.Notice.movedByMacOS(taken: "a", now: "b").isAboutMacOS)
        XCTAssertTrue(ShortcutMenu.Notice.macOSOwns(taken: "a").isAboutMacOS)
        XCTAssertFalse(ShortcutMenu.Notice.fellBack(failed: "a", now: "b").isAboutMacOS)
        XCTAssertFalse(ShortcutMenu.Notice.taken("a").isAboutMacOS)
        XCTAssertFalse(ShortcutMenu.Notice.allTaken("a").isAboutMacOS)
    }

    // MARK: ShortcutRegistration.run (loop + gates, with fakes)

    final class FakeStore: ShortcutStore {
        var values: [String: String] = [:]
        func string(forKey key: String) -> String? { values[key] }
        func setString(_ value: String?, forKey key: String) { values[key] = value }
    }

    /// Runs one registration where `works` are the indexes another app does not hold.
    final class FakeKey {}

    private func run(_ plan: ShortcutMenu.Plan, works: Set<Int>, previous: Int? = nil,
                     gates: inout RegistrationGates, store: FakeStore,
                     attempts: inout [Int]) -> ShortcutRegistration.Outcome<FakeKey> {
        var tried: [Int] = []
        let outcome = ShortcutRegistration.run(plan: plan, choices: offers, previous: previous,
                                               attempt: { tried.append($0); return works.contains($0) ? FakeKey() : nil },
                                               gates: &gates, store: store)
        attempts = tried
        return outcome
    }

    private func run(_ plan: ShortcutMenu.Plan, works: Set<Int>, previous: Int? = nil,
                     gates: inout RegistrationGates, store: FakeStore) -> ShortcutRegistration.Outcome<FakeKey> {
        var attempts: [Int] = []
        return run(plan, works: works, previous: previous, gates: &gates, store: store, attempts: &attempts)
    }

    // Mutation: ShortcutRegistration.run `while let index = next(...)` -> `if let` -> RED.
    func testTheLoopTriesTheSecondKeyAfterTheFirstIsRefused() {
        var gates = RegistrationGates(), attempts: [Int] = []
        let out = run(relaunchOnOpt, works: [0], gates: &gates, store: FakeStore(), attempts: &attempts)
        XCTAssertEqual(attempts, [1, 0])
        XCTAssertEqual(out.registered, 0)
        XCTAssertEqual(out.failed, [1])
        XCTAssertEqual(out.notices, [.fellBack(failed: "⌥Space", now: "⌃Space")])
    }

    // Mutation: `keyInUse: nil`, or the winner replaced by another attempt's
    // handle / dropped (`hotKey: nil`) -> RED.
    func testTheOutcomeCarriesTheWinningRegistrationAndTheKeyToRemember() {
        var gates = RegistrationGates()
        var made: [FakeKey] = []
        weak var refused: FakeKey?
        let out = ShortcutRegistration.run(plan: relaunchOnOpt, choices: offers, previous: nil, attempt: { (index: Int) -> FakeKey? in
            let key = FakeKey(); made.append(key)
            if index == 1 { refused = key; made.removeAll(); return nil }
            return key
        }, gates: &gates, store: FakeStore())
        XCTAssertEqual(out.registered, 0)
        XCTAssertTrue(out.hotKey === made.first, "the outcome must hand back the registration that took")
        XCTAssertNil(refused, "a refused attempt's registration must not be retained")
        XCTAssertEqual(out.keyInUse, "⌃Space")
        XCTAssertEqual(ShortcutMenu.Choice(title: "x", keyCode: 1, modifiers: 2, id: "controlSpace").id, "controlSpace")
        let none = run(relaunchOnOpt, works: [], gates: &gates, store: FakeStore())
        XCTAssertNil(none.hotKey)
        XCTAssertNil(none.keyInUse, "nothing registered: the remembered key stays")
    }

    // Mutation: the refusal filter `return !refusedBefore` -> `return true` -> RED
    // (notice and beep on every menu open while the conflict lasts).
    func testARefusalIsSaidOncePerKeyAcrossMenuOpens() {
        var gates = RegistrationGates(); let store = FakeStore()
        XCTAssertEqual(run(relaunchOnOpt, works: [0], gates: &gates, store: store).notices.count, 1)
        XCTAssertEqual(run(relaunchOnOpt, works: [0], previous: 0, gates: &gates, store: store).notices, [],
                       "the same refusal repeated on a second menu open")
    }

    // Mutation: drop the store reset when macOS moved nothing -> RED.
    func testAMacOSMoveIsToldOncePerTakenKeyAndToldAgainAfterItWasFreed() {
        let moved = ShortcutMenu.plan(stored: ctrl, active: nil, choices: offers, system: macOwnsCtrl)
        let freed = ShortcutMenu.plan(stored: ctrl, active: nil, choices: offers, system: [])
        var gates = RegistrationGates(); let store = FakeStore()
        XCTAssertEqual(run(moved, works: [1], gates: &gates, store: store).notices,
                       [.movedByMacOS(taken: "⌃Space", now: "⌥Space")])
        XCTAssertEqual(run(moved, works: [1], previous: 1, gates: &gates, store: store).notices, [], "told twice")
        XCTAssertEqual(run(freed, works: [0], previous: 1, gates: &gates, store: store).notices, [])
        XCTAssertEqual(run(moved, works: [1], previous: 0, gates: &gates, store: store).notices,
                       [.movedByMacOS(taken: "⌃Space", now: "⌥Space")], "macOS took it again and nobody was told")
    }

    // Mutation: key the refusal gate on the planned key alone -> RED.
    func testAnAllTakenAfterAFallbackIsNotSwallowedByTheEarlierFallbackNotice() {
        var gates = RegistrationGates(); let store = FakeStore()
        _ = run(relaunchOnOpt, works: [0], gates: &gates, store: store)
        let out = run(relaunchOnOpt, works: [], previous: 0, gates: &gates, store: store)
        XCTAssertNil(out.registered)
        XCTAssertEqual(out.notices, [.allTaken("⌥Space, ⌃Space")], "the user is not told dictation has no key")
    }

    // Mutation: `clearsStatusLine` true on every success -> RED.
    func testOnlyAChangedKeyClearsTheStatusLine() {
        var gates = RegistrationGates(); let store = FakeStore()
        XCTAssertTrue(run(relaunchOnOpt, works: [1], previous: nil, gates: &gates, store: store).clearsStatusLine)
        XCTAssertFalse(run(relaunchOnOpt, works: [1], previous: 1, gates: &gates, store: store).clearsStatusLine,
                       "an idle menu open must not wipe an unrelated status line")
        XCTAssertTrue(run(relaunchOnOpt, works: [0], previous: 1, gates: &gates, store: store).clearsStatusLine)
        XCTAssertFalse(run(relaunchOnOpt, works: [], previous: nil, gates: &gates, store: store).clearsStatusLine)
    }

    // Mutation: build `items` from plan.items unchanged -> RED.
    func testTheMenuTicksTheKeyDictationIsOnNotThePlannedOne() {
        var gates = RegistrationGates()
        let out = run(relaunchOnOpt, works: [0], gates: &gates, store: FakeStore())
        XCTAssertEqual(out.items.map(\.isOn), [true, false])
        let none = run(relaunchOnOpt, works: [], gates: &gates, store: FakeStore())
        XCTAssertEqual(none.items.map(\.isOn), [false, false])
    }

    func testEveryKeyBeingAMacOSShortcutIsALocalizedNotice() {
        let plan = ShortcutMenu.plan(stored: nil, active: nil, choices: offers, system: macOwnsCtrl + macOwnsOpt)
        var gates = RegistrationGates(); var attempts: [Int] = []
        let out = run(plan, works: [0, 1], gates: &gates, store: FakeStore(), attempts: &attempts)
        XCTAssertEqual(attempts, [])
        XCTAssertEqual(out.notices, [.allMacOS])
        withLocale("en") { XCTAssertTrue(ShortcutMenu.Notice.allMacOS.text.hasPrefix("Every dictation key is a macOS shortcut")) }
        withLocale("ru") { XCTAssertTrue(ShortcutMenu.Notice.allMacOS.text.range(of: "[А-Яа-я]", options: .regularExpression) != nil) }
    }

    // The only way a lone refusal happens is that the other key is a macOS
    // shortcut: "pick another one" would send the user to a greyed-out row.
    func testALoneRefusalDoesNotTellTheUserToPickAnotherKey() {
        for (code, banned) in [("en", "Pick another"), ("ru", "Выберите другую")] {
            withLocale(code) {
                XCTAssertFalse(ShortcutMenu.Notice.taken("⌥Space").text.contains(banned))
            }
        }
        let plan = ShortcutMenu.plan(stored: nil, active: nil, lastSession: opt, choices: offers, system: macOwnsCtrl)
        var gates = RegistrationGates()
        let out = run(plan, works: [], gates: &gates, store: FakeStore())
        XCTAssertEqual(out.notices, [.taken("⌥Space")])
    }

    // MARK: wording (en + ru)

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

    func testTheSentenceJoinsBothMessagesMacOSFirstInEnglish() {
        withLocale("en") {
            XCTAssertEqual(
                ShortcutMenu.sentence([.macOSOwns(taken: "⌃Space"), .taken("⌥Space")]),
                "⌃Space is a macOS shortcut on this Mac. ⌥Space is taken by another app and the other dictation key is a macOS shortcut, so dictation has no hotkey. Quit the app that holds it, then open this menu again.")
            XCTAssertEqual(ShortcutMenu.sentence([.fellBack(failed: "⌥Space", now: "⌃Space")]),
                           "⌥Space is taken by another app, so dictation uses ⌃Space.")
            XCTAssertEqual(ShortcutMenu.sentence([.movedByMacOS(taken: "⌃Space", now: "⌥Space")]),
                           "⌃Space is a macOS shortcut on this Mac, so dictation uses ⌥Space.")
        }
    }

    func testEveryHotkeyNoticeReadsInRussianWithItsArguments() {
        withLocale("ru") {
            let all: [ShortcutMenu.Notice] = [
                .movedByMacOS(taken: "⌃Space", now: "⌥Space"), .macOSOwns(taken: "⌃Space"),
                .fellBack(failed: "⌥Space", now: "⌃Space"), .taken("⌥Space"), .allTaken("⌥Space, ⌃Space"), .allMacOS,
            ]
            for notice in all {
                let text = notice.text
                XCTAssertTrue(text.range(of: "[А-Яа-я]", options: .regularExpression) != nil,
                              "\(notice) has no Russian text: \(text)")
                XCTAssertFalse(text.contains("%"), "\(notice) left a placeholder unfilled: \(text)")
                if notice != .allMacOS { XCTAssertTrue(text.contains("Space"), "\(notice) lost its key name: \(text)") }
            }
        }
    }

    // MARK: the late clipboard notice (#62)

    // Mutation: give `lateClipboard` kind `.outcome` -> RED.
    func testALateClipboardNoticeDoesNotTakeTheNextDictationsEndedReason() {
        let late = NoticeGate.Notice.lateClipboard("The clipboard stays as the dictation")
        XCTAssertEqual(late.kind, .unrelated)
        let merged = DictationNotice.merge(endedReason: "Recording stopped at the length cap.",
                                           into: late.message, kind: late.kind)
        XCTAssertEqual(merged.message, "The clipboard stays as the dictation")
        XCTAssertEqual(merged.endedReason, "Recording stopped at the length cap.", "the reason stays for its own dictation")
    }

    // MARK: AppKit glue pins (no OxSayDictation test target can reach it)

    private static func source(_ file: String) -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/\(file)")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    private static func body(_ signature: String, in file: String) -> String {
        let text = source(file)
        guard let start = text.range(of: signature),
              let end = text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex) else { return "" }
        return String(text[start.upperBound..<end.lowerBound])
    }

    // The remaining glue lines cannot move into Core; each is pinned exactly.
    // Mutation: delete `hotKey = outcome.hotKey` (nothing listens), delete
    // `active = ...` (the menu forgets the key), register `plan.key!` instead
    // of the outcome's, or drop the keyInUse write -> RED.
    func testRegisterShortcutAppliesTheCoreOutcome() {
        let register = Self.body("private func registerShortcut(_ plan: ShortcutMenu.Plan) {", in: "AppDelegate.swift")
        XCTAssertFalse(register.isEmpty, "registerShortcut not found")
        for line in [
            "ShortcutRegistration.run(",
            "        hotKey = outcome.hotKey\n",
            "        active = outcome.registered.map { Shortcut.allCases[$0] }\n",
            "        if let inUse = outcome.keyInUse { UserDefaults.standard.set(inUse, forKey: keyInUseKey) }\n",
            "        if outcome.clearsStatusLine { lastNotice = nil }\n",
            "        applyShortcutItems(outcome.items)\n",
            "        if !outcome.notices.isEmpty { notice(ShortcutMenu.sentence(outcome.notices)) }",
        ] {
            XCTAssertTrue(register.contains(line), "registerShortcut lost: \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        XCTAssertFalse(register.contains("plan.key!"), "the glue registers the plan's key, not the outcome's")
    }

    // Mutation: tag the late notice `.outcome` again, or wire `onNotice` to
    // PasteOutput.settle again -> RED.
    func testTheLateClipboardNoticeHasItsOwnWiring() {
        let app = Self.source("AppDelegate.swift")
        XCTAssertTrue(app.contains("output.onLateNotice = { [weak self] message in self?.notice(.lateClipboard(message)) }"),
                      "the late clipboard notice is not raised as .lateClipboard")
        XCTAssertTrue(app.contains("output.onNotice = { [weak self] message in self?.notice(message, kind: .outcome) }"),
                      "the delivery-time notice must stay an outcome of its own dictation")
        let settle = Self.body("func settle() {", in: "PasteOutput.swift")
        XCTAssertTrue(settle.contains("onNotice: onLateNotice"), "settle() reports through the delivery-time callback")
    }
}
