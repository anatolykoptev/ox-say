import AVFoundation

/// Converts audio buffers of any format to 16 kHz mono Float, the format of the
/// meeting channels. The same conversion MicRecorder does for dictation; a
/// second copy is kept here so the dictation path is not touched by the
/// meeting feature (extract both into one type at a third use).
final class PCM16kConverter {
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        if converter == nil || source != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            source = buffer.format
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
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
        guard error == nil, let channel = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }
}
