import Foundation

/// Streams a recording into a daemon transcription session while it is still
/// being made: every full chunk is decoded in the background, so at release
/// only the tail remains. On the first failure of any session call it falls
/// back to the one-shot upload in TranscriptionClient — which is also how a
/// daemon too old for sessions (404/405 on create) is handled.
///
/// `feed` runs on the audio thread. All state lives under one lock so chunk
/// order is the recording order end to end, and a single pump task does the
/// sending, so at most one request is in flight at a time.
public final class StreamingTranscriber: Transcriber, @unchecked Sendable {
    /// Samples per audio request: 0.5 s at 16 kHz, under the server's 30 s cap.
    public static let chunkSamples = 8000

    private let sessions: SessionClient
    private let oneShot: TranscriptionClient
    /// The committed text so far, on the main actor. Set once, before `begin`.
    public var onText: (@MainActor (String) -> Void)?

    private let lock = NSLock()
    /// Bumped by `begin`: work started under an older generation is dropped,
    /// like DictationController's generation.
    private var generation = 0
    private var id: String?
    private var createTask: Task<String, Error>?
    private var unsent: [Float] = []
    /// Segment texts decoded so far, trimmed.
    private var committed: [String] = []
    private var sending = false
    private var finishing = false
    private var fallback = false
    private var cancelled = false
    /// Samples appended to `unsent` this generation; `finish` reconciles it
    /// against the recording, since `feed` rides an AsyncStream that can lag.
    private var accepted = 0
    /// finish() waiters: true = everything sent, false = fell back or cancelled.
    private var drainWaiters: [CheckedContinuation<Bool, Never>] = []
    /// When `begin` ran, and how long its session create took once it landed.
    private var beganAt: UInt64 = 0
    private var createMs: Int?
    /// What the current dictation's `finish` saw at the release, and how it ended.
    private var stats = TranscriberStats(path: .stream)

    /// How the last `finish` was served: the session, or the re-upload after
    /// a failure, plus what was still unsent at the release.
    public var finishStats: TranscriberStats { lock.withLock { stats } }

    /// The tag `feed` requires, minted by `begin`: read it once per dictation
    /// and hand it to every chunk that dictation records.
    public var feedGeneration: Int { lock.withLock { generation } }

    /// Test seam: the pump's in-flight flag, read under the lock, so tests can
    /// await quiescence instead of sleeping.
    var pumpSending: Bool { lock.withLock { sending } }
    /// Test seam: samples `feed` accepted for the current dictation.
    var acceptedCount: Int { lock.withLock { accepted } }
    /// Test seam: drain waiters currently queued in `waitForDrain`.
    var pendingDrainWaiters: Int { lock.withLock { drainWaiters.count } }

    public init(baseURL: URL,
                send: @escaping TranscriptionClient.Send = { try await URLSession.shared.data(for: $0) }) {
        sessions = SessionClient(baseURL: baseURL, send: send)
        oneShot = TranscriptionClient(baseURL: baseURL, send: send)
    }

    /// A new dictation: start creating the session now so the id is ready by
    /// the time the first whole chunk is; samples fed before it lands buffer.
    public func begin() {
        let (staleID, create, g) = lock.withLock {
            generation += 1
            let g = generation
            let staleID = id
            id = nil
            unsent.removeAll(keepingCapacity: true)
            committed.removeAll()
            accepted = 0
            beganAt = DispatchTime.now().uptimeNanoseconds
            createMs = nil
            stats = TranscriberStats(path: .stream)
            finishing = false
            fallback = false
            cancelled = false
            resumeWaitersLocked(false)
            let create = Task { [sessions] in try await sessions.create() }
            createTask = create
            return (staleID, create, g)
        }
        if let staleID { Task { [sessions] in try? await sessions.delete(id: staleID) } }
        // The create can resolve after cancel() or the next begin(): the
        // watcher hands a still-live session to the pump and deletes a dead one.
        Task { [weak self] in
            do {
                self?.createArrived(try await create.value, generation: g)
            } catch {
                self?.createFailed(generation: g)
            }
        }
    }

