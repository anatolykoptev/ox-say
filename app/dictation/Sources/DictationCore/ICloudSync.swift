import Foundation

/// Whether macOS itself uploads a folder's contents to iCloud (#532). Two ways a folder syncs:
/// it sits inside an iCloud ubiquity container (`~/Library/Mobile Documents` holds one per
/// container, `com~apple~CloudDocs` being the iCloud Drive root), or the folder — or the nearest
/// ancestor that exists, since the notes folder may not be created yet — reports
/// `URLResourceValues.isUbiquitousItem`, which is how "Desktop & Documents Folders" sync marks
/// `~/Desktop` and `~/Documents` (they stay at their home paths, but their items are in iCloud
/// storage).
public enum ICloudSync {
    /// What the filesystem says about a path: `isUbiquitousItem` for one that exists, nil for one
    /// that does not. A probe that throws means "unknown" — and unknown is not a sync answer.
    /// Injected so tests never touch real iCloud state.
    public typealias Probe = (URL) throws -> Bool?

    /// The real probe: `isUbiquitousItem` — true when the item is in iCloud storage, false for a
    /// local item.
    public static let probe: Probe = { url in
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (try url.resourceValues(forKeys: [.isUbiquitousItemKey])).isUbiquitousItem ?? false
    }

    /// True when a file written to `folder` is uploaded to iCloud by macOS. A probe throw or an
    /// unknown answer reads as not synced: the settings page shows no warning rather than a wrong
    /// one, and nothing crashes.
    public static func syncs(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             probe: Probe = ICloudSync.probe) -> Bool {
        // A path inside a ubiquity container counts by itself. Both sides resolve: a symlinked
        // ancestor can land the folder inside a container, and the home itself can sit behind a
        // link (/var -> /private/var). resolvingSymlinksInPath is a no-op on a path whose tail
        // does not exist, so the resolved check runs on every candidate in the walk — the
        // nearest existing ancestor is where a picked symlink actually unfolds.
        let roots = [home, home.resolvingSymlinksInPath()]
            .map { $0.appendingPathComponent("Library/Mobile Documents", isDirectory: true) }
        var candidate = folder
        // One step per path component and no more: the walk ends at the root by counting, not by
        // comparing URLs, so no URL quirk at `/` can make it spin.
        for _ in 0...folder.standardizedFileURL.pathComponents.count {
            if roots.contains(where: { underMobileDocuments(candidate, under: $0) || underMobileDocuments(candidate.resolvingSymlinksInPath(), under: $0) }) {
                return true
            }
            // `try?` would flatten "threw" and "does not exist" into the same nil; only a throw
            // means "unknown".
            let answer: Bool?
            do { answer = try probe(candidate) } catch { return false }
            if let answer { return answer }
            candidate = candidate.deletingLastPathComponent()
        }
        return false
    }

    /// The path is `root` itself or under it.
    private static func underMobileDocuments(_ url: URL, under root: URL) -> Bool {
        url.standardizedFileURL.pathComponents.starts(with: root.pathComponents)
    }
}
