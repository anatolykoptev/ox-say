import Testing
@testable import OxDiarCore

private func probs(_ n: Int, _ on: [(slot: Int, from: Int, to: Int, p: Float)]) -> [Float] {
    var a = [Float](repeating: 0, count: n * Timeline.slots)
    for o in on { for f in o.from..<o.to { a[f * Timeline.slots + o.slot] = o.p } }
    return a
}

@Suite struct TimelineTests {
    @Test func theStrongestSlotOwnsAFrameTwoSlotsClaim() {
        let p = probs(10, [(0, 0, 6, 0.6), (1, 4, 10, 0.9)])
        #expect(Timeline.exclusive(probabilities: p, frameCount: 10)
                == [.init(startFrame: 0, endFrame: 4, slot: 0), .init(startFrame: 4, endFrame: 10, slot: 1)])
    }
    @Test func exactlyHalfIsNotSpeech() {
        #expect(Timeline.exclusive(probabilities: probs(5, [(0, 0, 5, 0.5)]), frameCount: 5).isEmpty)
    }
    @Test func aTieGoesToTheLowerSlot() {
        let p = probs(3, [(2, 0, 3, 0.8), (5, 0, 3, 0.8)])
        #expect(Timeline.exclusive(probabilities: p, frameCount: 3).map(\.slot) == [2])
    }
    @Test func aGapOfExactlyMaxIsJoinedAndOneFrameMoreIsNot() {
        let a = Timeline.Span(startFrame: 0, endFrame: 100, slot: 0)
        #expect(Timeline.mergeGaps([a, .init(startFrame: 250, endFrame: 300, slot: 0)])
                == [.init(startFrame: 0, endFrame: 300, slot: 0)])
        #expect(Timeline.mergeGaps([a, .init(startFrame: 251, endFrame: 300, slot: 0)]).count == 2)
    }
    @Test func anotherSlotInBetweenBlocksTheMerge() {
        let s = [Timeline.Span(startFrame: 0, endFrame: 100, slot: 0), .init(startFrame: 100, endFrame: 120, slot: 1),
                 .init(startFrame: 120, endFrame: 200, slot: 0)]
        #expect(Timeline.mergeGaps(s) == s)
    }
    @Test func theFixedGapIsOnePointFiveSeconds() { #expect(Timeline.mergeGapFrames == 150) }
}
