import Foundation

/// «Записать свой голос» writes a take into a private temp folder named `ox-say-voice-<uuid>`, which the app
/// removes when the add call returns (VoiceSource.addRecordedVoice). A crash between the write and the `defer`
/// leaves the folder behind — a person's voice on disk, unowned. The app sweeps the leftovers at launch.
public enum VoiceTakeCleanup {
    /// The prefix every take folder's name starts with.
    public static let folderPrefix = "ox-say-voice-"

    /// Whether one entry of the temp-dir listing is a leftover take folder's name: the prefix, then something
    /// (the take's uuid). Named matches only — nothing else in the temp dir is the app's to touch.
    public static func isTakeFolder(_ name: String) -> Bool {
        name.hasPrefix(folderPrefix) && name.count > folderPrefix.count
    }

    /// A take folder younger than this may still belong to a save in flight — the wav is written, the POST is
    /// waiting on the daemon, and the folder is removed when the call returns. Five minutes covers even a slow
    /// transcription; anything older is a leftover the app that wrote it did not live to remove.
    public static let liveWindowSeconds: TimeInterval = 300

    /// Removes every leftover take folder in `directory` and returns how many went. Real directories only: a
    /// symlink named like a take folder is never followed (attributesOfItem reports the link itself, so it does
    /// not pass the .typeDirectory check) and not removed either — it is not a folder the app made. A folder
    /// fresh enough to still be written (see `liveWindowSeconds`) is left for the next launch.
    @discardableResult
    public static func sweep(in directory: URL, fileManager: FileManager = .default) -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names where isTakeFolder(name) {
            let url = directory.appendingPathComponent(name)
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            guard attributes?[.type] as? FileAttributeType == .typeDirectory else { continue }
            if let modified = attributes?[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) < liveWindowSeconds { continue }
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }
}
