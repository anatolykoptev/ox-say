import Foundation
import XCTest
@testable import DictationCore

/// #530: the "them" channel hears the call's processes, not every app on the Mac.
final class CallAudioScopeTests: XCTestCase {
    private func p(_ id: UInt32, _ pid: Int32, _ bundle: String) -> AudioProcess { AudioProcess(objectID: id, pid: pid, bundleID: bundle) }

    /// The scope as if these call apps had been verified: the scope logic is what is under test here; whether an app is
    /// verified is `testNoAppIsVerifiedYet` and the allowlist tests below.
    private let allVerified: Set<String> = ["com.google.Chrome", "us.zoom.xos", "com.apple.FaceTime", "com.microsoft.teams2"]
    private func scoped(callBundleID: String?, processes: [AudioProcess], ownPID: Int32) -> TapScope {
        CallAudioScope.scope(callBundleID: callBundleID, processes: processes, ownPID: ownPID, verified: allVerified)
    }

    private let mac: [AudioProcess] = [
        AudioProcess(objectID: 10, pid: 100, bundleID: "com.google.Chrome.helper"),
        AudioProcess(objectID: 11, pid: 101, bundleID: "com.google.Chrome.helper.Renderer"),
        AudioProcess(objectID: 12, pid: 102, bundleID: "com.spotify.client"),
        AudioProcess(objectID: 13, pid: 103, bundleID: "com.apple.Music"),
        AudioProcess(objectID: 14, pid: 104, bundleID: "io.github.anatolykoptev.ox-say.dictation"),
        AudioProcess(objectID: 15, pid: 105, bundleID: "com.google.Chrome2"),
        AudioProcess(objectID: 16, pid: 106, bundleID: "us.zoom.xos"),
    ]

    /// Music and another app's video are not in a Meet call's scope; Chrome's helpers are, and the look-alike is not.
    /// Mutation: CallAudioScope.scope, drop the `belongs(...)` filter (take every process) -> RED.
    func testOnlyTheCallAppsProcessesAreInScope() {
        XCTAssertEqual(scoped(callBundleID: "com.google.Chrome", processes: mac, ownPID: 999), .call([10, 11]))
        XCTAssertEqual(scoped(callBundleID: "us.zoom.xos", processes: mac, ownPID: 999), .call([16]))
    }

    /// Mutation: CallAudioScope.belongs, `hasPrefix(call + ".")` -> `hasPrefix(call)` -> RED (com.google.Chrome2 joins).
    func testALookAlikeBundleIsNotTheCall() {
        XCTAssertEqual(scoped(callBundleID: "com.google.Chrome", processes: [p(15, 105, "com.google.Chrome2")], ownPID: 1), .global)
    }

    /// OxSay's own sound (a voice it speaks, a sound it plays) never goes into the recording, by pid and by bundle.
    /// Mutation: CallAudioScope.scope, delete the `$0.pid != ownPID` and own-bundle conditions -> RED.
    func testOxSayItselfIsNeverInScope() {
        let own = [p(1, 500, "com.google.Chrome.helper"), p(2, 501, "io.github.anatolykoptev.ox-say.dictation.helper")]
        XCTAssertEqual(scoped(callBundleID: "com.google.Chrome", processes: own, ownPID: 500), .global,
                       "the only matching process is OxSay's own pid")
        XCTAssertEqual(scoped(callBundleID: "io.github.anatolykoptev.ox-say.dictation", processes: own, ownPID: 1), .global)
    }

    /// The fallback: no call known, or the call's process not found, is the whole Mac minus OxSay.
    /// Mutation: CallAudioScope.scope, `ids.isEmpty ? .global : ...` -> `.call(Set(ids))` -> RED (a tap on nothing).
    func testNoCallOrNoProcessFallsBackToGlobal() {
        XCTAssertEqual(scoped(callBundleID: nil, processes: mac, ownPID: 999), .global)
        XCTAssertEqual(scoped(callBundleID: "", processes: mac, ownPID: 999), .global)
        XCTAssertEqual(scoped(callBundleID: "com.microsoft.teams2", processes: mac, ownPID: 999), .global)
        XCTAssertEqual(scoped(callBundleID: "us.zoom.xos", processes: [], ownPID: 999), .global)
    }

