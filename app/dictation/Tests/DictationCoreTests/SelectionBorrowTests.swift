import XCTest
@testable import DictationCore

/// The speak-selection capture over fake seams: AX is asked first and the
/// clipboard is borrowed only when the policy allows. A fake ⌘C is the app's
/// copy landing — `board.userCopies` is what the frontmost app would write.
final class SelectionBorrowTests: XCTestCase {
    /// A successful AX read of a focused element.
    private func ax(_ text: String?, secureField: Bool = false, error: Int32 = 0,
                    source: AXSelection.Source = .systemWide) -> AXSelection {
        AXSelection(text: text, secureField: secureField, hasElement: true, error: error, source: source)
    }

    /// AX could not read the focused element at all (no element, an error code).
    private func noElement() -> AXSelection {
        AXSelection(text: nil, secureField: false, hasElement: false, error: -25212, source: .app)
    }

    private func remoteBoard() -> FakePasteboard {
        let board = FakePasteboard(text: "copied on the iPhone")
        board.items[0].append((type: "public.rtf", data: Data("rtf".utf8)))
        board.items[0].append((type: PasteboardMarker.remoteClipboard, data: Data()))
        return board
    }

    // AX hands over the selection: nothing is copied, and the clipboard is not
    // touched at all — the whole point for a Universal Clipboard copy, which a
    // mere snapshot read already cannot restore but must not provoke either.
    // Mutation: SelectionBorrow.capture, always send ⌘C (drop the AX-first
    // plan) -> RED (postCopy fires, the clipboard is written and restored).
    func testAXTextIsSpokenWithoutTouchingTheClipboard() {
        let board = FakePasteboard(text: "the user's copy")
        var copies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { ax("the selection") },
                                                    secureInput: { false },
                                                    postCopy: { copies += 1 },
                                                    spin: { _ in },
                                                    readText: { board.text }, memory: SlowClipboardMemory())
        XCTAssertEqual(text, "the selection")
        XCTAssertNil(problem)
        XCTAssertEqual(copies, 0, "AX handed the selection over: ⌘C must never be sent")
        XCTAssertEqual(board.changeCount, 0, "the clipboard is not written at all")
        XCTAssertEqual(board.reads, [], "the clipboard is not even read")
    }

    // AX gave nothing: the clipboard is borrowed, ⌘C reads the selection, and
    // the user's own copy goes back.
    // Mutation: SelectionBorrow.capture, delete the `.copy` branch (decline
    // instead of borrowing) -> RED.
    func testAnEmptyAXFallsBackToTheClipboardBorrow() {
        let board = FakePasteboard(text: "the user's copy")
        var copies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { ax(nil) },
                                                    secureInput: { false },
                                                    postCopy: { copies += 1; board.userCopies("the selection") },
                                                    spin: { _ in },
                                                    readText: { board.text }, memory: SlowClipboardMemory())
        XCTAssertEqual(text, "the selection")
        XCTAssertNil(problem)
        XCTAssertEqual(copies, 1)
        XCTAssertEqual(board.text, "the user's copy", "the borrow puts the user's copy back")
    }

    // #220: AX gave nothing and the clipboard is an iPhone copy. ⌘C would
    // replace it for good (a remote copy cannot be restored), so the press is
    // declined with the localized notice and the clipboard is not touched.
    // Mutation: SelectionBorrow.run, `clipboardRemote: snapshot?.isRemote ?? false`
    // -> `clipboardRemote: false` -> RED (⌘C is sent over the iPhone copy).
    func testARemoteClipboardWithNoAXSelectionIsDeclinedWithoutTheCopy() {
        let board = remoteBoard()
        var copies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { noElement() },
                                                    secureInput: { false },
                                                    postCopy: { copies += 1; board.userCopies("the selection") },
                                                    spin: { _ in },
                                                    readText: { board.text }, memory: SlowClipboardMemory())
        XCTAssertNil(text)
        XCTAssertEqual(problem, L10nKey.noticeSelectionRemote.text)
        XCTAssertEqual(copies, 0, "⌘C over an iPhone copy replaces it for good")
        XCTAssertEqual(board.changeCount, 0, "the clipboard is not written")
        XCTAssertEqual(board.reads, [], "the remote copy's data is never read")
        XCTAssertEqual(board.text, "copied on the iPhone")
        XCTAssertTrue(board.declaredItems.joined().contains(PasteboardMarker.remoteClipboard))
    }

    // AX worked: it found the focused element and it has no selection (Safari or Notes with nothing selected). The iPhone
    // copy is still left alone, but the sentence must not claim the selection "can't be read in this app".
    // Mutation: SelectionBorrow.run, `axAnswered: ax.hasElement && ax.error == 0` -> `axAnswered: false` -> RED.
    func testARemoteClipboardWhereAXAnsweredSaysNothingIsSelected() {
        let board = remoteBoard()
        var copies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { ax(nil) },
                                                    secureInput: { false },
                                                    postCopy: { copies += 1; board.userCopies("the selection") },
                                                    spin: { _ in },
                                                    readText: { board.text }, memory: SlowClipboardMemory())
        XCTAssertNil(text)
        XCTAssertEqual(problem, L10nKey.noticeSelectionRemoteEmpty.text)
        XCTAssertEqual(copies, 0)
        XCTAssertEqual(board.reads, [])
        // An element that came back with an AX error is not an answer.
        let (_, failed) = SelectionBorrow.capture(board: remoteBoard(),
                                                  selectedText: { AXSelection(text: nil, hasElement: true, error: -25204, source: .app) },
                                                  secureInput: { false }, postCopy: {}, spin: { _ in }, readText: { nil }, memory: SlowClipboardMemory())
        XCTAssertEqual(failed, L10nKey.noticeSelectionRemote.text)
    }

    // Every decline is a localized key, never an English literal, and they are all different.
    // Mutation: SelectionPolicy.plan, `.decline(L10nKey.noticeSelectionNothing.text)` -> `.decline("Nothing selected to speak.")` -> RED.
    func testTheDeclinesAreLocalizedAndDistinct() {
        let keys: [L10nKey] = [.noticeSelectionRemote, .noticeSelectionRemoteEmpty, .noticeSelectionPassword,
                               .noticeSelectionNothing, .noticeSelectionFailed]
        XCTAssertEqual(Set(keys.map(\.text)).count, keys.count)
        func plan(_ ax: String?, secure: Bool = false, restorable: Bool = true, remote: Bool = false) -> SelectionPlan {
            SelectionPolicy.plan(axText: ax, secureInput: secure, clipboardRestorable: restorable, clipboardRemote: remote)
        }
        XCTAssertEqual(plan(nil, secure: true), .decline(L10nKey.noticeSelectionPassword.text))
        XCTAssertEqual(plan("  "), .decline(L10nKey.noticeSelectionNothing.text))
        XCTAssertEqual(plan(nil, restorable: false), .decline(L10nKey.noticeSelectionFailed.text))
    }

    // The two copy-path declines of the driver itself.
    // Mutation: SelectionBorrow.run, the final `(nil, L10nKey.noticeSelectionNothing.text)` -> `(nil, "Nothing selected to speak.")` -> RED.
    func testACopyThatBringsNothingSaysNothingIsSelectedInTheUsersLanguage() {
        let board = FakePasteboard(text: "the user's copy")
        let (text, problem) = SelectionBorrow.capture(board: board, selectedText: { ax(nil) }, secureInput: { false },
                                                      postCopy: {}, spin: { _ in }, readText: { board.text }, memory: SlowClipboardMemory(), copyTimeout: 0)
        XCTAssertNil(text)
        XCTAssertEqual(problem, L10nKey.noticeSelectionNothing.text)
    }

    // AX text wins over a remote clipboard: nothing declined, nothing touched.
    func testAXTextOverARemoteClipboardIsSpokenUntouched() {
        let board = remoteBoard()
        var copies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { ax("the selection") },
                                                    secureInput: { false },
                                                    postCopy: { copies += 1 },
                                                    spin: { _ in },
                                                    readText: { board.text }, memory: SlowClipboardMemory())
        XCTAssertEqual(text, "the selection")
        XCTAssertNil(problem)
        XCTAssertEqual(copies, 0)
        XCTAssertEqual(board.changeCount, 0)
        XCTAssertEqual(board.reads, [])
    }

    // A secure field gets neither AX nor ⌘C — the decline comes before any
    // clipboard contact.
    func testASecureFieldDeclinesWithoutTouchingTheClipboard() {
        let board = FakePasteboard(text: "the user's copy")
        var copies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { ax(nil) },
                                                    secureInput: { true },
                                                    postCopy: { copies += 1 },
                                                    spin: { _ in },
                                                    readText: { board.text }, memory: SlowClipboardMemory())
        XCTAssertNil(text)
        XCTAssertEqual(problem, L10nKey.noticeSelectionPassword.text)
        XCTAssertEqual(copies, 0)
        XCTAssertEqual(board.changeCount, 0)
        XCTAssertEqual(board.reads, [])
    }

    // A focused AXSecureTextField is refused whole: the text AX would hand over
    // is not spoken, and ⌘C is not sent — same outcome as secure event input.
    // Mutation: SelectionBorrow.run, `let axText = ax.secureField ? nil : ax.text`
    // -> `let axText = ax.text` -> RED (the password is spoken).
    func testASecureFieldSubroleIsNotSpoken() {
        let board = FakePasteboard(text: "the user's copy")
        var copies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { ax("hunter2", secureField: true) },
                                                    secureInput: { false },
                                                    postCopy: { copies += 1; board.userCopies("hunter2") },
                                                    spin: { _ in },
                                                    readText: { board.text }, memory: SlowClipboardMemory())
        XCTAssertNil(text, "a secure field's text must never be returned")
        XCTAssertEqual(problem, L10nKey.noticeSelectionPassword.text)
        XCTAssertEqual(copies, 0)
        XCTAssertEqual(board.changeCount, 0)
        XCTAssertEqual(board.reads, [])
    }

    // Mutation: SelectionBorrow.run, `let secure = secureInput() || ax.secureField`
    // -> `let secure = secureInput()` -> RED (no AX text, no secure-input flag:
    // the borrow proceeds and ⌘C goes to the password field).
    func testASecureFieldSubroleNeverSeesTheCopyFallback() {
        let board = FakePasteboard(text: "the user's copy")
        var copies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { ax(nil, secureField: true) },
                                                    secureInput: { false },
                                                    postCopy: { copies += 1; board.userCopies("hunter2") },
                                                    spin: { _ in },
                                                    readText: { board.text }, memory: SlowClipboardMemory())
        XCTAssertNil(text)
        XCTAssertEqual(problem, L10nKey.noticeSelectionPassword.text)
        XCTAssertEqual(copies, 0, "⌘C must not be sent to a secure field")
        XCTAssertEqual(board.changeCount, 0)
    }

    // AX answered with a whitespace-only selection: the app said what is
    // selected, ⌘C would copy the same blanks — decline, do not touch the
    // clipboard. An empty answer stays ambiguous and still falls back.
    // Mutation: SelectionPolicy.plan, delete the `isWhitespaceOnly` decline
    // -> RED (the borrow runs: postCopy fires).
    func testAWhitespaceOnlySelectionDeclinesWithoutTheCopy() {
        let board = FakePasteboard(text: "the user's copy")
        var copies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { ax("  \n ") },
                                                    secureInput: { false },
                                                    postCopy: { copies += 1; board.userCopies("x") },
                                                    spin: { _ in },
                                                    readText: { board.text }, memory: SlowClipboardMemory())
        XCTAssertNil(text)
        XCTAssertEqual(problem, L10nKey.noticeSelectionNothing.text)
        XCTAssertEqual(copies, 0)
        XCTAssertEqual(board.changeCount, 0)
        XCTAssertEqual(board.reads, [])
    }

    // The log line: one report per press, path plus every source's result.
    // Mutation: SelectionBorrow.capture, `onSelection?(...)` deleted -> RED;
    // `path: path` -> `path: .ax` -> RED in the copy/none cases;
    // `attempts: ax.attempts` -> `[ax.attempt]` -> RED in the two-source case.
    func testEachPressReportsThePathAndEverySourcesResult() {
        func press(_ read: AXSelection, copy: String? = nil, remote: Bool = false) -> String? {
            let board = remote ? remoteBoard() : FakePasteboard(text: "the user's copy")
            var reports: [SelectionReport] = []
            _ = SelectionBorrow.capture(board: board,
                                        selectedText: { read },
                                        secureInput: { false },
                                        postCopy: { if let copy { board.userCopies(copy) } },
                                        spin: { _ in },
                                        readText: { board.text },
                                        memory: SlowClipboardMemory(),
                                        onSelection: { reports.append($0) })
            XCTAssertEqual(reports.count, 1, "exactly one report per press")
            return reports.first?.line
        }
        XCTAssertEqual(press(ax("hello")), "selection path=ax ax=systemwide:0")
        XCTAssertEqual(press(ax("hello", source: .app)), "selection path=ax ax=app:0")
        XCTAssertEqual(press(ax(nil, error: -25212, source: .app), copy: "copied"),
                       "selection path=copy ax=app:-25212")
        XCTAssertEqual(press(ax(nil, error: -25205)), "selection path=none ax=systemwide:-25205",
                       "AX gave nothing and ⌘C copied nothing")
        XCTAssertEqual(press(ax("pw", secureField: true)), "selection path=none ax=systemwide:secure",
                       "a refused secure field is not an ax read: no success code")
        XCTAssertEqual(press(ax(nil), remote: true), "selection path=remote ax=systemwide:0",
                       "declined over an iPhone copy")
        let both = AXSelection.read(
            systemWide: { AXSelection(hasElement: false, error: -25204, source: .systemWide) },
            app: { AXSelection(hasElement: false, error: -25212, source: .app) })
        XCTAssertEqual(press(both), "selection path=none ax=systemwide:-25204,app:-25212",
                       "both sources' results are logged, not only the last")
    }

    // The source choice: the system-wide element first; the frontmost app's
    // when the first yields no focused element OR no text (Chromium answers
    // the system-wide query with an element that has no AXSelectedText).
    // Mutation: AXSelection.read, `first.hasElement ? first : app()` ->
    // `app()` -> RED; `-> first` -> RED (the fallback never runs).
    func testTheSystemWideElementWinsAndTheAppIsTheFallback() {
        var appAsked = 0
        let wide = AXSelection(text: "wide", hasElement: true, error: 0, source: .systemWide)
        let fromApp = AXSelection(text: "app", hasElement: true, error: 0, source: .app)
        let got = AXSelection.read(systemWide: { wide }, app: { appAsked += 1; return fromApp })
        XCTAssertEqual(got, wide)
        XCTAssertEqual(appAsked, 0, "the app element is not queried when the system-wide one has text")

        let refused = AXSelection(hasElement: false, error: -25204, source: .systemWide)
        let viaApp = AXSelection.read(systemWide: { refused }, app: { appAsked += 1; return fromApp })
        XCTAssertEqual(viaApp.text, "app")
        XCTAssertEqual(viaApp.source, .app)
        XCTAssertEqual(appAsked, 1)

        let noneEither = AXSelection(hasElement: false, error: -25212, source: .app)
        XCTAssertEqual(AXSelection.read(systemWide: { refused }, app: { noneEither }).source, .app,
                       "both failed with no element: the app source is the one reported")
    }

    // #222: the system-wide read returns an element that has no text. The app
    // source is asked next, and its text wins.
    // Mutation: AXSelection.read, `first.hasElement && hasText(first)` ->
    // `first.hasElement` -> RED (the app source is never asked).
    func testAnElementWithoutTextSendsTheReadToTheAppSource() {
        let bare = AXSelection(text: nil, hasElement: true, error: -25212, source: .systemWide)
        let fromApp = AXSelection(text: "chromium text", hasElement: true, error: 0, source: .app)
        let got = AXSelection.read(systemWide: { bare }, app: { fromApp })
        XCTAssertEqual(got.text, "chromium text")
        XCTAssertEqual(got.source, .app)
        XCTAssertEqual(got.attempts.map(\.source), [.systemWide, .app])
        XCTAssertEqual(got.attempts.map(\.error), [-25212, 0])
        let empty = AXSelection(text: "", hasElement: true, error: 0, source: .systemWide)
        XCTAssertEqual(AXSelection.read(systemWide: { empty }, app: { fromApp }).text, "chromium text",
                       "an empty selection string is no text either")
    }

    // Neither source has text: the system-wide element (which exists) is the
    // answer, and the report keeps both results.
    func testNoTextAnywhereKeepsTheFirstElementAndBothResults() {
        let bare = AXSelection(text: nil, hasElement: true, error: -25212, source: .systemWide)
        let appBare = AXSelection(text: nil, hasElement: true, error: -25205, source: .app)
        let got = AXSelection.read(systemWide: { bare }, app: { appBare })
        XCTAssertEqual(got.source, .systemWide)
        XCTAssertEqual(got.attempts.map(\.error), [-25212, -25205])
    }

    // A secure field found by either source is refused whole: the app source
    // is not asked after a secure system-wide element, and a secure app element
    // wins over a bare system-wide one.
    // Mutation: AXSelection.read, delete the `first.secureField` early return
    // or the `second.secureField` pick -> RED.
    func testASecureElementFromEitherSourceStaysSecure() {
        var appAsked = 0
        let secureWide = AXSelection(text: nil, secureField: true, hasElement: true, error: 0, source: .systemWide)
        let appText = AXSelection(text: "visible", hasElement: true, error: 0, source: .app)
        let got = AXSelection.read(systemWide: { secureWide }, app: { appAsked += 1; return appText })
        XCTAssertTrue(got.secureField)
        XCTAssertEqual(appAsked, 0)

        let bare = AXSelection(text: nil, hasElement: true, error: -25212, source: .systemWide)
        let secureApp = AXSelection(text: nil, secureField: true, hasElement: true, error: 0, source: .app)
        XCTAssertTrue(AXSelection.read(systemWide: { bare }, app: { secureApp }).secureField)
    }

    // Wiring guard for the one log line per speak press: SelectionCapture must
    // pass the hook through, AppDelegate must set it and log the report line.
    // Mutation: SelectionCapture, delete `onSelection: onSelection` -> RED.
    func testTheAppWiresTheSelectionLine() {
        let capture = source("Sources/OxSayDictation/SelectionCapture.swift")
        XCTAssertTrue(capture.contains("onSelection: onSelection"),
                      "SelectionCapture drops the selection hook — the path taken is never logged")
        let appDelegate = source("Sources/OxSayDictation/AppDelegate.swift")
        XCTAssertTrue(appDelegate.contains("capture.onSelection = { report in timingLog.notice(\"\\(report.line, privacy: .public)\") }"),
                      "no log line is wired for the speak-selection path")
    }

    // The platform seams the tests above replace with fakes: the call site must
    // hand SelectionBorrow the real ones. A stub (`selectedText: { nil }`,
    // `secureInput: { false }`) leaves every behaviour test green and silently
    // turns AX off or ⌘C loose on password fields.
    // Mutations: SelectionCapture.capture, `selectedText: selectedText` ->
    // `selectedText: { AXSelection(hasElement: false, error: 0, source: .app) }`;
    // `secureInput: IsSecureEventInputEnabled` -> `secureInput: { false }`;
    // `postCopy: postCommandC` -> `postCopy: {}`; `readText: board.readText`
    // -> `readText: { nil }` -> each RED.
    func testTheCaptureHandsOverTheRealPlatformSeams() {
        let capture = source("Sources/OxSayDictation/SelectionCapture.swift")
        for seam in ["selectedText: selectedText",
                     "secureInput: IsSecureEventInputEnabled",
                     "postCopy: postCommandC",
                     "readText: board.readText"] {
            XCTAssertTrue(capture.contains(seam), "SelectionCapture no longer passes `\(seam)` — a stub stands in for the platform")
        }
    }

    // #222: the real AX read is platform code the fakes above never run. The
    // secure-subrole mapping and the two-source read must stay wired: a
    // mapping that never matches reads a password field's text; a read that
    // bypasses `AXSelection.read` loses the app-source fallback.
    // Mutations: SelectionCapture.read, `kAXSecureTextFieldSubrole` -> any
    // other subrole; `secureField: secure` -> `secureField: false`;
    // `AXSelection.read(` -> a direct `read(from: AXUIElementCreateSystemWide()...)`
    // -> each RED.
    func testTheCaptureMapsTheSecureSubroleAndReadsThroughBothSources() {
        let capture = source("Sources/OxSayDictation/SelectionCapture.swift")
        for pin in ["let secure = (subrole as? String) == (kAXSecureTextFieldSubrole as String)",
                    "secureField: secure,",
                    "kAXSubroleAttribute",
                    "AXSelection.read(",
                    "systemWide: { read(from: AXUIElementCreateSystemWide(), source: .systemWide) }",
                    "return read(from: AXUIElementCreateApplication(pid), source: .app)"] {
            XCTAssertTrue(capture.contains(pin), "SelectionCapture no longer contains `\(pin)`")
        }
    }

    // #220: the decline's text reaches the user. AppDelegate shows the
    // problem the capture returns on the pill; dropping it would make the
    // hotkey go silent over an iPhone copy.
    // Mutation: AppDelegate.speakSelection, `overlay.showMessage(problem ??
    // L10nKey.noticeSelectionNothing.text)` -> `overlay.showMessage("")` -> RED.
    func testTheDeclineReachesThePill() {
        let appDelegate = source("Sources/OxSayDictation/AppDelegate.swift")
        XCTAssertTrue(appDelegate.contains("overlay.showMessage(problem ?? L10nKey.noticeSelectionNothing.text)"),
                      "speakSelection no longer shows the capture's problem")
        let capture = source("Sources/OxSayDictation/SelectionCapture.swift")
        XCTAssertTrue(capture.contains("func capture() -> (text: String?, problem: String?) {\n        SelectionBorrow.capture("),
                      "SelectionCapture must return SelectionBorrow's result unchanged")
    }

    // #319.1: a copy whose read timed out is remembered by the speak-selection path too. With AX giving no text, the
    // first press waits the limit and declines; the next press on the SAME memory and an unchanged clipboard declines
    // at once: no `data` call, no ⌘C. Mutation: SelectionBorrow.run, `memory: memory` -> `memory: SlowClipboardMemory()`
    // at the PasteboardSnapshot.capture call -> RED (the second press reads the board again).
    func testASlowClipboardIsDeclinedAtOnceOnTheSecondSelectionRead() {
        let board = SlowPasteboard(text: "the user's big copy", delay: 1.5)
        let memory = SlowClipboardMemory()
        var copies = 0
        func press() -> (text: String?, problem: String?) {
            SelectionBorrow.capture(board: board, selectedText: { self.noElement() }, secureInput: { false },
                                    postCopy: { copies += 1 }, spin: { _ in }, readText: { nil }, memory: memory)
        }
        // Shrink the wait: the production limit is 2 s.
        let first = SelectionBorrow.capture(board: board, selectedText: { self.noElement() }, secureInput: { false },
                                            postCopy: { copies += 1 }, spin: { _ in }, readText: { nil },
                                            memory: memory, readLimit: 0.1)
        XCTAssertNil(first.text)
        XCTAssertEqual(board.reads, 1, "the first press reads once and gives up")
        let second = press()
        XCTAssertNil(second.text)
        XCTAssertEqual(second.problem, first.problem, "declined the way the timeout declines")
        XCTAssertEqual(board.reads, 1, "the second press must make no data call")
        XCTAssertEqual(copies, 0, "⌘C is never sent over a clipboard that could not be read")
        XCTAssertEqual(board.changeCount, 0, "no write")
    }

    // The memory is about one copy: a new copy moves the changeCount and is read again on the speak path as well.
    // Mutation: SlowClipboardMemory.isSlow, `timedOutCount == changeCount` -> `timedOutCount != nil` -> RED.
    func testANewCopyIsReadAgainOnTheSelectionPath() {
        let board = SlowPasteboard(text: "slow", delay: 0.4)
        let memory = SlowClipboardMemory()
        _ = SelectionBorrow.capture(board: board, selectedText: { self.noElement() }, secureInput: { false },
                                    postCopy: {}, spin: { _ in }, readText: { nil }, memory: memory, readLimit: 0.1)
        Thread.sleep(forTimeInterval: 0.6)   // the abandoned read ends
        let readsBefore = board.reads
        board.inner.userCopies("a fast copy")
        board.inner.items = [[("public.utf8-plain-text", Data("a fast copy".utf8))]]
        _ = SelectionBorrow.capture(board: board, selectedText: { self.noElement() }, secureInput: { false },
                                    postCopy: {}, spin: { _ in }, readText: { nil }, memory: memory, copyTimeout: 0)
        XCTAssertGreaterThan(board.reads, readsBefore, "a copy made after the slow one must be read")
    }

    // #319.1 glue: the paste and the speak-selection copy share the app's ONE memory. A SelectionCapture that built its
    // own, or an AppDelegate that gave each a fresh one, leaves every behaviour test green and the 2 s freeze in place.
    // Mutations: AppDelegate, `SelectionCapture(slowClipboard: slowClipboard)` -> `SelectionCapture(slowClipboard:
    // SlowClipboardMemory())`; SelectionCapture.capture, `memory: slowClipboard` -> `memory: SlowClipboardMemory()` -> RED.
    func testThePasteAndTheSelectionCopyShareOneSlowClipboardMemory() {
        let appDelegate = source("Sources/OxSayDictation/AppDelegate.swift")
        XCTAssertEqual(appDelegate.components(separatedBy: "SlowClipboardMemory()").count - 1, 1,
                       "AppDelegate must build exactly one SlowClipboardMemory")
        XCTAssertTrue(appDelegate.contains("PasteOutput(slowClipboard: slowClipboard)"))
        XCTAssertTrue(appDelegate.contains("SelectionCapture(slowClipboard: slowClipboard)"))
        let capture = source("Sources/OxSayDictation/SelectionCapture.swift")
        XCTAssertTrue(capture.contains("memory: slowClipboard,"), "SelectionCapture must hand SelectionBorrow the shared memory")
        XCTAssertFalse(capture.contains("SlowClipboardMemory()"), "SelectionCapture must not build its own memory")
        let paste = source("Sources/OxSayDictation/PasteOutput.swift")
        XCTAssertFalse(paste.contains("SlowClipboardMemory()"), "PasteOutput must not build its own memory")
        XCTAssertTrue(paste.contains("memory: slowClipboard"))
    }

    private func source(_ relative: String) -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DictationCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        let text = (try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)) ?? ""
        XCTAssertFalse(text.isEmpty, "\(relative) unreadable")
        return text
    }

    /// Mutation: Resources/ru.lproj, notice.selection_password back to "Выбрано поле для пароля." -> RED.
    func testTheRussianPasswordDeclineSaysWhereTheCursorIs() {
        XCTAssertEqual(ShippedStrings.table("ru")["notice.selection_password"], "Курсор в поле для пароля.")
    }
}
