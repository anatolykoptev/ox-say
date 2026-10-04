import Foundation

/// Plays synthesized audio through the platform player, afplay. Each playback
/// is its own temporary file and process: a new `play` stops the previous one,
/// and a file is removed when its process exits, not when the next one starts,
/// so an interrupted playback cannot delete a live one's file.
final class AudioPlayer {
    private var current: Process?

    func stop() {
        current?.terminate()
        current = nil
    }

    /// Plays the bytes as a wav. Returns after afplay starts; playback then
    /// continues in the background until it finishes or `stop` runs.
    func play(wav: Data) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ox-say-speak-\(UUID().uuidString).wav")
        try wav.write(to: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [url.path]
        process.terminationHandler = { _ in try? FileManager.default.removeItem(at: url) }
        stop()
        try process.run()
        current = process
    }
}
