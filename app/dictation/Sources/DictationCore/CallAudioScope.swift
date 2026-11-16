import Foundation

/// One process CoreAudio knows (macOS 14.2+): the object a tap is built from, and who it is.
public struct AudioProcess: Equatable {
    public var objectID: UInt32
    public var pid: Int32
    /// Empty when CoreAudio has none for the process (a system daemon such as FaceTime's `avconferenced` may report an
    /// empty id); such a process matches no call app.
    public var bundleID: String
    /// The process has audio output running right now.
    public var runningOutput: Bool

    public init(objectID: UInt32, pid: Int32, bundleID: String, runningOutput: Bool = false) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.runningOutput = runningOutput
    }
}

/// What the "them" channel listens to (#530).
public enum TapScope: Equatable {
    /// Only these audio processes: the call app and its helpers, mixed down.
    case call(Set<UInt32>)
    /// Every process on the Mac except OxSay itself. This is the fallback when the call's process cannot be found, and
    /// it records music, a video or a notification sound playing in any other app.
    case global
}

/// Which processes belong to the call, and when the tap must be built again. Pure: the CoreAudio reads and the tap
/// itself are the app's.
public enum CallAudioScope {
    /// The call apps whose per-app scope has been VERIFIED on a real call: the app's far side really plays from a process
    /// under this bundle id (or `extraBundles`), so a tap on those processes records it. EMPTY on purpose: no app has
    /// been checked yet, and a wrong scope records no far side at all and says nothing. Every app that is not listed
    /// keeps the whole-Mac tap (minus OxSay), as before per-app scoping existed.
    ///
    /// To add an app: run the live matrix in the pull request that introduced this list (#608) for that app on a real
    /// call, with the scope forced on in a local build; when every row passes, add its canonical bundle id (the one
    /// `CallDetector` reports, e.g. `us.zoom.xos`) here, in the same change as a pass note in the PR, and update
    /// `testNoAppIsVerifiedYet` to the new list. Do not add an app on a guess.
    public static let verifiedScopedApps: Set<String> = []

    /// `call` when it is on the verified list (case-insensitive), else nil: an unverified app is handled exactly like
    /// "no call known", so it gets the whole-Mac tap, no fallback notice and no rescan timer.
    public static func scopedCall(_ call: String?, verified: Set<String> = verifiedScopedApps) -> String? {
        guard let call, !call.isEmpty else { return nil }
        let wanted = call.lowercased()
        return verified.contains { $0.lowercased() == wanted } ? call : nil
    }

    /// Call apps whose sound is played by a system process, not by the app's own: FaceTime hands its audio to
    /// `avconferenced`. Without it the tap on FaceTime's own processes would be silent.
    static let extraBundles: [String: [String]] = [
        "com.apple.FaceTime": ["com.apple.avconferenced"],
    ]

    /// `bundleID` is the call app's (canonical, from `CallDetector`) or one of its helpers: a browser's audio comes
    /// from `com.google.Chrome.helper.*`, not from `com.google.Chrome`. The whole component has to match, so
    /// `com.acme.Chrome2` is not `com.acme.Chrome`.
    /// Bundle ids are compared without regard to case: macOS treats them so, and a helper registered as `COM.Google.Chrome`
    /// is still Chrome's.
    static func belongs(_ bundleID: String, toCall call: String) -> Bool {
        let id = bundleID.lowercased()
        let app = call.lowercased()
        if id == app || id.hasPrefix(app + ".") { return true }
        return extraBundles.contains { entry in
            entry.key.lowercased() == app && entry.value.contains { $0.lowercased() == id }
        }
    }

    private static func isOwn(_ bundleID: String) -> Bool { belongs(bundleID, toCall: CallDetector.ownBundleID) }

    /// The scope for a call whose app is `callBundleID` (nil: no call is known, as for a recording started by hand
    /// outside a call). OxSay's own processes are never in it. A call with no audio process yet is `.global`: better the
    /// other side and the rest of the Mac than a recording with no other side.
    ///
    /// Only a call on the verified list (`verifiedScopedApps`, empty until an app has been checked live) gets a scoped tap;
    /// any other is `.global`, whatever its processes look like.
    public static func scope(callBundleID: String?, processes: [AudioProcess], ownPID: Int32,
                             verified: Set<String> = verifiedScopedApps) -> TapScope {
        guard let call = scopedCall(callBundleID, verified: verified) else { return .global }
        let ids = matched(call: call, processes: processes, ownPID: ownPID).map(\.objectID)
        return ids.isEmpty ? .global : .call(Set(ids))
    }

