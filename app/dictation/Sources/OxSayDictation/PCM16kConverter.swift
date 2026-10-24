import AVFoundation

/// Converts audio buffers of any format to 16 kHz mono Float, the format of the
/// meeting channels. The same conversion MicRecorder does for dictation; a
/// second copy is kept here so the dictation path is not touched by the
/// meeting feature (extract both into one type at a third use).
///
/// Stereo (the system tap) is averaged to mono, not cut to its first channel.
/// Timing contract (#247): the caller stamps each returned chunk with the INPUT
/// buffer's first-sample host time; a resampler's own latency is not a timestamp.
/// A nil or empty result is counted, never silent — the controller logs the counters.
final class PCM16kConverter {
    /// Buffers that could not be converted (no converter for the format, allocation, converter error).
    private(set) var failedConversions = 0
    /// Buffers that converted to zero frames (the resampler's priming, or a zero-length input).
    private(set) var emptyConversions = 0

    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        if converter == nil || source != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
            source = buffer.format
        }
        guard let converter else { return failed() }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return failed() }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData else { return failed() }
        if out.frameLength == 0 { emptyConversions += 1 }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    private func failed() -> [Float]? {
        failedConversions += 1
        return nil
    }
}
