import Foundation

/// One process CoreAudio knows (macOS 14.2+): the object a tap is built from, and who it is.
public struct AudioProcess: Equatable {
    public var objectID: UInt32
    public var pid: Int32
    public var bundleID: String

    public init(objectID: UInt32, pid: Int32, bundleID: String) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
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
    /// Call apps whose sound is played by a system process, not by the app's own: FaceTime hands its audio to
    /// `avconferenced`. Without it the tap on FaceTime's own processes would be silent.
    static let extraBundles: [String: [String]] = [
        "com.apple.FaceTime": ["com.apple.avconferenced"],
    ]

    /// `bundleID` is the call app's (canonical, from `CallDetector`) or one of its helpers: a browser's audio comes
    /// from `com.google.Chrome.helper.*`, not from `com.google.Chrome`. The whole component has to match, so
    /// `com.acme.Chrome2` is not `com.acme.Chrome`.
    static func belongs(_ bundleID: String, toCall call: String) -> Bool {
        if bundleID == call || bundleID.hasPrefix(call + ".") { return true }
        return (extraBundles[call] ?? []).contains(bundleID)
    }

    /// The scope for a call whose app is `callBundleID` (nil: no call is known, as for a recording started by hand
    /// outside a call). OxSay's own processes are never in it. A call with no audio process yet is `.global`: better the
    /// other side and the rest of the Mac than a recording with no other side.
    public static func scope(callBundleID: String?, processes: [AudioProcess], ownPID: Int32) -> TapScope {
        guard let call = callBundleID, !call.isEmpty else { return .global }
        let own = CallDetector.ownBundleID
        let ids = processes
            .filter { $0.pid != ownPID && $0.bundleID != own && !$0.bundleID.hasPrefix(own + ".") && belongs($0.bundleID, toCall: call) }
            .map(\.objectID)
        return ids.isEmpty ? .global : .call(Set(ids))
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
