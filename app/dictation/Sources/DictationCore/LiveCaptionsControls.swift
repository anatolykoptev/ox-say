import Foundation

/// What a click on the recording plate opens. The plate is shown only while a recording runs, but the recording can
/// stop between the draw and the click: then the Meetings list opens, never a crash and never a page for a meeting
/// that is not being recorded.
public enum PlateClick {
    public static func route(recordingID: String?) -> MainRoute {
        guard let id = recordingID, !id.isEmpty else { return MainRoute(section: .meetings, clearsSelection: true) }
        return MainRoute(section: .meetings, meetingID: id)
    }
}

/// The line under the recording's row in the Meetings list: its last live caption.
public enum MeetingRowCaption {
    /// One row line, so a long caption is cut here (the view then truncates to the width it has).
    public static let maxCharacters = 160

    /// nil when the row looks as it always did: the meeting is not recording, captions are off in the daemon, or no
    /// line has arrived yet. The text is shown, never logged.
    public static func line(info: MeetingInfo, feed: LiveFeed?) -> String? {
        guard info.status == .recording, let feed, feed.state?.enabled != false, let last = feed.captions.last else { return nil }
        let flat = last.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        guard flat.count > maxCharacters else { return flat }
        return String(flat.prefix(maxCharacters - 1)) + "…"
    }
}

/// Saves of the live-captions switch, one at a time. A quick off then on must not be two PUTs the daemon may apply in
/// either order: while a save runs the newest intent waits, and is sent when it ends, so the last thing the daemon takes
/// is the last thing the user chose. `finished` fires once, when nothing is left to send.
@MainActor
public final class LiveCaptionsSaveQueue {
    public enum Outcome: Equatable {
        /// The value the daemon took last.
        case saved(Bool)
        /// The sentence for the user; the last send failed.
        case failed(String)
    }

    /// What a settings read started with; `isStale` says whether an edit has overtaken it since.
    public struct ReadToken: Equatable {
        fileprivate let edits: Int
        fileprivate let busy: Bool
    }

    private let send: (Bool) async -> String?
    private let finished: (Outcome) -> Void
    private var latest: Bool?
    private var task: Task<Void, Never>?
    public private(set) var busy = false
    private var edits = 0

    public init(send: @escaping (Bool) async -> String?, finished: @escaping (Outcome) -> Void) {
        self.send = send
        self.finished = finished
    }

    public func submit(_ on: Bool) {
        edits += 1
        latest = on
        guard !busy else { return }
        busy = true
        task = Task { await drain() }
    }

    /// Returns when nothing is being saved.
    public func idle() async { await task?.value }

    private func drain() async {
        var outcome: Outcome?
        while let next = latest {
            latest = nil
            if let failure = await send(next) { outcome = .failed(failure) } else { outcome = .saved(next) }
        }
        busy = false
        if let outcome { finished(outcome) }
    }

    public func beginRead() -> ReadToken { ReadToken(edits: edits, busy: busy) }

    /// A read that began while a save ran, or before an edit, or that ends while one runs, may carry the value from before it.
    public func isStale(_ token: ReadToken) -> Bool { token.busy || busy || token.edits != edits }
}
