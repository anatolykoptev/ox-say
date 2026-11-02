import FluidAudio
import Foundation
import OxDiarCore

/// The Nemotron 3 Diarization engine: probabilities for the whole recording, streamed in 30 s chunks over a
/// mapped source — frame-exact with the one-shot path and flat in memory on multi-hour audio (the Task 0
/// probe), where reading a call into one [Float] would cost ~230 MB per hour.
enum NemotronEngine {
    /// Runs `source` through the diarizer and returns the flattened [frames x Timeline.slots] probabilities
    /// and the frame count. The frontend keeps only what it still needs (the probe saw ~65 MB at 2.2 h).
    static func probabilities(source: MappedPCM16Source, models: Nemotron3Models) throws -> (p: [Float], frames: Int) {
        let diarizer = Nemotron3Diarizer(config: Pinned.nemotron, models: models)
        var p: [Float] = []
        p.reserveCapacity((source.sampleCount / 160 + 1) * Timeline.slots)
        try ChunkFeeder.feed(source: source, chunkSamples: 480_000) { chunk in
            diarizer.appendAudio(chunk)
            for r in try diarizer.processBufferedAudio() { p.append(contentsOf: r.probabilities) }
        }
        for r in try diarizer.finishStream() { p.append(contentsOf: r.probabilities) }
        return (p, p.count / Timeline.slots)
    }
}
