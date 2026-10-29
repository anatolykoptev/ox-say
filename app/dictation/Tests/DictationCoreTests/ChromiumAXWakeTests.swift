import XCTest
@testable import DictationCore

/// #220: Chromium and Electron publish no focused element over Accessibility
/// until asked. Every AX call here goes through a fake `AXAppAttributes`; no
/// real app, clipboard or event is touched.
final class ChromiumAXWakeTests: XCTestCase {
    /// Records every call in order, so the order (set → retry → restore) is asserted.
    private final class Fake: AXAppAttributes {
        var log: [String] = []
        var values: [String: AXAttributeValue] = [:]
        var writeError: [String: Int32] = [:]
        var writeErrorOnValue: [Bool: Int32] = [:]

        func read(_ name: String) -> AXAttributeValue {
            log.append("read \(name)")
            return values[name] ?? .bool(false)
        }

        func write(_ name: String, _ value: Bool) -> Int32 {
            log.append("write \(name)=\(value)")
            if let e = writeErrorOnValue[value] { return e }
            return writeError[name] ?? 0
        }
    }

    private let chrome = AppIdentity(bundleID: "com.google.Chrome", frameworks: [])
    private let slack = AppIdentity(bundleID: "com.tinyspeck.slackmacgap", frameworks: [])
    private let safari = AppIdentity(bundleID: "com.apple.Safari", frameworks: [])

    private func nothing() -> AXSelection {
        AXSelection(text: nil, hasElement: false, error: -25212, source: .app)
    }

    private func found(_ text: String) -> AXSelection {
        AXSelection(text: text, hasElement: true, error: 0, source: .app)
    }

    /// Runs the wake over a scripted retry sequence; `spin` advances a fake clock.
    private func run(_ identity: AppIdentity?, fake: Fake, first: AXSelection? = nil,
                     retries: [AXSelection] = [], policy: WakePolicy = .restore,
                     retryCount: UnsafeMutablePointer<Int>? = nil,
                     spun: UnsafeMutablePointer<TimeInterval>? = nil) -> AXSelection {
        var clock = Date(timeIntervalSince1970: 1_000)
        var script = retries
        return ChromiumAXWake.read(
            first: first ?? nothing(),
            identity: { identity },
            attributes: fake,
            retry: {
                retryCount?.pointee += 1
                fake.log.append("retry")
                return script.isEmpty ? self.nothing() : script.removeFirst()
            },
            spin: { clock = clock.addingTimeInterval($0); spun?.pointee += $0 },
            now: { clock },
            policy: policy)
    }

    // The Chromium path sets AXEnhancedUserInterface, retries the read and puts the
    // previous value back AFTER the read.
    // Mutation F1: ChromiumAXWake.read, skip the restore write -> RED.
    // Mutation F3: ChromiumAXWake.read, skip the retry after the set -> RED.
    func testChromiumSetsReadsAgainAndRestores() {
        let fake = Fake()
        let result = run(chrome, fake: fake, retries: [found("the selection")])
        XCTAssertEqual(result.text, "the selection")
        XCTAssertEqual(fake.log, ["read AXEnhancedUserInterface", "write AXEnhancedUserInterface=true",
                                  "retry", "write AXEnhancedUserInterface=false"])
        XCTAssertEqual(result.wake, AXWake(kind: .chromium, outcome: .found, restoreError: 0))
    }

    func testElectronUsesManualAccessibility() {
        let fake = Fake()
        let result = run(slack, fake: fake, retries: [found("the selection")])
        XCTAssertEqual(result.text, "the selection")
        XCTAssertEqual(fake.log, ["read AXManualAccessibility", "write AXManualAccessibility=true",
                                  "retry", "write AXManualAccessibility=false"])
        XCTAssertEqual(result.wake?.kind, .electron)
    }

    // A non-Chromium app is never touched: no attribute read, no write, no retry.
    // Mutation F2: ChromiumAXWake.read, drop the classification (treat every app
    // as Chromium) -> RED.
    func testANonChromiumAppIsLeftAlone() {
        let fake = Fake()
        var retries = 0
        let result = run(safari, fake: fake, retryCount: &retries)
        XCTAssertEqual(fake.log, [])
        XCTAssertEqual(retries, 0)
        XCTAssertNil(result.wake)
        XCTAssertEqual(result, nothing())
    }

