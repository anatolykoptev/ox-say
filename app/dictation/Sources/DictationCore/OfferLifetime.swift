import Foundation

/// How long the badge's questions stay up. The detected-call prompt and the Automation-consent question each
/// belong to something that can end — a call, a browser's hold on the microphone, the "when a call starts" mode —
/// and a question that outlives it is stale. The app target only draws; this decides when to take them down.
public struct OfferLifetime {
    public enum Offer: Equatable {
        /// "<App> call — record it?" for this call source.
        case prompt(source: String)
        /// "A call in <Browser>? …Allow…" for this browser bundle id.
        case browserConsent(browser: String)
    }

    /// A question about a call stays up through a short microphone dropout (Meet in Chrome may release the
    /// microphone when it is muted); it goes down once the call has been gone as long as the tracker needs to
    /// call the episode over and offer the next one afresh.
    public static let callGoneAfter: TimeInterval = CallTracker.endAfter

    private var absentSince: Date?

    public init() {}

    /// Calls and consent questions are only raised while the global mode watches for calls.
    public static func offersAllowed(mode: CallGlobalMode) -> Bool { mode != .off }

    /// One poll. `liveSource` is the call the watcher sees now (nil = none), `users` the microphone holders.
    /// True when the badge's `offer` must come down.
    public mutating func shouldHide(now: Date, offer: Offer?, liveSource: String?, users: [MicUser]) -> Bool {
        guard let offer else { absentSince = nil; return false }
        switch offer {
        case .browserConsent(let id):
            absentSince = nil
            return !CallDetector.holds(users, bundleID: id)
        case .prompt(let source):
            if liveSource == source { absentSince = nil; return false }
            // Another call took over: this question is about the wrong one.
            if liveSource != nil { absentSince = nil; return true }
            let since = absentSince ?? now
            absentSince = since
            return now.timeIntervalSince(since) >= Self.callGoneAfter
        }
    }
}