    /// FaceTime's sound is played by a system daemon.
    /// Mutation: CallAudioScope.extraBundles, delete the FaceTime entry -> RED.
    func testFaceTimeIncludesItsAudioDaemon() {
        let ft = [p(1, 10, "com.apple.FaceTime"), p(2, 11, "com.apple.avconferenced"), p(3, 12, "com.apple.Music")]
        XCTAssertEqual(scoped(callBundleID: "com.apple.FaceTime", processes: ft, ownPID: 999), .call([1, 2]))
        XCTAssertEqual(scoped(callBundleID: "us.zoom.xos", processes: ft, ownPID: 999), .global, "the daemon is FaceTime's only")
    }

    /// Nothing has been checked on a real call yet, so every app keeps the whole-Mac tap and merging changes nothing.
    /// When an app is verified (the live matrix in #608 passed for it), add it to the list and to this expectation.
    /// Mutation: CallAudioScope.verifiedScopedApps, `[]` -> `["us.zoom.xos"]` -> RED.
    func testNoAppIsVerifiedYet() {
        XCTAssertEqual(CallAudioScope.verifiedScopedApps, [])
    }

    /// An app that is not on the list is never scoped, whatever its processes look like: through the shipped default (the
    /// recorder's path), and with an explicit list that lacks it.
    /// Mutation: CallAudioScope.scopedCall, `? call : nil` -> `? call : call` -> RED; or `scope(...)`'s
    /// `guard let call = scopedCall(...)` -> `guard let call = callBundleID` -> RED.
    func testAnUnverifiedAppGetsTheWholeMacTap() {
        for app in ["com.google.Chrome", "us.zoom.xos", "com.apple.FaceTime", "com.microsoft.teams2"] {
            XCTAssertEqual(CallAudioScope.scope(callBundleID: app, processes: mac, ownPID: 999), .global, "\(app), shipped list")
            XCTAssertEqual(CallAudioScope.scope(callBundleID: app, processes: mac, ownPID: 999, verified: ["org.other.app"]), .global, app)
        }
        XCTAssertEqual(CallAudioScope.scope(callBundleID: "us.zoom.xos", processes: mac, ownPID: 999, verified: ["us.zoom.xos"]), .call([16]),
                       "listed: scoped")
    }

    /// The list is read without regard to case, and an unlisted or empty call resolves to nil (an unverified app looks
    /// exactly like "no call known" to the recorder).
    /// Mutation: CallAudioScope.scopedCall, drop the `.lowercased()` on `wanted` -> RED.
    func testTheVerifiedListIsMatchedCaseInsensitively() {
        XCTAssertEqual(CallAudioScope.scopedCall("US.Zoom.XOS", verified: ["us.zoom.xos"]), "US.Zoom.XOS")
        XCTAssertNil(CallAudioScope.scopedCall("us.zoom.xos", verified: []))
        XCTAssertNil(CallAudioScope.scopedCall("", verified: [""]))
        XCTAssertNil(CallAudioScope.scopedCall(nil, verified: ["us.zoom.xos"]))
    }

    /// Bundle ids match without regard to case: a helper, the call app, FaceTime's daemon and OxSay's own exclusion.
    /// Mutation: CallAudioScope.belongs, drop `.lowercased()` from `let id = bundleID.lowercased()` -> RED.
    func testBundleIDsMatchWithoutRegardToCase() {
        let odd = [p(1, 10, "COM.Google.Chrome.Helper"), p(2, 11, "com.GOOGLE.chrome"), p(3, 12, "com.google.chrome2"),
                   p(4, 13, "IO.GITHUB.ANATOLYKOPTEV.OX-SAY.DICTATION.helper")]
        XCTAssertEqual(scoped(callBundleID: "com.google.Chrome", processes: odd, ownPID: 999), .call([1, 2]),
                       "OxSay's own helper stays out in any case, and the look-alike is not Chrome")
        XCTAssertEqual(scoped(callBundleID: "com.google.chrome", processes: odd, ownPID: 999), .call([1, 2]), "the call's id in another case")
        let ft = [p(1, 10, "COM.Apple.FaceTime"), p(2, 11, "COM.APPLE.AVCONFERENCED")]
        XCTAssertEqual(CallAudioScope.scope(callBundleID: "com.apple.facetime", processes: ft, ownPID: 999, verified: ["com.apple.FaceTime"]), .call([1, 2]))
    }

