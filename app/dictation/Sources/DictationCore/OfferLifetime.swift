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
    /// microphone when it is muted); it goes down once the call has been gone this long. Its own number, not the
    /// tracker's auto-stop (`CallTracker.endAfter`, which happens to be 90 s too): the two answer different questions
    /// (how long a stale question may stay up; how long silence ends a recording) and must be tunable apart. Going down
    /// withdraws the offer (see `Reason.withdrawsOffer`), so a call that returns is asked about again.
    public static let callGoneAfter: TimeInterval = 90

    public enum Verdict: Equatable {
        case keep
        case hide(Reason)
    }

    public enum Reason: Equatable {
        /// The call has been gone for `callGoneAfter`.
        case callGone
        /// Another call took over: the question is about the wrong one.
        case otherCall
        /// The consent question's browser released the microphone.
        case browserReleased

        /// The question went down without an answer from the user, about a call that may well return: the tracker must
        /// forget it asked, so the returning call is offered again. Not for `otherCall` (the tracker's episode is the
        /// other call's by now) or the consent question (no episode).
        public var withdrawsOffer: Bool { self == .callGone }
    }

    private var absentSince: Date?

    public init() {}

    /// Calls and consent questions are only raised while the global mode watches for calls.
    public static func offersAllowed(mode: CallGlobalMode) -> Bool { mode != .off }

    /// Would the next poll take this `.prompt` offer down — the call absent for `callGoneAfter`, or another
    /// call live? The Record press asks this (#342.1): a peek, not a verdict — `absentSince` is read, never
    /// moved, and a non-prompt offer is never stale for it.
    public func stale(now: Date, offer: Offer, liveSource: String?) -> Bool {
        guard case .prompt(let source) = offer else { return false }
        if liveSource == source { return false }
        if liveSource != nil { return true }
        guard let absentSince else { return false }
        return now.timeIntervalSince(absentSince) >= Self.callGoneAfter
    }

    /// One poll. `liveSource` is the call the watcher sees now (nil = none; a browser call counts while its browser
    /// holds the microphone, whichever tab is in front, #241), `users` the microphone holders. `.hide` when the badge's `offer` must come down, with why.
    public mutating func verdict(now: Date, offer: Offer?, liveSource: String?, users: [MicUser]) -> Verdict {
        guard let offer else { absentSince = nil; return .keep }
        switch offer {
        case .browserConsent(let id):
            absentSince = nil
            return CallDetector.holds(users, bundleID: id) ? .keep : .hide(.browserReleased)
        case .prompt(let source):
            if liveSource == source { absentSince = nil; return .keep }
            // Another call took over: this question is about the wrong one.
            if liveSource != nil { absentSince = nil; return .hide(.otherCall) }
            let since = absentSince ?? now
            absentSince = since
            guard now.timeIntervalSince(since) >= Self.callGoneAfter else { return .keep }
            absentSince = nil
            return .hide(.callGone)
        }
    }
}
