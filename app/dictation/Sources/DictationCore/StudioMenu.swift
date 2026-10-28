import Foundation

/// What the Studio submenu shows, decided on every menu open from the daemon's
/// /status and the voiceover the app is following. Pure: AppKit only draws the rows.
public enum StudioMenu {
    public static func installTitle(text: (L10nKey) -> String = { $0.text }) -> String { text(.studioInstallTitle) }
    public static let newVoiceoverTitle = "New Voiceover from Document…"
    public static let stopTitle = "Stop Voiceover"
    public static let continueTitle = "Continue on Battery Power"
    public static let folderTitle = "Open Voiceovers Folder"
    public static func createVoiceTitle(text: (L10nKey) -> String = { $0.text }) -> String { text(.studioCreateVoice) }
    public static let noServiceTitle = "Studio needs the ox-say service, which is not answering"
    public static func cannotRunTitle(text: (L10nKey) -> String = { $0.text }) -> String { text(.studioCannotRun) }
    public static let checkingTitle = "Checking the ox-say service…"

    /// What the app knows of the daemon right now.
    public enum ServiceState: Equatable {
        /// No answer yet since the app started: neither "up" nor "not answering".
        case unknown
        /// The last /status did not answer.
        case unreachable
        case answered(DaemonStatus)
    }

    /// - Parameters:
    ///   - service: the daemon's last /status.
    ///   - installing: an install or update is running now.
    ///   - job: the voiceover the app is following, while it is not over.
    ///   - serviceWaiting: the app is following `job` but the daemon did not answer the last poll.
    ///   - hasOutputFolder: the latest voiceover's folder exists on this Mac.
    ///   - readingDocument: a document is being read for a new voiceover; a second one waits.
    public static func rows(service: ServiceState, installing: Bool, job: ProduceJob?,
                            serviceWaiting: Bool, hasOutputFolder: Bool, readingDocument: Bool = false,
                            text: (L10nKey) -> String = { $0.text }) -> [MenuRow] {
        let active = job.flatMap { $0.status.isTerminal ? nil : $0 }
        switch service {
        case .unknown:
            return jobRows(active, waiting: serviceWaiting) + [disabled(checkingTitle)]
        case .unreachable:
            // A voiceover the app is following keeps its rows: the service is only not answering.
            return jobRows(active, waiting: serviceWaiting) + [disabled(noServiceTitle)]
        case .answered(let status):
            guard status.studioAvailable else {
                guard status.installWouldHelp else { return [disabled(unavailableText(reason: status.studioReason, text: text))] }
                return [.item(title: installTitle(text: text), isOn: false, isEnabled: !installing, action: .installStudioVoice)]
            }
            var rows: [MenuRow] = [.item(title: newVoiceoverTitle, isOn: false, isEnabled: active == nil && !readingDocument, action: .newVoiceover)]
            rows += jobRows(active, waiting: serviceWaiting)
            rows.append(.item(title: folderTitle, isOn: false, isEnabled: hasOutputFolder, action: hasOutputFolder ? .openVoiceoversFolder : nil))
            rows.append(.separator)
            rows.append(.item(title: createVoiceTitle(text: text), isOn: false, isEnabled: true, action: .createVoice))
            return rows
        }
    }

    private static func disabled(_ title: String) -> MenuRow {
        .item(title: title, isOn: false, isEnabled: false, action: nil)
    }

    /// The followed voiceover's progress, Stop and (on battery) Continue rows.
    private static func jobRows(_ job: ProduceJob?, waiting: Bool) -> [MenuRow] {
        guard let job else { return [] }
        var rows = [disabled(ProduceText.progressRow(job, serviceWaiting: waiting)),
                    MenuRow.item(title: stopTitle, isOn: false, isEnabled: true, action: .stopVoiceover)]
        if job.status == .pausedOnBattery {
            rows.append(.item(title: continueTitle, isOn: false, isEnabled: true, action: .continueOnBattery))
        }
        return rows
    }

    /// The daemon's reason the studio voice cannot run, in words for the owner; a
    /// reason that is nothing but a terminal instruction, or none, becomes the plain fallback.
    public static func unavailableText(reason: String?, text: (L10nKey) -> String = { $0.text }) -> String {
        PlainWords.clean(reason ?? "", fallback: cannotRunTitle(text: text))
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
            !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !jargon.contains(where: { sentence.contains($0) })
        }
        guard let last = kept.last else { return fallback }
        let joined = kept.joined(separator: ". ").replacingOccurrences(of: " (VoxCPM2)", with: "")
        // A sentence cut off from the ones after it needs its full stop back.
        return last == all.last ? joined : joined + "."
    }
}