    /// What plays: with a scoped tap only the call's processes count as playing, the rest are named as outside; OxSay's
    /// own sound counts for neither; a process without a bundle id is named `<none>`.
    /// Mutation: CallAudioScope.playback, `.call` case `ids.contains($0.objectID)` -> `true` -> RED.
    func testPlaybackSeparatesTheCallFromTheRestAndIgnoresOxSay() {
        let procs = [AudioProcess(objectID: 1, pid: 10, bundleID: "com.google.Chrome.helper", runningOutput: false),
                     AudioProcess(objectID: 2, pid: 11, bundleID: "com.spotify.client", runningOutput: true),
                     AudioProcess(objectID: 3, pid: 12, bundleID: "", runningOutput: true),
                     AudioProcess(objectID: 4, pid: 13, bundleID: "io.github.anatolykoptev.ox-say.dictation", runningOutput: true),
                     AudioProcess(objectID: 5, pid: 500, bundleID: "com.apple.Music", runningOutput: true)]
        let quiet = CallAudioScope.playback(processes: procs, scope: .call([1]), call: "com.google.Chrome", ownPID: 500)
        XCTAssertEqual(quiet, CallAudioScope.Playback(inScope: false, outside: ["<none>", "com.spotify.client"]))
        var talking = procs
        talking[0].runningOutput = true
        XCTAssertTrue(CallAudioScope.playback(processes: talking, scope: .call([1]), call: "com.google.Chrome", ownPID: 500).inScope)
    }

    /// A whole-Mac tap hears every process: anything playing counts as in scope (the old rule), and `outside` names what a
    /// per-app scope would have left out, for the log. No call known: nothing is outside.
    /// Mutation: CallAudioScope.playback, `.global` case `inScope = !playing.isEmpty` -> `false` -> RED.
    func testAWholeMacTapCountsEverythingAndNamesWhatTheCallAppIsNot() {
        let procs = [AudioProcess(objectID: 1, pid: 10, bundleID: "us.zoom.xos", runningOutput: true),
                     AudioProcess(objectID: 2, pid: 11, bundleID: "com.spotify.client", runningOutput: true)]
        XCTAssertEqual(CallAudioScope.playback(processes: procs, scope: .global, call: "us.zoom.xos", ownPID: 500),
                       CallAudioScope.Playback(inScope: true, outside: ["com.spotify.client"]))
        XCTAssertEqual(CallAudioScope.playback(processes: procs, scope: .global, call: nil, ownPID: 500),
                       CallAudioScope.Playback(inScope: true, outside: []))
        XCTAssertEqual(CallAudioScope.playback(processes: [], scope: .global, call: "us.zoom.xos", ownPID: 500),
                       CallAudioScope.Playback(inScope: false, outside: []))
    }

    /// The log line: the scope kind, the call, the bundle ids matched; why it is the whole Mac; bundle ids only.
    /// Mutation: CallAudioScope.describe, `.global` case, the `listed ?` branch swapped -> RED.
    func testTheLogLineNamesTheScopeAndTheMatchedBundleIDs() {
        let procs = [p(10, 100, "com.google.Chrome.helper"), p(11, 101, "com.google.Chrome.helper.Renderer"), p(12, 102, "com.spotify.client")]
        XCTAssertEqual(CallAudioScope.describe(scope: .call([10, 11]), observed: "com.google.Chrome", processes: procs, ownPID: 1),
                       "scope=call call=com.google.Chrome tap=com.google.Chrome.helper,com.google.Chrome.helper.Renderer")
        XCTAssertEqual(CallAudioScope.describe(scope: .global, observed: "com.google.Chrome", processes: procs, ownPID: 1),
                       "scope=global (call app not on the verified list) call=com.google.Chrome matched=com.google.Chrome.helper,com.google.Chrome.helper.Renderer")
        XCTAssertEqual(CallAudioScope.describe(scope: .global, observed: "com.google.Chrome", processes: procs, ownPID: 1, verified: ["com.google.Chrome"]),
                       "scope=global (no process of the call found) call=com.google.Chrome matched=com.google.Chrome.helper,com.google.Chrome.helper.Renderer")
        XCTAssertEqual(CallAudioScope.describe(scope: .global, observed: nil, processes: procs, ownPID: 1),
                       "scope=global (no call known) call=<none> matched=<none>")
    }

