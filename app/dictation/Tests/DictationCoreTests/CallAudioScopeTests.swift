import Foundation
import XCTest
@testable import DictationCore

/// #530: the "them" channel hears the call's processes, not every app on the Mac.
final class CallAudioScopeTests: XCTestCase {
    private func p(_ id: UInt32, _ pid: Int32, _ bundle: String) -> AudioProcess { AudioProcess(objectID: id, pid: pid, bundleID: bundle) }

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
        XCTAssertEqual(CallAudioScope.scope(callBundleID: "com.google.Chrome", processes: mac, ownPID: 999), .call([10, 11]))
        XCTAssertEqual(CallAudioScope.scope(callBundleID: "us.zoom.xos", processes: mac, ownPID: 999), .call([16]))
    }

    /// Mutation: CallAudioScope.belongs, `hasPrefix(call + ".")` -> `hasPrefix(call)` -> RED (com.google.Chrome2 joins).
    func testALookAlikeBundleIsNotTheCall() {
        XCTAssertEqual(CallAudioScope.scope(callBundleID: "com.google.Chrome", processes: [p(15, 105, "com.google.Chrome2")], ownPID: 1), .global)
    }

    /// OxSay's own sound (a voice it speaks, a sound it plays) never goes into the recording, by pid and by bundle.
    /// Mutation: CallAudioScope.scope, delete the `$0.pid != ownPID` and own-bundle conditions -> RED.
    func testOxSayItselfIsNeverInScope() {
        let own = [p(1, 500, "com.google.Chrome.helper"), p(2, 501, "io.github.anatolykoptev.ox-say.dictation.helper")]
        XCTAssertEqual(CallAudioScope.scope(callBundleID: "com.google.Chrome", processes: own, ownPID: 500), .global,
                       "the only matching process is OxSay's own pid")
        XCTAssertEqual(CallAudioScope.scope(callBundleID: "io.github.anatolykoptev.ox-say.dictation", processes: own, ownPID: 1), .global)
    }

    /// The fallback: no call known, or the call's process not found, is the whole Mac minus OxSay.
    /// Mutation: CallAudioScope.scope, `ids.isEmpty ? .global : ...` -> `.call(Set(ids))` -> RED (a tap on nothing).
    func testNoCallOrNoProcessFallsBackToGlobal() {
        XCTAssertEqual(CallAudioScope.scope(callBundleID: nil, processes: mac, ownPID: 999), .global)
        XCTAssertEqual(CallAudioScope.scope(callBundleID: "", processes: mac, ownPID: 999), .global)
        XCTAssertEqual(CallAudioScope.scope(callBundleID: "com.microsoft.teams2", processes: mac, ownPID: 999), .global)
        XCTAssertEqual(CallAudioScope.scope(callBundleID: "us.zoom.xos", processes: [], ownPID: 999), .global)
    }

    /// FaceTime's sound is played by a system daemon.
    /// Mutation: CallAudioScope.extraBundles, delete the FaceTime entry -> RED.
    func testFaceTimeIncludesItsAudioDaemon() {
        let ft = [p(1, 10, "com.apple.FaceTime"), p(2, 11, "com.apple.avconferenced"), p(3, 12, "com.apple.Music")]
        XCTAssertEqual(CallAudioScope.scope(callBundleID: "com.apple.FaceTime", processes: ft, ownPID: 999), .call([1, 2]))
        XCTAssertEqual(CallAudioScope.scope(callBundleID: "us.zoom.xos", processes: ft, ownPID: 999), .global, "the daemon is FaceTime's only")
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
        XCTAssertTrue(recorder.contains("CallAudioScope.scope(callBundleID: callBundleID, processes: processes, ownPID: getpid())"))
        XCTAssertTrue(recorder.contains("CallAudioScope.needsRebuild(current: self.tapScope, wanted: self.wantedScope())"))
    }
}
