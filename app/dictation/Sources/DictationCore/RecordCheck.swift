import Foundation

/// What the Record press on the call prompt checks before it starts (#342.1, #348's option b).
/// A prompt can outlive its call: the badge stays up to `OfferLifetime.callGoneAfter` after the call went,
/// and a browser's hold on the microphone is not a call either (any page holds it, and a muted Meet may
/// release it). Pressing Record on a dead call records silence into a private meeting, so "cannot confirm
/// the call" asks instead of starting — it never refuses: the call may genuinely go on in a place the
/// checks cannot see, and the user has the last word.
public enum RecordCheck {
    /// What a fresh read of the holding browser's tabs answered.
    public enum Tabs: Equatable {
        /// Some tab still reads as a call page.
        case callPage
        /// The read ran and no tab is a call page.
        case noCallPage
        /// It could not answer — denied, timed out, unreadable, no consent: "cannot confirm".
        case unknown
    }

    /// The app that holds the call's microphone.
    public enum Holder: Equatable {
        /// A native call app: there are no tabs to re-read, the offer's staleness is the whole answer.
        case native
        /// A browser: all of its windows' tabs are re-read, never only the front one — the call may
        /// continue in a background tab.
        case browser
    }

    public enum Verdict: Equatable {
        /// Start exactly as the press always did.
        case record
        /// Ask "the call may have ended — record anyway?" first.
        case ask
    }

    /// `offerStale`: `OfferLifetime` would take the prompt down now (the call absent `callGoneAfter`, or
    /// another call live). `tabs`: the all-tab read for a browser holder, ignored for a native one.
    /// Only a live offer AND a visible call page records unasked; every other combination asks.
    public static func decide(offerStale: Bool, holder: Holder, tabs: Tabs) -> Verdict {
        if offerStale { return .ask }
        switch holder {
        case .native: return .record
        case .browser: return tabs == .callPage ? .record : .ask
        }
    }
}

/// What the Record press does with the check's verdict and the user's answer on the badge (#342.1). Pure so
/// that a flipped answer — Cancel recording, Record cancelling a live call — fails a test, not a user.
public enum RecordPrompt {
    /// The badge's question: Record starts exactly as the press always did, Cancel goes back to the prompt.
    public enum Answer: Equatable { case record, cancel }

    public enum Outcome: Equatable {
        /// Start the recording (the offered start).
        case start
        /// Put the question on the badge (no modal alert mid-call).
        case ask
        /// Back to the normal prompt; `OfferLifetime` still takes it down by itself once the call is gone.
        case backToPrompt
    }

    /// `answer` is nil until the badge has asked. Nothing here refuses: only a Cancel the user pressed stops
    /// the start, and a verdict of `.record` never asks.
    public static func outcome(verdict: RecordCheck.Verdict, answer: Answer?) -> Outcome {
        switch (verdict, answer) {
        case (.record, _): return .start
        case (.ask, nil): return .ask
        case (.ask, .record?): return .start
        case (.ask, .cancel?): return .backToPrompt
        }
    }

    /// A browser holder gets its tabs re-read; anything else (a native call app, or no known holder) has
    /// no tabs and only the offer's staleness counts.
    public static func holder(bundleID: String?) -> RecordCheck.Holder {
        guard let bundleID, CallDetector.browsers.contains(bundleID) else { return .native }
        return .browser
    }
}

/// The voices Try Again on a finished meeting: the daemon transcribes it again, so the speaker names the
/// user typed and the notes already written are made again (#340.2). The retry asks before it remakes
/// either; a meeting with neither retries as before.
public enum VoicesRetry {
    /// Whether the retry must be confirmed first. `info` carries the notes (`withTexts`), `speakers` the
    /// typed names. A read that cannot answer is "ask": an unneeded question costs a click, a missed one
    /// loses the edits.
    public static func asksFirst(info: MeetingInfo?, speakers: SpeakersState?) -> Bool {
        guard let info, let speakers else { return true }
        return info.notesMD != nil || speakers.speakers.contains { !$0.name.isEmpty }
    }

    /// Whether the retry goes on. `confirmed` raises the question and is only called when `asks`; a Cancel
    /// (false) stops the retry before anything is sent.
    public static func proceeds(asks: Bool, confirmed: () -> Bool) -> Bool {
        asks ? confirmed() : true
    }
}