    /// The processes that belong to `call` (OxSay's own never do), whether or not the tap is built from them.
    static func matched(call: String, processes: [AudioProcess], ownPID: Int32) -> [AudioProcess] {
        processes.filter { $0.pid != ownPID && !isOwn($0.bundleID) && belongs($0.bundleID, toCall: call) }
    }

    /// What is playing, for the silent-tap judgement and the diagnostics. `inScope`: something the tap hears is playing
    /// (the call's processes when the tap is scoped; any process but OxSay's when it is the whole Mac). `outside`: the
    /// bundle ids of the processes that play and are not the call's, OxSay excluded (`<none>` for a process without an
    /// id). `call` is the call app as the watcher saw it, verified or not: for a whole-Mac tap it names what a per-app scope
    /// would have left out.
    public struct Playback: Equatable {
        public var inScope: Bool
        public var outside: [String]
    }

    public static func playback(processes: [AudioProcess], scope: TapScope, call: String?, ownPID: Int32) -> Playback {
        let playing = processes.filter { $0.runningOutput && $0.pid != ownPID && !isOwn($0.bundleID) }
        let inScope: Bool
        let outside: [AudioProcess]
        switch scope {
        case .call(let ids):
            inScope = playing.contains { ids.contains($0.objectID) }
            outside = playing.filter { !ids.contains($0.objectID) }
        case .global:
            inScope = !playing.isEmpty
            if let call, !call.isEmpty {
                outside = playing.filter { !belongs($0.bundleID, toCall: call) }
            } else {
                outside = []
            }
        }
        return Playback(inScope: inScope, outside: names(outside))
    }

    /// One line for the public log at a tap start and each rebuild: which scope the tap runs with and the bundle ids it
    /// matched. Bundle ids only, no content. `observed` is the call app as the watcher saw it (nil: none), `verified`
    /// whether it is on the verified list; with a whole-Mac tap, `matched` is what a per-app scope would have taken.
    public static func describe(scope: TapScope, observed: String?, processes: [AudioProcess], ownPID: Int32,
                                verified: Set<String> = verifiedScopedApps) -> String {
        let call = (observed?.isEmpty == false) ? observed : nil
        let listed = scopedCall(call, verified: verified) != nil
        let matchedIDs = call.map { names(matched(call: $0, processes: processes, ownPID: ownPID)) } ?? []
        func list(_ ids: [String]) -> String { ids.isEmpty ? "<none>" : ids.joined(separator: ",") }
        switch scope {
        case .call(let ids):
            let used = names(processes.filter { ids.contains($0.objectID) })
            return "scope=call call=\(call ?? "<none>") tap=\(list(used))"
        case .global:
            let why = call == nil ? "no call known" : (listed ? "no process of the call found" : "call app not on the verified list")
            return "scope=global (\(why)) call=\(call ?? "<none>") matched=\(list(matchedIDs))"
        }
    }

    /// Sorted, unique bundle ids, `<none>` for a process without one.
    static func names(_ processes: [AudioProcess]) -> [String] {
        Array(Set(processes.map { $0.bundleID.isEmpty ? "<none>" : $0.bundleID })).sorted()
    }

    /// Whether the running tap has to be replaced by one with `wanted`. A call process that appeared (a browser's new
    /// audio helper, the app opening its audio late) is added; the scope never widens on its own — a call whose
    /// processes all went away keeps its tap rather than turning into a recording of the whole Mac — and the fallback
    /// is left for the call's processes as soon as they exist.
    public static func needsRebuild(current: TapScope, wanted: TapScope) -> Bool {
        switch (current, wanted) {
        case (.global, .global): return false
        case (.global, .call): return true
        case (.call, .global): return false
        case (.call(let have), .call(let want)): return !want.isSubset(of: have)
        }
    }

    /// The scope to build the tap with when it is (re)built for any reason, a route change included: the one the call's
    /// processes now give, except that a tap on the call never falls back to the whole Mac because its processes
    /// vanished for a moment or CoreAudio failed to list them. The old set is kept; a rebuild that cannot use it fails and
    /// leaves the running tap in place.
    public static func scopeForRebuild(current: TapScope, wanted: TapScope) -> TapScope {
        if case .call = current, wanted == .global { return current }
        return wanted
    }
}
