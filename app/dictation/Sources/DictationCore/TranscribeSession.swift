import Foundation

/// The daemon calls the Расшифровка page makes, as closures so a test drives the session without a daemon.
public struct TranscribeOps {
    public var list: () async throws -> [TranscriptEntry]
    /// The file, its title, its duration in seconds when known.
    public var transcribe: (URL, String, Double?) async throws -> TranscriptEntry
    public var text: (String, TranscriptFormat) async throws -> Data
    public var delete: (String) async throws -> Void
    /// The recording's duration, measured locally; nil when it cannot be (the upload timeout then has its floor).
    public var duration: (URL) async -> Double?

    public init(list: @escaping () async throws -> [TranscriptEntry],
                transcribe: @escaping (URL, String, Double?) async throws -> TranscriptEntry,
                text: @escaping (String, TranscriptFormat) async throws -> Data,
                delete: @escaping (String) async throws -> Void,
                duration: @escaping (URL) async -> Double? = { _ in nil }) {
        self.list = list
        self.transcribe = transcribe
        self.text = text
        self.delete = delete
        self.duration = duration
    }
}

/// A transcript in one format, ready to be written where the person chose.
public struct TranscriptFile: Equatable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    public func write(to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// What the save panel's answer means: nil when the person cancelled (nothing to say), otherwise whether the file was
    /// written. A cancel is not a failure.
    public func finishSave(confirmed: Bool, url: URL?) -> Bool? {
        guard confirmed, let url else { return nil }
        do {
            try write(to: url)
            return true
        } catch {
            return false
        }
    }
}

/// The Расшифровка page's decisions. The app copies the result into the window's values.
///
/// - a failed read is `load = .failed`, never an empty list, and keeps the list already shown;
/// - one file at a time; a file that is too big or not media never starts an upload;
/// - a failed upload changes nothing but the sentence it returns;
/// - a list read that began before an upload (or a delete) landed is stale and is dropped.
@MainActor
public final class TranscribeSession {
    public private(set) var entries: [TranscriptEntry] = []
    public private(set) var load: TranscribeLoad = .loading
    /// The title of the file being transcribed; nil when none is.
    public private(set) var working: String?
    public private(set) var selectedID: String?
    /// Called after every change of the above, also in the middle of an upload.
    public var onChange: () -> Void = {}

    private let ops: TranscribeOps
    private let limits: () -> TranscribeLimits
    private let text: (L10nKey) -> String
    /// Counts every change of what a list read may still show: a read applies only if no change came after it began.
    private var epoch = 0

    public init(ops: TranscribeOps, limits: @escaping () -> TranscribeLimits = { .fallback },
                text: @escaping (L10nKey) -> String = { $0.text }) {
        self.ops = ops
        self.limits = limits
        self.text = text
    }

    public var pageState: TranscribePageState {
        TranscribePageState.of(load: load, hasItems: !entries.isEmpty, working: working)
    }

    public func sentence(_ error: Error) -> String { StudioError.plain(error, text: text) }

    /// Reads the list again.
    public func reload() async {
        epoch += 1
        let mine = epoch
        do {
            let list = try await ops.list()
            guard mine == epoch else { return }
            entries = list
            if let selectedID, !list.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
            load = .loaded
        } catch {
            guard mine == epoch else { return }
            load = .failed(sentence(error))
        }
        onChange()
    }

    public func select(_ id: String?) {
        selectedID = id
        onChange()
    }

    /// Transcribes the file. Returns the sentence to show when it did not go through; nil when it did.
    public func submit(_ url: URL, bytes: Int64) async -> String? {
        if working != nil { return text(.transcribeBusy) }
        if let problem = TranscribeFileCheck.problem(bytes: bytes, ext: url.pathExtension, limit: limits().maxBytes, text: text) { return problem }
        let title = TranscribeFileCheck.title(fromFileName: url.deletingPathExtension().lastPathComponent)
        working = title
        onChange()
        defer {
            working = nil
            onChange()
        }
        let seconds = await ops.duration(url)
        do {
            let entry = try await ops.transcribe(url, title, seconds)
            epoch += 1
            entries.removeAll { $0.id == entry.id }
            entries.insert(entry, at: 0)
            selectedID = entry.id
            load = .loaded
            return nil
        } catch {
            return sentence(error)
        }
    }

    /// The transcript in `format`, named after its title.
    public func file(id: String, format: TranscriptFormat) async throws -> TranscriptFile {
        let data = try await ops.text(id, format)
        let title = entries.first { $0.id == id }?.title ?? ""
        return TranscriptFile(name: format.fileName(forTitle: title, fallback: text(.transcribeDefaultName)), data: data)
    }

    /// Deletes the transcript. Returns the sentence to show when it did not go through.
    public func delete(id: String) async -> String? {
        do {
            try await ops.delete(id)
        } catch {
            return sentence(error)
        }
        epoch += 1
        entries.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        onChange()
        return nil
    }
}
