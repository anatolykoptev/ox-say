import XCTest
@testable import DictationCore

final class WaveformTests: XCTestCase {
    func testPeaksOfASilentAndALoudWave() {
        let silent = WAV.pcm16([Float](repeating: 0, count: 4800), sampleRate: 48000)
        XCTAssertEqual(Waveform.peaks(wav: silent, bins: 10), [Float](repeating: 0, count: 10))
        let loud = WAV.pcm16([Float](repeating: 0.5, count: 4800), sampleRate: 48000)
        XCTAssertTrue(Waveform.peaks(wav: loud, bins: 10).allSatisfy { abs($0 - 0.5) < 0.01 })
        XCTAssertEqual(Waveform.peaks(wav: Data("not a wav".utf8), bins: 10), [])
    }

    func testABinHoldsTheLoudestSampleOfItsStretch() {
        var samples = [Float](repeating: 0.1, count: 1000)
        samples[750] = -0.9
        let peaks = Waveform.peaks(wav: WAV.pcm16(samples, sampleRate: 8000), bins: 4)
        XCTAssertEqual(peaks.count, 4)
        XCTAssertEqual(peaks[3], 0.9, accuracy: 0.01, "a negative peak counts by its size")
        XCTAssertEqual(peaks[0], 0.1, accuracy: 0.01)
    }

    func testGarbageWithAHeaderShapedStartIsRejected() {
        // Right size, wrong magic: decoding the bytes as samples would draw noise.
        XCTAssertEqual(Waveform.peaks(wav: Data(repeating: 0x7F, count: 4096), bins: 8), [])
        XCTAssertEqual(Waveform.peaks(wav: Data(), bins: 8), [])
        let wav = WAV.pcm16([Float](repeating: 0.5, count: 100), sampleRate: 8000)
        XCTAssertEqual(Waveform.peaks(wav: wav, bins: 0), [])
        XCTAssertEqual(Waveform.peaks(wav: wav.prefix(40), bins: 4), [], "a header with no data chunk")
    }

    /// A well-formed body behind the wrong container magic is not this reader's file (a big-endian RIFX would draw noise).
    func testAWrongContainerMagicIsRejectedEvenWithAGoodBody() {
        var wav = WAV.pcm16([Float](repeating: 0.5, count: 100), sampleRate: 8000)
        XCTAssertFalse(Waveform.peaks(wav: wav, bins: 4).isEmpty)
        wav.replaceSubrange(0..<4, with: Array("RIFX".utf8))
        XCTAssertEqual(Waveform.peaks(wav: wav, bins: 4), [])
        wav = WAV.pcm16([Float](repeating: 0.5, count: 100), sampleRate: 8000)
        wav.replaceSubrange(8..<12, with: Array("AVI ".utf8))
        XCTAssertEqual(Waveform.peaks(wav: wav, bins: 4), [])
    }

    func testStereoTakesTheLouderChannelAndFewerFramesThanBinsStillFills() {
        // Two frames, left quiet / right loud: 4 bins over 2 frames.
        var data = WAV.pcm16([0.1, 0.8, 0.1, 0.8], sampleRate: 8000)
        data.replaceSubrange(22..<24, with: [2, 0])            // channels = 2
        data.replaceSubrange(32..<34, with: [4, 0])            // block align = 4
        let peaks = Waveform.peaks(wav: data, bins: 4)
        XCTAssertEqual(peaks.count, 4)
        XCTAssertTrue(peaks.allSatisfy { abs($0 - 0.8) < 0.01 })
    }

    func testTheCursorIsAFractionOfTheTrackAndNeverLeavesTheBar() {
        XCTAssertEqual(Waveform.fraction(time: 30, duration: 120), 0.25)
        XCTAssertEqual(Waveform.fraction(time: 200, duration: 120), 1)
        XCTAssertEqual(Waveform.fraction(time: -1, duration: 120), 0)
        XCTAssertEqual(Waveform.fraction(time: 5, duration: 0), 0, "no length yet: no cursor math by zero")
    }

    /// A scan whose track left the screen stops instead of reading hundreds of megabytes.
    func testACancelledScanReturnsNothing() async {
        let wav = WAV.pcm16([Float](repeating: 0.5, count: 4800), sampleRate: 48000)
        let scan = Task { () -> [Float] in
            while !Task.isCancelled { await Task.yield() }
            return Waveform.peaks(wav: wav, bins: 10)
        }
        scan.cancel()
        let peaks = await scan.value
        XCTAssertEqual(peaks, [], "cancelled: no bars, not a half-read picture")
        XCTAssertEqual(Waveform.peaks(wav: wav, bins: 10).count, 10, "the same call outside a cancelled task reads normally")
    }
}
