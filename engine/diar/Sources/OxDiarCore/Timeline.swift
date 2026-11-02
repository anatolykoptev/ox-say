import Foundation

/// Nemotron's [frames x 8] speaker probabilities at 10 ms -> ox-diar's exclusive timeline.
public enum Timeline {
    public static let slots = 8
    public static let threshold: Float = 0.5
    /// Same-slot neighbours at most this far apart are one segment (1.5 s; REPORT 10.5: AMI manual-reference DER 18.8 -> 6.7,
    /// Russian 13.3 -> 10.4, speaker count unchanged on 15/15). Task 6 re-checks it against word attribution.
    public static let mergeGapFrames = 150

    public struct Span: Equatable {
        public var startFrame: Int
        public var endFrame: Int
        public var slot: Int
        public init(startFrame: Int, endFrame: Int, slot: Int) { self.startFrame = startFrame; self.endFrame = endFrame; self.slot = slot }
    }

    public static func exclusive(probabilities p: [Float], frameCount n: Int) -> [Span] {
        let n = min(n, p.count / slots)   // never trap in a daemon child on a short buffer
        var spans: [Span] = []
        var open: (start: Int, slot: Int)?
        for f in 0...n {
            var label = -1
            if f < n {
                var best = threshold
                for s in 0..<slots where p[f * slots + s] > best { best = p[f * slots + s]; label = s }
            }
            if let o = open, o.slot != label { spans.append(Span(startFrame: o.start, endFrame: f, slot: o.slot)); open = nil }
            if open == nil, label >= 0 { open = (f, label) }
        }
        return spans
    }

    public static func mergeGaps(_ spans: [Span], maxGapFrames: Int = mergeGapFrames) -> [Span] {
        var out: [Span] = []
        for s in spans {
            if var last = out.last, last.slot == s.slot, s.startFrame - last.endFrame <= maxGapFrames {
                last.endFrame = s.endFrame
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }

    public static func raw(_ spans: [Span]) -> [RawSegment] {
        spans.map { RawSegment(start: Double($0.startFrame) / 100, end: Double($0.endFrame) / 100, speaker: "S\($0.slot)") }
    }
}