    /// The tag is fixed when the chunk is recorded (`feedGeneration` of that
    /// dictation), so a chunk still queued in a finished stream — or a feed
    /// suspended across `begin()` — is checked against the live generation
    /// here, under the lock, and dropped instead of entering the next
    /// dictation's session.
    public func feed(_ samples: [Float], generation g: Int) async {
        lock.withLock {
            // Once finish() reconciled the recording into `unsent`, a late
            // chunk can only duplicate the appended tail or be foreign audio;
            // buffering it would let the pump's finishing-drain send it.
            guard g == generation, !cancelled, !finishing else { return }
            unsent.append(contentsOf: samples)
            accepted += samples.count
            kickPumpLocked()
        }
    }

    /// The recording is over: drain what is still queued (bounded at 10 s),
    /// send the partial tail and finish the session for its text. Any failure
    /// — or a fallback that already happened — means the whole recording goes
    /// through the one-shot upload instead.
    public func finish(all: [Float]) async throws -> String {
        enum Step { case cancelled, upload, wait }
        let (step, g) = lock.withLock { () -> (Step, Int) in
            if cancelled { return (.cancelled, generation) }
            finishing = true
            // `feed` can lag the recorder: a tail still in its AsyncStream is
            // missing from the session — take it straight from `all`. More
            // accepted than recorded means foreign audio (e.g. the previous
            // recording's tail fed after this begin): the session can never
            // match `all`, so it is dropped and the recording re-uploaded.
            if accepted < all.count {
                unsent.append(contentsOf: all[accepted...])
                accepted = all.count
            } else if accepted > all.count {
                enterFallbackLocked()
            }
            // What the release left to do: the unsent audio, against what
            // the session had already decoded while the key was held.
            stats = TranscriberStats(path: .stream, sessionCreateMs: createMs,
                                     segmentsBeforeRelease: committed.count,
                                     tailSeconds: Double(unsent.count) / 16000)
            kickPumpLocked()
            return (fallback || (id == nil && createTask == nil) ? .upload : .wait,
                    generation)
        }
        if step == .cancelled { throw CancellationError() }
        if step == .wait {
            let drained = await waitForDrain(g)
            let (dead, canStream, sid) = lock.withLock {
                let dead = cancelled || generation != g
                return (dead, drained && !dead && !fallback, id)
            }
            if dead { throw CancellationError() }
            if canStream, let sid {
                do {
                    let text = try await sessions.finish(id: sid)
                    // Forget the session: the next begin() must not DELETE a
                    // finished one, and nothing may POST to it again.
                    lock.withLock { if generation == g { id = nil } }
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    lock.withLock { if generation == g { enterFallbackLocked() } }
                }
            }
        }
        // Esc during the drain or the session finish lands here: a dead
        // dictation must not upload.
        let dead = lock.withLock { () -> Bool in
            if cancelled || generation != g { return true }
            stats.path = .fallback
            return false
        }
        if dead { throw CancellationError() }
        return try await oneShot.transcribe(all)
    }

    /// Esc: stop all sending and drop the session best-effort. A create still
    /// in flight resolves into the watcher's stale-generation branch, which
    /// deletes it, so no session is left open either way.
    public func cancel() {
        let staleID = lock.withLock { () -> String? in
            if cancelled { return nil }
            cancelled = true
            defer {
                id = nil
                createTask = nil
                resumeWaitersLocked(false)
            }
            return id
        }
        if let staleID { Task { [sessions] in try? await sessions.delete(id: staleID) } }
    }

    /// The create returned an id: start pumping, unless the dictation died or
    /// was superseded meanwhile — in which case the session is deleted unused.
    private func createArrived(_ newID: String, generation g: Int) {
        let alive = lock.withLock { () -> Bool in
            guard generation == g, !cancelled, !fallback else { return false }
            id = newID
            createTask = nil
            createMs = Int((DispatchTime.now().uptimeNanoseconds - beganAt) / 1_000_000)
            // A cold server's create can land after the release: the stats
            // snapshot finish() took must still carry how long it took.
            if finishing { stats.sessionCreateMs = createMs }
            kickPumpLocked()
            // A finish() waiter with nothing sendable (empty buffer) never gets
            // a pump to resume it; decide the drain here instead.
            if !sending { resumeWaitersLocked(unsent.isEmpty) }
            return true
        }
        if !alive {
            Task { [sessions] in try? await sessions.delete(id: newID) }
        }
    }

