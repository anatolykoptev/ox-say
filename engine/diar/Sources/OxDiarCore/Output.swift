import Foundation

/// One span of one cluster as FluidAudio reports it (exclusive timeline).
public struct RawSegment: Equatable {
    public var start: Double
    public var end: Double
    public var speaker: String
    /// The cluster's VBx centroid (256 floats); FluidAudio repeats it on every segment of the cluster.
    public var embedding: [Float]

    public init(start: Double, end: Double, speaker: String, embedding: [Float]) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.embedding = embedding
    }
}

/// diarization.json, version 1: the contract internal/meeting.ParseDiarization reads.
public struct Diarization: Encodable, Equatable {
    public struct Speaker: Encodable, Equatable {
        public var id: Int
        public var speechS: Double
        public var embedding: [Float]
        enum CodingKeys: String, CodingKey { case id, speechS = "speech_s", embedding }
    }

    public struct Segment: Encodable, Equatable {
        public var s: Double
        public var e: Double
        public var spk: Int
    }

    public var version = 1
    public var durationS: Double
    public var speakers: [Speaker]
    public var segments: [Segment]
    public var timingS: [String: Double]
    enum CodingKeys: String, CodingKey {
        case version, durationS = "duration_s", speakers, segments, timingS = "timing_s"
    }

    /// Builds the answer from FluidAudio's segments: times rounded to the millisecond, segments that are empty
    /// at that precision dropped, sorted by (start, end); speakers are the clusters that kept a segment,
    /// numbered 0..n-1 by descending speech (ties: earlier first appearance, then name), so the ids are dense
    /// as ParseDiarization requires and do not depend on FluidAudio's cluster labels.
    public static func make(duration: Double, segments raw: [RawSegment], timing: [String: Double]) -> Diarization {
        func ms(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        let kept = raw.map { RawSegment(start: ms($0.start), end: ms($0.end), speaker: $0.speaker, embedding: $0.embedding) }
            .filter { $0.end > $0.start && $0.start >= 0 }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var speech: [String: Double] = [:]
        var first: [String: Double] = [:]
        var centroid: [String: [Float]] = [:]
        for s in kept {
            speech[s.speaker, default: 0] += s.end - s.start
            first[s.speaker] = first[s.speaker] ?? s.start
            if centroid[s.speaker] == nil { centroid[s.speaker] = s.embedding }
        }
        let order = speech.keys.sorted {
            (-ms(speech[$0]!), first[$0]!, $0) < (-ms(speech[$1]!), first[$1]!, $1)
        }
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return Diarization(
            durationS: ms(duration),
            speakers: order.map { Speaker(id: index[$0]!, speechS: ms(speech[$0]!), embedding: centroid[$0] ?? []) },
            segments: kept.map { Segment(s: $0.start, e: $0.end, spk: index[$0.speaker]!) },
            timingS: timing)
    }

    /// JSON with the keys in a fixed order.
    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }
}
