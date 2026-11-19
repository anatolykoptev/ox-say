import Foundation

/// Why an owner-only call of the model-access endpoint was not made, or was refused as not the owner's. The key of
/// the endpoint, its rotation and turning it on are the owner's: the daemon wants the bearer it keeps in
/// `owner.token`, the same one the Glossary page sends.
public enum LLMEndpointOwnerError: Error, Equatable, UserFacingError {
    /// `owner.token` is missing or unreadable: nothing was sent.
    case tokenMissing
    /// The daemon answered 401: the token on disk is not the one it holds (regenerated, or another home).
    case denied

    public var userText: String {
        switch self {
        case .tokenMissing: return L10nKey.settingsLLMEndpointOwnerMissing.text
        case .denied: return L10nKey.settingsLLMEndpointOwnerDenied.text
        }
    }
}

/// "New key" taps, one at a time. Every rotation invalidates the previous key at the daemon, so only the LAST answer
/// is the key in force: while a rotation runs a further tap waits, and runs after it, and only the final answer is
/// handed to `finished` — a late response to an earlier tap can never show a stale key. A settings read that began
/// before or during a rotation is stale too (`beginRead` / `isStale`), the same shape as the live-captions queue.
/// `finished` fires once, when nothing is left to send.
@MainActor
public final class LLMEndpointKeyQueue {
    public struct ReadToken: Equatable {
        fileprivate let taps: Int
        fileprivate let busy: Bool
    }

    private let send: () async throws -> String
    private let finished: (Result<String, Error>) -> Void
    private var pending = false
    private var taps = 0
    public private(set) var busy = false
    private var task: Task<Void, Never>?

    public init(send: @escaping () async throws -> String, finished: @escaping (Result<String, Error>) -> Void) {
        self.send = send
        self.finished = finished
    }

    public func regenerate() {
        taps += 1
        pending = true
        guard !busy else { return }
        busy = true
        task = Task { await drain() }
    }

    /// Returns when nothing is being sent.
    public func idle() async { await task?.value }

    private func drain() async {
        var last: Result<String, Error>?
        while pending {
            pending = false
            do { last = .success(try await send()) } catch { last = .failure(error) }
        }
        busy = false
        if let last { finished(last) }
    }

    public func beginRead() -> ReadToken { ReadToken(taps: taps, busy: busy) }

    /// A key read that began while a rotation ran, or before a tap, or that ends while one runs, may be the old key.
    public func isStale(_ token: ReadToken) -> Bool { token.busy || busy || token.taps != taps }
}
