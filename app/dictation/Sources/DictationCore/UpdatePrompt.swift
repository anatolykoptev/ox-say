import Foundation

/// What a user-initiated update check ends in: always one of these, rendered
/// as an alert that waits for the user.
public enum UpdatePrompt: Equatable {
    case upToDate(version: String)
    case available(remote: String, local: String, notes: String, url: URL?)
    case failed(reason: String)

    /// The longest release-notes excerpt an alert shows, in characters.
    public static let notesLimit = 1200

    /// Maps the installed version and the fetch outcome to the prompt.
    public static func make(local: String,
                            fetch: Result<(tag: String, url: URL?, body: String), UpdateError>) -> UpdatePrompt {
        switch fetch {
        case .failure(let error):
            return .failed(reason: String(describing: error))
        case .success(let release):
            guard UpdateChecker.isNewer(release.tag, than: local) else { return .upToDate(version: local) }
            return .available(remote: release.tag, local: local,
                              notes: releaseNotesText(release.body, limit: notesLimit), url: release.url)
        }
    }

    private static let replacements: [(pattern: String, template: String)] = [
        (#"<!--.*?-->"#, ""),                       // html comments
        (#"(?m)^[ \t]{0,3}#{1,6}[ \t]+"#, ""),            // heading markers
        (#"(?m)^[ \t]*[-*+][ \t]+"#, "• "),               // bullets
        (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),        // links and images keep their text
        (#"(\*\*|__|`)"#, ""),                      // bold, code
        (#"\n{3,}"#, "\n\n"),                       // blank-line runs
    ]

    /// GitHub release markdown reduced to plain readable text, at most `limit`
    /// characters (the last one "…" when it was cut).
    public static func releaseNotesText(_ markdown: String, limit: Int) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        for (pattern, template) in replacements {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                               withTemplate: template)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        return text.prefix(max(0, limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
