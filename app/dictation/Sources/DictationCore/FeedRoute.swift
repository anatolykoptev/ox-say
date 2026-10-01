import Foundation

/// One dictation's path from the recorder to the transcriber: the audio thread
/// yields into a stream, and a single consumer feeds each chunk, in order,
/// tagged with the generation read when the route opened. A route lives for
/// one recording; `close` ends it, and what was not fed by then is the tail of
/// the recording, which `finish(all:)` appends itself.
public final class FeedRoute {
    public let generation: Int
    private let continuation: AsyncStream<[Float]>.Continuation
    private let consumer: Task<Void, Never>

    /// Opens a route for the dictation the transcriber has just begun.
    public init(transcriber: Transcriber) {
        let generation = transcriber.feedGeneration
        let (chunks, continuation) = AsyncStream<[Float]>.makeStream()
        self.generation = generation
        self.continuation = continuation
        consumer = Task {
            for await chunk in chunks {
                if Task.isCancelled { break }
                await transcriber.feed(chunk, generation: generation)
            }
        }
    }

    /// The recorder's sink: callable from the audio thread.
    public var sink: ([Float]) -> Void {
        { [continuation] chunk in continuation.yield(chunk) }
    }

    /// Ends the route: what is still queued is never fed. At most one chunk
    /// that was already past the cancellation check is still fed; it is the
    /// next one in order, so the fed chunks stay a prefix of the recording.
    public func close() {
        continuation.finish()
        consumer.cancel()
    }

    /// Test seam: ends the stream without cancelling, and waits until every
    /// chunk already yielded has been fed.
    func drain() async {
        continuation.finish()
        await consumer.value
    }
}
