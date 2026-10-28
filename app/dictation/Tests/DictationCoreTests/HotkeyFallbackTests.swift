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
                "⌃Space is a macOS shortcut on this Mac. ⌥Space is taken by another app, so dictation has no hotkey. Pick another one in this menu.")
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
                .fellBack(failed: "⌥Space", now: "⌃Space"), .taken("⌥Space"), .allTaken("⌥Space, ⌃Space"),
            ]
            for notice in all {
                let text = notice.text
                XCTAssertTrue(text.range(of: "[А-Яа-я]", options: .regularExpression) != nil,
                              "\(notice) has no Russian text: \(text)")
                XCTAssertFalse(text.contains("%"), "\(notice) left a placeholder unfilled: \(text)")
                XCTAssertTrue(text.contains("Space"), "\(notice) lost its key name: \(text)")
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

    // Mutation: in registerShortcut, build the HotKey from `plan.key` once
    // instead of looping over `ShortcutMenu.next` -> RED (the second key is
    // never tried).
    func testRegisterShortcutWalksThePlansKeysAndReportsFromTheCoreDecision() {
        let register = Self.body("private func registerShortcut(_ plan: ShortcutMenu.Plan) {", in: "AppDelegate.swift")
        XCTAssertFalse(register.isEmpty, "registerShortcut not found")
        XCTAssertTrue(register.contains("ShortcutMenu.next(plan, failed:"), "registerShortcut ignores the plan's other keys")
        XCTAssertTrue(register.contains("ShortcutMenu.registrationNotices("), "the notices are not the Core decision")
        XCTAssertFalse(register.contains("guard hotKey != nil"), "the failure return is back, before the macOS notice")
    }

    // Mutation: delete `lastNotice = nil` from registerShortcut -> RED (a stale
    // status line survives the recovery).
    func testARegistrationThatSucceedsClearsTheStaleStatusLine() {
        let register = Self.body("private func registerShortcut(_ plan: ShortcutMenu.Plan) {", in: "AppDelegate.swift")
        XCTAssertTrue(register.contains("lastNotice = nil"), "registerShortcut leaves the stale status line")
        guard let cleared = register.range(of: "lastNotice = nil"),
              let said = register.range(of: "notice(ShortcutMenu.sentence(") else {
            return XCTFail("registerShortcut lost the clear or the sentence")
        }
        XCTAssertLessThan(cleared.lowerBound, said.lowerBound,
                          "the clear must come before the notice, or it erases the sentence it just raised")
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