    /// A new helper joins; losing one does not rebuild; the scope never widens to the whole Mac; leaving the fallback
    /// is immediate.
    /// Mutation: CallAudioScope.needsRebuild, `!want.isSubset(of: have)` -> `want != have` -> RED (rebuilds when a helper exits);
    /// `case (.call, .global): return false` -> `true` -> RED.
    func testRebuildOnlyWhenTheScopeGainsACallProcess() {
        XCTAssertTrue(CallAudioScope.needsRebuild(current: .call([1, 2]), wanted: .call([1, 2, 3])))
        XCTAssertFalse(CallAudioScope.needsRebuild(current: .call([1, 2]), wanted: .call([1])))
        XCTAssertFalse(CallAudioScope.needsRebuild(current: .call([1, 2]), wanted: .call([1, 2])))
        XCTAssertFalse(CallAudioScope.needsRebuild(current: .call([1, 2]), wanted: .global))
        XCTAssertTrue(CallAudioScope.needsRebuild(current: .global, wanted: .call([1])))
        XCTAssertFalse(CallAudioScope.needsRebuild(current: .global, wanted: .global))
    }

    /// A rebuild (a route change) never widens a call's tap to the whole Mac; leaving the fallback and changing the set work.
    /// Mutation: CallAudioScope.scopeForRebuild, delete the `if case .call = current, wanted == .global` line -> RED.
    func testARebuildNeverWidensACallTapToTheWholeMac() {
        XCTAssertEqual(CallAudioScope.scopeForRebuild(current: .call([1, 2]), wanted: .global), .call([1, 2]))
        XCTAssertEqual(CallAudioScope.scopeForRebuild(current: .call([1, 2]), wanted: .call([3])), .call([3]))
        XCTAssertEqual(CallAudioScope.scopeForRebuild(current: .global, wanted: .call([3])), .call([3]))
        XCTAssertEqual(CallAudioScope.scopeForRebuild(current: .global, wanted: .global), .global)
    }

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/\(name)")
        return MeetingWiringTests.stripComments(try String(contentsOf: url, encoding: .utf8))
    }

    /// The scope reaches the tap and the call reaches the recorder (the shim compiles DictationCore only, so this
    /// reads the app's sources as text).
    /// Mutations: SystemAudioTap.build, `.call` case back to `stereoGlobalTapButExcludeProcesses` -> RED;
    /// MeetingController.start, `callBundleID: callBundleID(for: source)` removed -> RED;
    /// MeetingController.tapScopeChanged, delete the `host.notify(` line -> RED; MeetingRecorder.tapStarted, delete `onTapScope?(scope)` -> RED;
    /// MeetingRecorder.start, delete `watchScope()` -> RED; MeetingRecorder.startTap, `scope: scope` removed from `tap.start` -> RED (does not compile: not counted),
    /// `wantedScope()` replaced by `.global` -> RED.
    func testTheCallsProcessesReachTheTap() throws {
        let tap = try source("SystemAudioTap.swift")
        XCTAssertTrue(tap.contains("case .call(let processes): description = CATapDescription(stereoMixdownOfProcesses:"))
        XCTAssertTrue(tap.contains("case .global: description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)"))
        let controller = try source("MeetingController.swift")
        XCTAssertTrue(controller.contains("callBundleID: callBundleID(for: source)"))
        XCTAssertTrue(controller.contains("recorder.onTapScope = { [weak self] scope in self?.tapScopeChanged(scope) }"))
        let told = try XCTUnwrap(controller.range(of: "private func tapScopeChanged(_ scope: TapScope) {"))
        let toldBody = String(controller[told.upperBound...].prefix(400))
        XCTAssertTrue(toldBody.contains("guard scope == .global else { return }") && toldBody.contains("host.notify(L10nKey.noticeMeetingTapGlobal.text)"),
                      "the fallback is told to the user")
        XCTAssertTrue(controller.contains("liveCall = nil"), "a stopped watcher forgets the call")
        let recorder = try source("MeetingRecorder.swift")
        XCTAssertTrue(recorder.contains("let scope = CallAudioScope.scopeForRebuild(current: tapScope, wanted: wantedScope())"))
        XCTAssertTrue(recorder.contains("onTapScope?(scope)"), "the recorder reports the scope the tap really runs with")
        XCTAssertTrue(recorder.contains("        watchScope()\n"), "the rescan is started with the recording")
        XCTAssertTrue(recorder.contains("CallAudioScope.scope(callBundleID: callBundleID, processes: CoreAudioProps.scopeProcesses() ?? [], ownPID: getpid())"))
        XCTAssertTrue(recorder.contains("CallAudioScope.needsRebuild(current: self.tapScope, wanted: self.wantedScope())"))
    }

    /// The verified list gates the recorder's call, the log line and the outside-playback notice reach the screen (the shim
    /// compiles DictationCore only, so this reads the app's sources as text).
    /// Mutations: MeetingRecorder.start, `CallAudioScope.scopedCall(callBundleID)` -> `callBundleID` -> RED (an unverified app is
    /// scoped); MeetingRecorder.tapStarted, `if callBundleID != nil { onTapScope?(scope) }` -> `onTapScope?(scope)` -> RED (every
    /// unverified recording is told it fell back); delete `logScope(scope)` -> RED; MeetingController.refreshBadge, delete the
    /// `outsidePlayingFor:` argument -> RED; the `.say(.playingOutsideScope)` case's notify -> RED; MeetingController.pollPlaying,
    /// `case .call = scope,` -> `true,` is not testable here (see the pure tests).
    func testTheVerifiedListAndTheOutsideNoticeAreWired() throws {
        let recorder = try source("MeetingRecorder.swift")
        XCTAssertTrue(recorder.contains("self.callBundleID = CallAudioScope.scopedCall(callBundleID)"), "an unverified app is 'no call known'")
        XCTAssertTrue(recorder.contains("self.observedCall = callBundleID"), "the log and the playback diagnostics see the real app")
        XCTAssertTrue(recorder.contains("logScope(scope)"), "every started tap is logged")
        XCTAssertTrue(recorder.contains("if callBundleID != nil { onTapScope?(scope) }"), "only a verified call is told when it falls back")
        let controller = try source("MeetingController.swift")
        XCTAssertTrue(controller.contains("outsidePlayingFor: outsidePlayingSince.map { Date().timeIntervalSince($0) } ?? 0)"))
        XCTAssertTrue(controller.contains("case .say(.playingOutsideScope): host.notify(L10nKey.noticeMeetingTapOutsideScope.text)"))
        XCTAssertTrue(controller.contains("let playback = CallAudioScope.playback(processes: processes, scope: scope, call: recorder.observedCall, ownPID: me)"))
        XCTAssertTrue(controller.contains("if case .call = scope, !playback.outside.isEmpty {"), "only a scoped tap raises the outside-playback timer")
        XCTAssertTrue(controller.contains("log.info(\"system audio: playing outside the call app: "), "the bundle ids outside the scope are logged once")
    }

    /// Both languages say what the notice is about: the call app only, and another app playing.
    /// Mutation: Localizable.strings (en), notice.meeting.tap_outside_scope -> the permission sentence -> RED.
    func testTheOutsideNoticeIsInBothLanguagesAndIsNotThePermissionText() throws {
        let res = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        for (lang, needles) in [("en", ["call app", "another app"]), ("ru", ["приложения звонка", "другое приложение"])] {
            let text = try String(contentsOf: res.appendingPathComponent("\(lang).lproj/Localizable.strings"), encoding: .utf8)
            let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("\"notice.meeting.tap_outside_scope\"") }, lang)
            for needle in needles { XCTAssertTrue(line.contains(needle), "\(lang): \(needle)") }
            XCTAssertFalse(line.contains("Privacy") || line.contains("Конфиденциальность"), "\(lang): it is not about the permission")
        }
    }
}
