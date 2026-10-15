import Foundation

/// What the Studio submenu shows, decided on every menu open from the daemon's
/// /status and the voiceover the app is following. Pure: AppKit only draws the rows.
public enum StudioMenu {
    public static let installTitle = "Install Studio Voice (about 3 GB)…"
    public static let newVoiceoverTitle = "New Voiceover from Text File…"
    public static let stopTitle = "Stop Voiceover"
    public static let continueTitle = "Continue on Battery Power"
    public static let folderTitle = "Open Voiceovers Folder"
    public static let createVoiceTitle = "Create a Voice…"
    public static let noServiceTitle = "Studio needs the ox-say service, which is not answering"
    /// UserDefaults key: the studio voice was installed from the menu once.
    public static let installAttemptedKey = "studioInstallAttempted"
    public static let cannotRunTitle = "This Mac can't run the studio voice."

    /// - Parameters:
    ///   - status: the daemon's last /status; nil when it did not answer.
    ///   - installAttempted: the studio voice was installed once already and the
    ///     daemon still says it is unavailable, so offering the same install again helps nobody.
    ///   - installing: an install or update is running now.
    ///   - job: the voiceover the app is following, while it is not over.
    ///   - hasOutputFolder: the latest voiceover's folder exists on this Mac.
    public static func rows(status: DaemonStatus?, installAttempted: Bool, installing: Bool,
                            job: ProduceJob?, hasOutputFolder: Bool) -> [MenuRow] {
        guard let status else {
            return [.item(title: noServiceTitle, isOn: false, isEnabled: false, action: nil)]
        }
        guard status.studioAvailable else {
            if installAttempted {
                return [.item(title: unavailableText(reason: status.studioReason), isOn: false, isEnabled: false, action: nil)]
            }
            return [.item(title: installTitle, isOn: false, isEnabled: !installing, action: .installStudioVoice)]
        }
        let active = job.map { !$0.status.isTerminal } ?? false
        var rows: [MenuRow] = [.item(title: newVoiceoverTitle, isOn: false, isEnabled: !active, action: .newVoiceover)]
        if let job, active {
            rows.append(.item(title: ProduceText.progressRow(job), isOn: false, isEnabled: false, action: nil))
            rows.append(.item(title: stopTitle, isOn: false, isEnabled: true, action: .stopVoiceover))
            if job.status == .pausedOnBattery {
                rows.append(.item(title: continueTitle, isOn: false, isEnabled: true, action: .continueOnBattery))
            }
        }
        rows.append(.item(title: folderTitle, isOn: false, isEnabled: hasOutputFolder, action: hasOutputFolder ? .openVoiceoversFolder : nil))
        rows.append(.separator)
        rows.append(.item(title: createVoiceTitle, isOn: false, isEnabled: true, action: .createVoice))
        return rows
    }

    /// The daemon's reason the studio voice cannot run, in words for the owner; a
    /// reason that is nothing but a terminal instruction, or none, becomes the plain fallback.
    public static func unavailableText(reason: String?) -> String {
        PlainWords.clean(reason ?? "", fallback: cannotRunTitle)
    }

    /// The Voice popup of the voiceover form: "Default voice" (the daemon's own
    /// pick, nil) then the daemon's voices; the Russian voice pick is preselected
    /// when it is one of them.
    public static func voiceChoices(voices: [String], russianPick: String?) -> (names: [String?], selected: Int) {
        let names: [String?] = [nil] + voices.map { Optional($0) }
        let selected = russianPick.flatMap { pick in voices.firstIndex(of: pick).map { $0 + 1 } } ?? 0
        return (names, selected)
    }

    /// The file name without its extension: the form's default title.
    public static func defaultTitle(fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }
}

/// The daemon words its errors for terminals and agents too. What an owner reads
/// drops the sentences that name an environment variable or a tool, and the engine's name.
public enum PlainWords {
    /// Text that only makes sense in a terminal or to an agent.
    static let jargon = ["OX_SAY", "voice_", "ox-say voice", "ox-say status", "`"]

    public static func clean(_ text: String, fallback: String) -> String {
        let all = text.components(separatedBy: ". ")
        let kept = all.filter { sentence in
            !sentence.isEmpty && !jargon.contains(where: { sentence.contains($0) })
        }
        guard let last = kept.last else { return fallback }
        let joined = kept.joined(separator: ". ").replacingOccurrences(of: " (VoxCPM2)", with: "")
        // A sentence cut off from the ones after it needs its full stop back.
        return last == all.last ? joined : joined + "."
    }
}
