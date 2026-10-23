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
                                                    readText: { board.text })
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
                                                    readText: { board.text })
        XCTAssertEqual(text, "the selection")
        XCTAssertNil(problem)
        XCTAssertEqual(copies, 1)
        XCTAssertEqual(board.text, "the user's copy", "the borrow puts the user's copy back")
    }

    // Anchored wiring: the remote flag the snapshot finds must reach the plan.
    // With `clipboardRemote: false` at the call site, an iPhone copy's snapshot
    // reads "unrestorable" and the borrow is declined — speak-selection stops
    // working after every iPhone copy, exactly #214's symptom.
    // Mutation: SelectionBorrow.capture, `clipboardRemote: snapshot?.isRemote
    // ?? false` -> `clipboardRemote: false` -> RED.
    func testTheRemoteFlagReachesThePlan() {
        let board = remoteBoard()
        var remoteCopies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { ax(nil) },
                                                    secureInput: { false },
                                                    postCopy: { board.userCopies("the selection") },
                                                    spin: { _ in },
                                                    readText: { board.text },
                                                    onRemoteCopy: { remoteCopies += 1 })
        XCTAssertEqual(text, "the selection", "⌘C over a remote copy still reads the selection")
        XCTAssertNil(problem)
        XCTAssertEqual(remoteCopies, 1, "a ⌘C landing over a remote copy is logged once")
        XCTAssertEqual(board.text, "the selection",
                       "a remote snapshot is never restored: the clipboard keeps the copy")
        XCTAssertEqual(board.reads, [], "the remote copy's data is never read")
    }

    // The other side of the same line: ⌘C lands nothing, so the remote copy
    // was never overwritten and nothing is logged.
    func testARemoteClipboardWithNoCopyComingNeedsNoLog() {
        let board = remoteBoard()
        var remoteCopies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { ax(nil) },
                                                    secureInput: { false },
                                                    postCopy: {},
                                                    spin: { _ in },
                                                    readText: { board.text },
                                                    onRemoteCopy: { remoteCopies += 1 })
        XCTAssertNil(text)
        XCTAssertEqual(problem, "Nothing selected to speak.")
        XCTAssertEqual(remoteCopies, 0, "the remote copy survived: there is nothing to log")
        XCTAssertTrue(board.declaredItems.joined().contains(PasteboardMarker.remoteClipboard),
                      "a selection-less ⌘C writes nothing: the iPhone copy is still there")
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
                                                    readText: { board.text })
        XCTAssertNil(text)
        XCTAssertEqual(problem, "A password field is focused.")
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
                                                    readText: { board.text })
        XCTAssertNil(text, "a secure field's text must never be returned")
        XCTAssertEqual(problem, "A password field is focused.")
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
                                                    readText: { board.text })
        XCTAssertNil(text)
        XCTAssertEqual(problem, "A password field is focused.")
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
                                                    readText: { board.text })
        XCTAssertNil(text)
        XCTAssertEqual(problem, "Nothing selected to speak.")
        XCTAssertEqual(copies, 0)
        XCTAssertEqual(board.changeCount, 0)
        XCTAssertEqual(board.reads, [])
    }

    // The log line: one report per press, path and AX read's error/source.
    // Mutation: SelectionBorrow.capture, `onSelection?(...)` deleted -> RED;
    // `path: path` -> `path: .ax` -> RED in the copy/none cases.
    func testEachPressReportsThePathAndTheAXRead() {
        func press(_ read: AXSelection, copy: String? = nil) -> SelectionReport? {
            let board = FakePasteboard(text: "the user's copy")
            var reports: [SelectionReport] = []
            _ = SelectionBorrow.capture(board: board,
                                        selectedText: { read },
                                        secureInput: { false },
                                        postCopy: { if let copy { board.userCopies(copy) } },
                                        spin: { _ in },
                                        readText: { board.text },
                                        onSelection: { reports.append($0) })
            XCTAssertEqual(reports.count, 1, "exactly one report per press")
            return reports.first
        }
        XCTAssertEqual(press(ax("hello"))?.line, "selection path=ax ax_err=0 source=systemwide")
        XCTAssertEqual(press(ax("hello", source: .app))?.line, "selection path=ax ax_err=0 source=app")
        XCTAssertEqual(press(ax(nil, error: -25212, source: .app), copy: "copied")?.line,
                       "selection path=copy ax_err=-25212 source=app")
        XCTAssertEqual(press(ax(nil, error: -25205))?.line,
                       "selection path=none ax_err=-25205 source=systemwide",
                       "AX gave nothing and ⌘C copied nothing")
        XCTAssertEqual(press(ax("pw", secureField: true))?.line,
                       "selection path=none ax_err=0 source=systemwide",
                       "a refused secure field is not an ax read")
    }

    // The source choice: the system-wide element first; the frontmost app's
    // only when the first yields no focused element.
    // Mutation: AXSelection.read, `first.hasElement ? first : app()` ->
    // `app()` -> RED; `-> first` -> RED (the fallback never runs).
    func testTheSystemWideElementWinsAndTheAppIsTheFallback() {
        var appAsked = 0
        let wide = AXSelection(text: "wide", hasElement: true, error: 0, source: .systemWide)
        let fromApp = AXSelection(text: "app", hasElement: true, error: 0, source: .app)
        let got = AXSelection.read(systemWide: { wide }, app: { appAsked += 1; return fromApp })
        XCTAssertEqual(got, wide)
        XCTAssertEqual(appAsked, 0, "the app element is not queried when the system-wide one answers")

        let refused = AXSelection(hasElement: false, error: -25204, source: .systemWide)
        XCTAssertEqual(AXSelection.read(systemWide: { refused }, app: { appAsked += 1; return fromApp }), fromApp)
        XCTAssertEqual(appAsked, 1)

        let noneEither = AXSelection(hasElement: false, error: -25212, source: .app)
        XCTAssertEqual(AXSelection.read(systemWide: { refused }, app: { noneEither }).source, .app,
                       "both failed: the report says the app source was the last one tried")
    }

    // Wiring guard: the app forwards the remote-copy line to the unified log —
    // without it the loss happens silently. Anchored on both source files:
    // SelectionCapture must pass the hook through, AppDelegate must set it.
    func testTheAppWiresTheRemoteCopyLine() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DictationCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        let capture = (try? String(contentsOf: root.appendingPathComponent("Sources/OxSayDictation/SelectionCapture.swift"),
                                   encoding: .utf8)) ?? ""
        XCTAssertFalse(capture.isEmpty, "SelectionCapture.swift unreadable")
        XCTAssertTrue(capture.contains("onRemoteCopy: onRemoteCopy"),
                      "SelectionCapture drops the remote-copy hook — the fallback is never logged")
        let appDelegate = (try? String(contentsOf: root.appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift"),
                                       encoding: .utf8)) ?? ""
        XCTAssertFalse(appDelegate.isEmpty, "AppDelegate.swift unreadable")
        XCTAssertTrue(appDelegate.contains("capture.onRemoteCopy = {"),
                      "no log line is wired for a ⌘C over a Universal Clipboard copy")
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

    private func source(_ relative: String) -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DictationCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        let text = (try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)) ?? ""
        XCTAssertFalse(text.isEmpty, "\(relative) unreadable")
        return text
    }
}