    private func createFailed(generation g: Int) {
        lock.withLock {
            if generation == g, !cancelled {
                createTask = nil
                enterFallbackLocked()
            }
        }
    }

    /// The first failure ends streaming: stop sending, wake finish(), and drop
    /// the session best-effort. Every later feed only buffers. The lock is held.
    private func enterFallbackLocked() {
        if fallback { return }
        fallback = true
        resumeWaitersLocked(false)
        if let id {
            self.id = nil
            Task { [sessions] in try? await sessions.delete(id: id) }
        }
    }

    /// Starts the single send loop if there is sendable work. The lock is held.
    private func kickPumpLocked() {
        guard !sending, !fallback, !cancelled, id != nil,
              unsent.count >= Self.chunkSamples || (finishing && !unsent.isEmpty) else { return }
        sending = true
        let g = generation
        Task { [weak self] in await self?.pump(g) }
    }

    /// Sends chunks strictly in order, one request in flight, until the buffer
    /// cannot fill a chunk (only the tail, and only once `finish` asked for it).
    private func pump(_ g: Int) async {
        while true {
            let next = lock.withLock { () -> (id: String, chunk: [Float])? in
                guard generation == g, !fallback, !cancelled, let id,
                      unsent.count >= Self.chunkSamples || (finishing && !unsent.isEmpty) else {
                    return nil
                }
                return (id, Array(unsent[..<min(Self.chunkSamples, unsent.count)]))
            }
            guard let (sid, chunk) = next else {
                lock.withLock {
                    sending = false
                    kickPumpLocked()  // hand off to a newer generation's pending work
                    // Drain waiters always belong to the current generation —
                    // a supersede or cancel resumed the stale ones — so the
                    // verdict is judged on live state, not this pump's g; a
                    // create still in flight gets to resolve the drain itself.
                    if !sending && createTask == nil {
                        resumeWaitersLocked(!fallback && !cancelled && unsent.isEmpty)
                    }
                }
                return
            }
            do {
                let reply = try await sessions.audio(id: sid, pcm: Self.pcm(chunk))
                let text = lock.withLock { () -> String? in
                    guard generation == g, !fallback, !cancelled else { return nil }
                    unsent.removeFirst(chunk.count)
                    for t in reply.texts {
                        let t = t.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { committed.append(t) }
                    }
                    return committed.joined(separator: " ")
                }
                if let text { await onText?(text) }
            } catch {
                lock.withLock { if generation == g { enterFallbackLocked() } }
            }
        }
    }

    /// Waits until the queue is drained or the session is dead, bounded at
    /// 10 s: past that the drain counts as a failure and finish falls back.
    private func waitForDrain(_ g: Int) async -> Bool {
        await withCheckedContinuation { cont in
            let decided = lock.withLock { () -> Bool? in
                if generation != g || cancelled || fallback { return false }
                if !sending && unsent.isEmpty && id != nil { return true }
                drainWaiters.append(cont)
                return nil
            }
            if let decided {
                cont.resume(returning: decided)
            } else {
                // Strong self: the continuation must be resumed even if the
                // transcriber is otherwise unreferenced.
                Task { [self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    drainTimedOut(g)
                }
            }
        }
    }

    private func drainTimedOut(_ g: Int) {
        lock.withLock {
            if generation == g, !drainWaiters.isEmpty { enterFallbackLocked() }
        }
    }

    /// The lock is held.
    private func resumeWaitersLocked(_ drained: Bool) {
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for w in waiters { w.resume(returning: drained) }
    }

    /// Little-endian float32 mono PCM; every macOS host is little-endian.
    private static func pcm(_ chunk: [Float]) -> Data {
        chunk.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
