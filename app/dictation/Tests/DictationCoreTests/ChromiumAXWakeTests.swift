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

    /// An app whose bundle tree is a dictionary of directory listings (relative to Contents).
    private func app(_ id: String?, tree: [String: [String]] = [:]) -> AppIdentity {
        AppIdentity(bundleID: id, list: { tree[$0] ?? [] })
    }

    private var chrome: AppIdentity { app("com.google.Chrome") }
    private var slack: AppIdentity { app("com.tinyspeck.slackmacgap") }
    private var safari: AppIdentity { app("com.apple.Safari") }

    private func nothing() -> AXSelection {
        AXSelection(text: nil, hasElement: false, error: -25212, source: .app)
    }

    private func found(_ text: String) -> AXSelection {
        AXSelection(text: text, hasElement: true, error: 0, source: .app)
    }

    /// Runs the wake over a scripted retry sequence; `spin` advances a fake clock.
    private func run(_ identity: AppIdentity?, fake: Fake, first: AXSelection? = nil,
                     retries: [AXSelection] = [], policy: WakePolicy = .restore,
                     assistive: Bool = false,
                     retryCount: UnsafeMutablePointer<Int>? = nil,
                     spun: UnsafeMutablePointer<TimeInterval>? = nil) -> AXSelection {
        var clock = Date(timeIntervalSince1970: 1_000)
        var script = retries
        return ChromiumAXWake.read(
            first: first ?? nothing(),
            identity: { identity },
            attributes: fake,
            assistiveTechOn: { assistive },
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

    // Electron does not publish AXManualAccessibility for reading: the old value is
    // unknowable, so false is never written back (a tree VoiceOver relies on stays).
    // Mutation F5: ChromiumAXWake.read, `(policy == .restore && knownOff)` ->
    // `(policy == .restore)` -> RED.
    func testAnUnsupportedPreviousValueIsNeverRestoredToFalse() {
        let fake = Fake()
        fake.values["AXManualAccessibility"] = .unsupported
        let result = run(slack, fake: fake, retries: [found("x")])
        XCTAssertEqual(fake.log, ["read AXManualAccessibility", "write AXManualAccessibility=true", "retry"])
        XCTAssertEqual(result.text, "x")
        XCTAssertEqual(result.wake?.restoreError, 0)
    }

    // VoiceOver or Switch Control on: the attribute is not read, set or restored.
    // Mutation F4: ChromiumAXWake.read, delete the `assistiveTechOn()` guard -> RED.
    func testAssistiveTechMeansNoAttributeWriteAtAll() {
        for kindApp in [chrome, slack] {
            let fake = Fake()
            var retries = 0
            let result = run(kindApp, fake: fake, assistive: true, retryCount: &retries)
            XCTAssertEqual(fake.log, [], "no AX call at all")
            XCTAssertEqual(retries, 0)
            XCTAssertEqual(result.wake?.outcome, .assistiveTech)
        }
    }

    // A non-boolean success (a CFNumber) is an error, never "off".
    // Mutation F6: AXAttributeValue.decode, `?? .error(-25201)` -> `?? .bool(false)` -> RED.
    func testDecodeNeverReadsAnUnknownValueAsOff() {
        XCTAssertEqual(AXAttributeValue.decode(error: 0, boolean: nil), .error(-25201))
        XCTAssertEqual(AXAttributeValue.decode(error: 0, boolean: true), .bool(true))
        XCTAssertEqual(AXAttributeValue.decode(error: 0, boolean: false), .bool(false))
        XCTAssertEqual(AXAttributeValue.decode(error: -25205, boolean: nil), .unsupported)
        XCTAssertEqual(AXAttributeValue.decode(error: -25212, boolean: nil), .unsupported)
        XCTAssertEqual(AXAttributeValue.decode(error: -25204, boolean: nil), .error(-25204))
    }

    // The earlier trail survives a successful retry: the log keeps every source.
    // Mutation F7: ChromiumAXWake.read, delete `result.trail = first.attempts + next.attempts` -> RED.
    func testTheRetryKeepsTheEarlierSourcesInTheTrail() {
        let fake = Fake()
        let first = AXSelection(text: nil, hasElement: false, error: -25204, source: .systemWide)
        let next = AXSelection(text: "t", hasElement: true, error: 0, source: .app)
        let result = run(chrome, fake: fake, first: first, retries: [next])
        XCTAssertEqual(result.trail, [AXSelection.Attempt(source: .systemWide, error: -25204),
                                      AXSelection.Attempt(source: .app, error: 0)])
    }

    // No AX call starts once the deadline passed, even when the pause overshot it.
    // Mutation F8: ChromiumAXWake.read, the loop's `if remaining <= 0.001 { break }` -> `if remaining <= -1000 { break }`
    // -> RED (the clock keeps running past the deadline and the reads go on).
    func testNoRetryStartsAfterTheDeadline() {
        let fake = Fake()
        var clock = Date(timeIntervalSince1970: 1_000)
        var retries = 0
        _ = ChromiumAXWake.read(first: nothing(), identity: { self.chrome }, attributes: fake,
                                retry: { retries += 1; return self.nothing() },
                                spin: { _ in clock = clock.addingTimeInterval(1) }, now: { clock })
        XCTAssertEqual(retries, 1, "the pause overshot the deadline: no second read")
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

    // The tree needs a moment after the set: the first read waits one step too, whether or not it then finds text.
    // Mutation: ChromiumAXWake.read, move `spin(min(step, remaining))` below `let next = retry()` -> RED.
    func testTheFirstRetryWaitsOneStep() {
        for script in [[found("x")], [AXSelection]()] {
            let fake = Fake()
            var events: [String] = []
            var clock = Date(timeIntervalSince1970: 1_000)
            var queue = script
            _ = ChromiumAXWake.read(first: nothing(), identity: { self.chrome }, attributes: fake,
                                    retry: { events.append("retry"); return queue.isEmpty ? self.nothing() : queue.removeFirst() },
                                    spin: { events.append("spin \($0)"); clock = clock.addingTimeInterval($0) }, now: { clock })
            XCTAssertEqual(Array(events.prefix(2)), ["spin \(ChromiumAXWake.step)", "retry"])
            XCTAssertEqual(fake.log.prefix(2), ["read AXEnhancedUserInterface", "write AXEnhancedUserInterface=true"])
        }
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
        // every retry follows a pause of one step, so there are never more reads than whole steps in the wait
        XCTAssertLessThanOrEqual(retries, Int((ChromiumAXWake.wait / ChromiumAXWake.step).rounded()))
        XCTAssertEqual(spun, ChromiumAXWake.wait, accuracy: 0.0001, "the whole wait is used by an app that never answers")
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

    /// The real layout of a Chromium browser (see the installed Chrome and Brave): the helpers live
    /// inside the framework's Versions/<v>/Helpers, not beside it.
    private func chromiumTree(_ name: String) -> [String: [String]] {
        let fw = "Frameworks/\(name) Framework.framework"
        return ["Frameworks": ["\(name) Framework.framework", "Sparkle.framework"],
                "\(fw)/Versions": ["1.2.3", "Current"],
                "\(fw)/Versions/1.2.3/Helpers": ["\(name) Helper (Renderer).app", "\(name) Helper.app"],
                "\(fw)/Versions/Current/Helpers": ["\(name) Helper (Renderer).app", "\(name) Helper.app"]]
    }

    func testKnownBrowsersAndElectronAppsAreRecognisedByBundleID() {
        for id in ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "org.chromium.Chromium"] {
            XCTAssertEqual(WebAppKind.classify(app(id)), .chromium, id)
        }
        for id in ["com.microsoft.VSCode", "com.tinyspeck.slackmacgap"] {
            XCTAssertEqual(WebAppKind.classify(app(id)), .electron, id)
        }
    }

    // Spotify is CEF, not Electron: the id list does not claim it either way.
    func testSpotifyIsNotInTheElectronIDList() {
        XCTAssertNil(WebAppKind.classify(app("com.spotify.client")))
    }

    // The bundle is listed only when the id did not decide.
    func testAKnownIDListsNothing() {
        var listings = 0
        let known = AppIdentity(bundleID: "com.google.Chrome", list: { _ in listings += 1; return [] })
        XCTAssertEqual(WebAppKind.classify(known), .chromium)
        XCTAssertEqual(listings, 0)
        let unknown = AppIdentity(bundleID: "com.example.x", list: { _ in listings += 1; return [] })
        XCTAssertNil(WebAppKind.classify(unknown))
        XCTAssertGreaterThan(listings, 0)
    }

    // A new Electron app no list knows: the bundle's own framework gives it away.
    func testAnUnknownElectronAppIsRecognisedByItsFramework() {
        let id = app("com.example.newapp", tree: ["Frameworks": ["Electron Framework.framework", "Squirrel.framework"]])
        XCTAssertEqual(WebAppKind.classify(id), .electron)
    }

    // A new Chromium browser, in the real layout: "<Name> Framework.framework/Versions/*/Helpers/<Name> Helper*.app".
    // Mutation F9: WebAppKind.classify, look beside the framework (`app.list("Frameworks")`) instead of its
    // Versions/*/Helpers -> RED.
    func testAnUnknownChromiumBrowserIsRecognisedByTheRealLayout() {
        XCTAssertEqual(WebAppKind.classify(app("com.example.newbrowser", tree: chromiumTree("Newbrowser"))), .chromium)
    }

    // Helpers beside the framework is a layout no browser has: not a match.
    func testHelpersBesideTheFrameworkAreNotTheRealLayout() {
        let id = app("com.example.fiction", tree: ["Frameworks": ["Fiction Framework.framework", "Fiction Helper (GPU).app"]])
        XCTAssertNil(WebAppKind.classify(id))
    }

    func testCEFEmbeddersAreChromium() {
        let id = app("com.example.cef", tree: ["Frameworks": ["Chromium Embedded Framework.framework"]])
        XCTAssertEqual(WebAppKind.classify(id), .chromium)
    }

    // A "Framework" with no helpers (Sparkle, an SDK) is not a browser.
    func testAnOrdinaryFrameworkIsNotChromium() {
        let id = app("com.example.native", tree: ["Frameworks": ["Foo Framework.framework", "Bar Helper.app"],
                                                  "Frameworks/Foo Framework.framework/Versions": ["A"],
                                                  "Frameworks/Foo Framework.framework/Versions/A/Helpers": ["Other.app"]])
        XCTAssertNil(WebAppKind.classify(id))
    }

    func testSafariAndNativeAppsAreNotWebApps() {
        XCTAssertNil(WebAppKind.classify(app("com.apple.Safari")))
        XCTAssertNil(WebAppKind.classify(app("com.apple.TextEdit")))
        XCTAssertNil(WebAppKind.classify(app(nil)))
    }

    // The classifier against the REAL bundle trees of installed apps: directory listings only, no AX.
    // The bundle id is withheld so the structure alone decides. CI has none of these apps: skipped.
    func testTheStructuralRuleOnTheRealInstalledBundles() {
        let cases: [(path: String, kind: WebAppKind?)] = [
            ("/Applications/Google Chrome.app", .chromium), ("/Applications/Brave Browser.app", .chromium),
            ("/Applications/Slack.app", .electron), ("/Applications/Visual Studio Code.app", .electron),
            ("/Applications/Safari.app", nil), ("/System/Applications/TextEdit.app", nil),
        ]
        var checked = 0
        var skipped: [String] = []
        for c in cases {
            let contents = URL(fileURLWithPath: c.path).appendingPathComponent("Contents")
            guard FileManager.default.fileExists(atPath: contents.path) else { skipped.append(c.path); continue }
            let kind = WebAppKind.classify(AppIdentity.onDisk(bundleID: nil, contents: contents))
            XCTAssertEqual(kind, c.kind, "\(c.path) classified as \(String(describing: kind))")
            checked += 1
        }
        // The shim's XCTest has no XCTSkip: say so on the log and pass vacuously.
        if checked == 0 { print("SKIPPED testTheStructuralRuleOnTheRealInstalledBundles: none of the sample apps is installed here: \(skipped)") }
        else { print("real bundles checked: \(checked), not installed: \(skipped)") }
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
        XCTAssertTrue(body.contains("assistiveTechOn:") && body.contains("isVoiceOverEnabled")
                      && body.contains("isSwitchControlEnabled"), "the assistive-tech check is wired")
        XCTAssertTrue(source.contains("AppIdentity.onDisk("), "the bundle structure is the identity signal")
    }

    // MARK: one press at a time

    func testASecondPressInsideTheFirstIsRefused() {
        let gate = CaptureGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin(), "a press delivered while the capture spins the run loop")
        gate.end()
        XCTAssertTrue(gate.begin(), "the next press after the first ended")
        gate.end()
        gate.end()
        XCTAssertTrue(gate.begin(), "an extra end is harmless")
    }

    /// Mutation F10: AppDelegate.speakSelection, delete `guard capture.beginPress() else { return }` -> RED;
    /// SelectionCapture.capture, `gate.ending {` -> a bare call -> RED (here and in the behaviour tests below).
    func testTheAppGuardsOnePressAtATime() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation")
        let delegate = MeetingWiringTests.stripComments(try String(contentsOf: dir.appendingPathComponent("AppDelegate.swift"), encoding: .utf8))
        let start = try XCTUnwrap(delegate.range(of: "private func speakSelection() {"))
        let end = try XCTUnwrap(delegate.range(of: "\n    }\n", range: start.upperBound..<delegate.endIndex))
        let body = String(delegate[start.lowerBound..<end.upperBound])
        let install = try XCTUnwrap(body.range(of: "guard !refuseSpeechWhileUpdating() else { return }"))
        let press = try XCTUnwrap(body.range(of: "guard capture.beginPress() else { return }"))
        let capture = try XCTUnwrap(body.range(of: "capture.capture()"))
        XCTAssertLessThan(install.lowerBound, press.lowerBound)
        XCTAssertLessThan(press.lowerBound, capture.lowerBound)
        // The press ends where the capture ends, not in a report callback somebody may move.
        let cap = MeetingWiringTests.stripComments(try String(contentsOf: dir.appendingPathComponent("SelectionCapture.swift"), encoding: .utf8))
        let fn = try XCTUnwrap(cap.range(of: "func capture() -> (text: String?, problem: String?) {"))
        let fnEnd = try XCTUnwrap(cap.range(of: "\n    }\n", range: fn.upperBound..<cap.endIndex))
        let captureBody = String(cap[fn.lowerBound..<fnEnd.upperBound])
        XCTAssertTrue(captureBody.contains("gate.ending {"), "the capture runs inside the gate")
        XCTAssertTrue(captureBody.contains("SelectionBorrow.capture("))
        XCTAssertEqual(cap.components(separatedBy: "gate.end").count - 1, 1, "the gate ends in one place only (`gate.ending`)")
        XCTAssertFalse(cap.contains("reporter"), "the report callback no longer carries the gate")
    }

    // The press ends on every way out of the capture: each path of SelectionBorrow, with and without a listener.
    // Mutation: CaptureGate.ending, delete `defer { end() }` -> RED (the next begin() is refused).
    func testACaptureEndsThePressOnEveryExit() {
        let paths: [(String, () -> (AXSelection, FakePasteboard))] = [
            ("ax text", { (self.found("selected"), FakePasteboard(text: "old")) }),
            ("secure field", { (AXSelection(text: nil, secureField: true, hasElement: true, error: 0, source: .app), FakePasteboard(text: "old")) }),
            ("nothing selected: the copy times out", { (self.nothing(), FakePasteboard(text: "old")) }),
        ]
        for (name, make) in paths {
            for listening in [true, false] {
                let gate = CaptureGate()
                XCTAssertTrue(gate.begin(), name)
                let (ax, board) = make()
                var reports = 0
                let result = gate.ending {
                    SelectionBorrow.capture(board: board, selectedText: { ax }, secureInput: { false }, postCopy: {},
                                            spin: { _ in }, readText: { nil }, memory: SlowClipboardMemory(), copyTimeout: 0,
                                            onSelection: listening ? { _ in reports += 1 } : nil)
                }
                _ = result
                XCTAssertEqual(reports, listening ? 1 : 0, name)
                XCTAssertTrue(gate.begin(), "\(name) (listener: \(listening)): the next press must not be refused for good")
            }
        }
        // an iPhone copy is declined without ⌘C: another exit
        let remote = FakePasteboard(text: "copied on the iPhone")
        remote.items[0].append((type: PasteboardMarker.remoteClipboard, data: Data()))
        let gate = CaptureGate()
        XCTAssertTrue(gate.begin())
        _ = gate.ending {
            SelectionBorrow.capture(board: remote, selectedText: { self.nothing() }, secureInput: { false }, postCopy: {},
                                    spin: { _ in }, readText: { nil }, memory: SlowClipboardMemory())
        }
        XCTAssertTrue(gate.begin(), "declined on an iPhone copy")
    }

    // While the capture runs the gate stays shut: a press delivered inside it is refused.
    func testTheGateStaysShutDuringTheCapture() {
        let gate = CaptureGate()
        XCTAssertTrue(gate.begin())
        var insideRefused = false
        gate.ending { insideRefused = !gate.begin() }
        XCTAssertTrue(insideRefused)
        XCTAssertTrue(gate.begin())
    }
}