    func testAnUnidentifiableFrontmostAppIsLeftAlone() {
        let fake = Fake()
        _ = run(nil, fake: fake)
        XCTAssertEqual(fake.log, [])
    }

    // AX already answered with text: nothing to wake, the identity is not even asked.
    func testASelectionAlreadyReadIsReturnedUntouched() {
        let fake = Fake()
        var asked = false
        let first = found("already")
        let result = ChromiumAXWake.read(first: first, identity: { asked = true; return self.chrome },
                                         attributes: fake, retry: { XCTFail("no retry"); return self.nothing() },
                                         spin: { _ in }, now: Date.init)
        XCTAssertEqual(result, first)
        XCTAssertFalse(asked)
        XCTAssertEqual(fake.log, [])
    }

    // A secure field is refused whole elsewhere; waking the app for it is pointless.
    func testASecureFieldIsNotWoken() {
        let fake = Fake()
        let first = AXSelection(text: nil, secureField: true, hasElement: true, error: 0, source: .app)
        _ = run(chrome, fake: fake, first: first)
        XCTAssertEqual(fake.log, [])
    }

    // The attribute is set but there is still no selection: the first read comes
    // back so the caller falls to ⌘C, and the previous value is restored.
    func testStillNoSelectionAfterTheSetFallsBackAndRestores() {
        let fake = Fake()
        let first = nothing()
        let result = run(chrome, fake: fake, first: first)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.wake?.outcome, .nothing)
        XCTAssertEqual(fake.log.last, "write AXEnhancedUserInterface=false")
        XCTAssertEqual(fake.log.first, "read AXEnhancedUserInterface")
    }

    // An AX error on the set: no retry (nothing changed), no restore write, ⌘C fallback.
    func testASetErrorFallsBackWithoutRetryOrRestore() {
        let fake = Fake()
        fake.writeError["AXEnhancedUserInterface"] = -25200
        var retries = 0
        let result = run(chrome, fake: fake, retryCount: &retries)
        XCTAssertEqual(retries, 0)
        XCTAssertEqual(fake.log, ["read AXEnhancedUserInterface", "write AXEnhancedUserInterface=true"])
        XCTAssertNil(result.text)
        XCTAssertEqual(result.wake?.outcome, .setFailed(-25200))
    }

    // The previous value could not be read (not "unsupported"): it could not be put
    // back, so the attribute is not touched at all.
    func testAnUnreadablePreviousValueMeansNoSet() {
        let fake = Fake()
        fake.values["AXEnhancedUserInterface"] = .error(-25204)
        let result = run(chrome, fake: fake)
        XCTAssertEqual(fake.log, ["read AXEnhancedUserInterface"])
        XCTAssertEqual(result.wake?.outcome, .readFailed(-25204))
    }

    // Electron does not publish AXManualAccessibility for reading: unsupported
    // means "off", and off is what is restored.
    func testAnUnsupportedPreviousValueIsRestoredToFalse() {
        let fake = Fake()
        fake.values["AXManualAccessibility"] = .unsupported
        _ = run(slack, fake: fake, retries: [found("x")])
        XCTAssertEqual(fake.log.last, "write AXManualAccessibility=false")
    }

    // Already on (the user's own setting or another tool): leave it as found, no retry
    // can turn up anything the first read missed.
    func testAnAttributeAlreadyOnIsNeitherSetNorRestored() {
        let fake = Fake()
        fake.values["AXEnhancedUserInterface"] = .bool(true)
        var retries = 0
        let result = run(chrome, fake: fake, retryCount: &retries)
        XCTAssertEqual(fake.log, ["read AXEnhancedUserInterface"])
        XCTAssertEqual(retries, 0)
        XCTAssertEqual(result.wake?.outcome, .alreadyOn)
    }

    // The tree appears a moment after the set: the read is repeated until it does.
    func testALateTreeIsFoundOnALaterRetry() {
        let fake = Fake()
        var retries = 0
        let result = run(chrome, fake: fake, retries: [nothing(), nothing(), found("late")], retryCount: &retries)
        XCTAssertEqual(result.text, "late")
        XCTAssertEqual(retries, 3)
    }

    // The wait is bounded: an app that never answers costs at most `wait`, in whole steps.
    func testTheWaitIsBounded() {
        let fake = Fake()
        var retries = 0
        var spun: TimeInterval = 0
        _ = run(chrome, fake: fake, retryCount: &retries, spun: &spun)
        XCTAssertLessThanOrEqual(spun, ChromiumAXWake.wait + 0.0001)
        XCTAssertGreaterThan(retries, 1, "a bounded wait still retries more than once")
        XCTAssertLessThanOrEqual(retries, Int(ChromiumAXWake.wait / ChromiumAXWake.step) + 1)
    }

    // A slow AX call eats the budget too: the bound is the clock, not the retry count.
    func testASlowReadStopsTheWaitEarly() {
        let fake = Fake()
        var clock = Date(timeIntervalSince1970: 1_000)
        var retries = 0
        _ = ChromiumAXWake.read(first: nothing(), identity: { self.chrome }, attributes: fake,
                                retry: { retries += 1; clock = clock.addingTimeInterval(0.5); return self.nothing() },
                                spin: { clock = clock.addingTimeInterval($0) }, now: { clock })
        XCTAssertEqual(retries, 1, "one read already used the whole wait")
        XCTAssertEqual(fake.log.last, "write AXEnhancedUserInterface=false")
    }

    // The restore failing is recorded, the selection is still returned.
    func testARestoreErrorIsRecordedAndTheTextStillReturned() {
        let fake = Fake()
        fake.writeErrorOnValue[false] = -25202
        let result = run(chrome, fake: fake, retries: [found("text")])
        XCTAssertEqual(result.text, "text")
        XCTAssertEqual(result.wake?.restoreError, -25202)
    }

    // The reset policy is one parameter; `.leave` keeps the attribute on.
    func testTheLeavePolicySkipsTheRestore() {
        let fake = Fake()
        _ = run(chrome, fake: fake, retries: [found("text")], policy: .leave)
        XCTAssertEqual(fake.log, ["read AXEnhancedUserInterface", "write AXEnhancedUserInterface=true", "retry"])
    }

    func testTheDefaultPolicyIsRestore() {
        XCTAssertEqual(ChromiumAXWake.defaultPolicy, .restore)
    }

    // A secure field turning up after the wake is returned (refused whole downstream).
    func testASecureFieldAfterTheWakeIsReturned() {
        let fake = Fake()
        let secure = AXSelection(text: nil, secureField: true, hasElement: true, error: 0, source: .app)
        let result = run(chrome, fake: fake, retries: [secure])
        XCTAssertTrue(result.secureField)
        XCTAssertEqual(fake.log.last, "write AXEnhancedUserInterface=false")
    }

    // The earlier trail survives into the result, so the log line keeps every source.
    func testTheWakeJoinsTheLogLine() {
        let report = SelectionReport(path: .ax, attempts: [AXSelection.Attempt(source: .app, error: 0)],
                                     wake: AXWake(kind: .chromium, outcome: .setFailed(-25200), restoreError: 0))
        XCTAssertEqual(report.line, "selection path=ax ax=app:0 wake=chromium:set-failed(-25200)")
        let ok = SelectionReport(path: .ax, attempts: [AXSelection.Attempt(source: .app, error: 0)],
                                 wake: AXWake(kind: .electron, outcome: .found, restoreError: -25202))
        XCTAssertEqual(ok.line, "selection path=ax ax=app:0 wake=electron:found restore=-25202")
        let none = SelectionReport(path: .copy, attempts: [AXSelection.Attempt(source: .app, error: 0)])
        XCTAssertEqual(none.line, "selection path=copy ax=app:0")
    }

    func testTheWakeTravelsFromTheReadToTheReport() {
        let board = FakePasteboard(text: "x")
        var report: SelectionReport?
        var ax = found("the selection")
        ax.wake = AXWake(kind: .chromium, outcome: .found, restoreError: 0)
        _ = SelectionBorrow.capture(board: board, selectedText: { ax }, secureInput: { false },
                                    postCopy: {}, spin: { _ in }, readText: { nil },
                                    memory: SlowClipboardMemory(), onSelection: { report = $0 })
        XCTAssertEqual(report?.wake, ax.wake)
    }

    // MARK: classification

    func testKnownBrowsersAndElectronAppsAreRecognisedByBundleID() {
        for id in ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "org.chromium.Chromium"] {
            XCTAssertEqual(WebAppKind.classify(AppIdentity(bundleID: id, frameworks: [])), .chromium, id)
        }
        for id in ["com.microsoft.VSCode", "com.tinyspeck.slackmacgap"] {
            XCTAssertEqual(WebAppKind.classify(AppIdentity(bundleID: id, frameworks: [])), .electron, id)
        }
    }

    // A new Electron app no list knows: the bundle's own framework gives it away.
    func testAnUnknownElectronAppIsRecognisedByItsFramework() {
        let id = AppIdentity(bundleID: "com.example.newapp",
                             frameworks: ["Electron Framework.framework", "Squirrel.framework", "NewApp Helper.app"])
        XCTAssertEqual(WebAppKind.classify(id), .electron)
    }

    // A new Chromium browser: "<Name> Framework.framework" beside "<Name> Helper*.app".
    func testAnUnknownChromiumBrowserIsRecognisedByFrameworkAndHelpers() {
        let id = AppIdentity(bundleID: "com.example.newbrowser",
                             frameworks: ["Newbrowser Framework.framework", "Newbrowser Helper (Renderer).app",
                                          "Newbrowser Helper (GPU).app"])
        XCTAssertEqual(WebAppKind.classify(id), .chromium)
    }

    func testCEFEmbeddersAreChromium() {
        let id = AppIdentity(bundleID: "com.example.cef", frameworks: ["Chromium Embedded Framework.framework"])
        XCTAssertEqual(WebAppKind.classify(id), .chromium)
    }

    // A "Framework" with no matching helper is not a browser (Sparkle, plain SDK bundles).
    func testAnOrdinaryFrameworkIsNotChromium() {
        let id = AppIdentity(bundleID: "com.example.native",
                             frameworks: ["Sparkle.framework", "Foo Framework.framework", "Bar Helper.app"])
        XCTAssertNil(WebAppKind.classify(id))
    }

    func testSafariAndNativeAppsAreNotWebApps() {
        XCTAssertNil(WebAppKind.classify(AppIdentity(bundleID: "com.apple.Safari", frameworks: [])))
        XCTAssertNil(WebAppKind.classify(AppIdentity(bundleID: "com.apple.TextEdit", frameworks: [])))
        XCTAssertNil(WebAppKind.classify(AppIdentity(bundleID: nil, frameworks: [])))
    }

    // MARK: app wiring

    /// The app's one AX read goes through the wake, with the same read as the retry
    /// and the AX seam the wake is tested against.
    /// Mutation: SelectionCapture.selectedText, `return ChromiumAXWake.read(` ->
    /// `return first` (the wake dropped) -> RED; `retry: once` -> `retry: { first }` -> RED.
    func testTheAppReadsThroughTheWake() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/SelectionCapture.swift")
        let source = MeetingWiringTests.stripComments(try String(contentsOf: path, encoding: .utf8))
        let start = try XCTUnwrap(source.range(of: "private func selectedText() -> AXSelection {"))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.upperBound])
        XCTAssertTrue(body.contains("return ChromiumAXWake.read(first: first,"))
        XCTAssertTrue(body.contains("retry: once,"), "the retry is the same selection read")
        XCTAssertTrue(body.contains("AppElementAttributes(root:"), "the AX seam is the app element's")
        XCTAssertTrue(source.contains("Contents/Frameworks"), "the bundle structure is the identity signal")
    }
}
