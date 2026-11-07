import Foundation

/// Bars for the finished track's picture, read from the WAV the daemon wrote.
public enum Waveform {
    /// `bins` peaks in 0...1: each the loudest sample (either channel) of its stretch of the track. Only a 16-bit PCM WAV
    /// of one or two channels is read; anything else gives `[]`, so a file that is not that draws no bars rather than noise.
    public static func peaks(wav: Data, bins: Int) -> [Float] {
        guard bins > 0, let layout = layout(of: wav) else { return [] }
        let frames = layout.dataLength / layout.blockAlign
        guard frames > 0 else { return [] }
        var peaks = [Float](repeating: 0, count: bins)
        var cancelled = false
        wav.withUnsafeBytes { raw in
            for bin in 0..<bins {
                // A track that is no longer on screen is not worth finishing: its scan can be hundreds of megabytes.
                if Task.isCancelled { cancelled = true; return }
                let from = frames * bin / bins
                let to = max(from + 1, frames * (bin + 1) / bins)
                var loudest: Int32 = 0
                for frame in from..<min(to, frames) {
                    for channel in 0..<layout.channels {
                        let at = layout.dataStart + frame * layout.blockAlign + channel * 2
                        let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: Int16.self))
                        loudest = max(loudest, abs(Int32(sample)))
                    }
                }
                peaks[bin] = min(1, Float(loudest) / 32768)
            }
        }
        return cancelled ? [] : peaks
    }

    /// How far into a track the sound is, 0...1.
    public static func fraction(time: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, time / duration))
    }

    private struct Layout { var channels: Int; var blockAlign: Int; var dataStart: Int; var dataLength: Int }

    /// The header, parsed strictly: RIFF/WAVE, a PCM `fmt ` chunk (16 bit, 1 or 2 channels) and a `data` chunk.
    private static func layout(of wav: Data) -> Layout? {
        guard wav.count >= 12, wav.prefix(4) == Data("RIFF".utf8), wav.dropFirst(8).prefix(4) == Data("WAVE".utf8) else { return nil }
        func u16(_ at: Int) -> Int { Int(wav[wav.startIndex + at]) | Int(wav[wav.startIndex + at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        var channels = 0, bits = 0, format = 0
        var at = 12
        while at + 8 <= wav.count {
            let id = wav.dropFirst(at).prefix(4)
            let size = u32(at + 4)
            let body = at + 8
            if id == Data("fmt ".utf8) {
                guard size >= 16, body + 16 <= wav.count else { return nil }
                format = u16(body)
                channels = u16(body + 2)
                bits = u16(body + 14)
            } else if id == Data("data".utf8) {
                guard format == 1, bits == 16, channels == 1 || channels == 2 else { return nil }
                // A streamed file may declare 0 or 0xFFFFFFFF: the rest of the file is the data then.
                let available = wav.count - body
                let length = (size == 0 || size > available) ? available : size
                let block = channels * 2
                return Layout(channels: channels, blockAlign: block, dataStart: body, dataLength: length - length % block)
            }
            at = body + size + (size % 2)
        }
        return nil
    }
}
