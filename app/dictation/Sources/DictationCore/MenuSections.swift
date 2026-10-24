/// What the menu's merged submenus contain, as plain values: the Voice
/// submenu (a Russian and an English section) and the Keyboard Shortcuts
/// submenu (a dictation and a speak section). AppKit only draws the rows, so a
/// lost section or a dropped key row fails a test instead of shipping.

/// The language a voice pick belongs to; the text's script chooses which pick a
/// speak request sends (see VoicePick).
public enum VoiceSlot: Equatable, CaseIterable {
    case russian
    case english

    public var title: String {
        switch self {
        case .russian: return "Russian"
        case .english: return "English"
        }
    }
}

/// What choosing a row does; the app maps each case onto its own selector.
public enum MenuAction: Equatable {
    /// `name` nil is "Default voice" (no pref stored); "default" is the engine's random voice.
    case pickVoice(VoiceSlot, name: String?)
    /// An index into the offered dictation keys.
    case pickDictationKey(Int)
    /// An index into the offered speak keys.
    case pickSpeakKey(Int)
    // The Studio submenu.
    case installStudioVoice
    case newVoiceover
    case stopVoiceover
    case continueOnBattery
    case openVoiceoversFolder
    case createVoice
    // The Recent Dictations submenu and its sibling row.
    /// An index into `DictationHistory.texts` (newest first): copy it.
    case copyDictation(Int)
    case pasteLastDictation
    // The Meetings submenu.
    case startMeeting
    case stopMeeting
    case installNotesModel
    case openMeetingsFolder
    case chooseMeetingsFolder
    case setMeetingName
    case toggleMeetingAutoStart
    /// The days of audio retention (0 = never delete).
    case pickMeetingRetention(Int)
    /// Name, merge or split the speakers of the meeting with this id.
    case editSpeakers(String)
    /// Tell the voices of the meeting with this id apart again (the engine broke the first time).
    case retryVoices(String)
}

public enum MenuRow: Equatable {
    case header(String)
    case item(title: String, isOn: Bool, isEnabled: Bool, action: MenuAction?)
    case separator
}

public enum MenuSections {
    public static let defaultVoiceTitle = "Default voice"
    public static let randomVoiceTitle = "Random each time"
    public static let loadingTitle = "Loading…"
    public static let dictationHeader = "Dictation"
    public static let speakHeader = "Speak Selection"
    /// The pref value that means "the engine's random voice".
    public static let randomVoice = "default"

    /// The Voice submenu: per language a header, "Default voice", "Random each
    /// time", then the daemon's voices (or "Loading…" until the first answer).
    /// `known` nil means no answer yet.
    public static func voiceRows(known: [String]?, russian: String?, english: String?) -> [MenuRow] {
        var rows: [MenuRow] = []
        for slot in VoiceSlot.allCases {
            if !rows.isEmpty { rows.append(.separator) }
            let current = slot == .russian ? russian : english
            rows.append(.header(slot.title))
            rows.append(.item(title: defaultVoiceTitle, isOn: current == nil, isEnabled: true,
                              action: .pickVoice(slot, name: nil)))
            rows.append(.item(title: randomVoiceTitle, isOn: current == randomVoice, isEnabled: true,
                              action: .pickVoice(slot, name: randomVoice)))
            for name in known ?? [] {
                rows.append(.item(title: name, isOn: name == current, isEnabled: true,
                                  action: .pickVoice(slot, name: name)))
            }
            if known == nil {
                rows.append(.item(title: loadingTitle, isOn: false, isEnabled: false, action: nil))
            }
        }
        return rows
    }

    /// The Keyboard Shortcuts submenu: the dictation keys, then the speak keys,
    /// each row keeping the state the plan gave it (checked, greyed out, "a macOS shortcut").
    public static func shortcutRows(dictation: [ShortcutMenu.Item], speak: [ShortcutMenu.Item]) -> [MenuRow] {
        var rows: [MenuRow] = [.header(dictationHeader)]
        for (index, item) in dictation.enumerated() {
            rows.append(.item(title: item.title, isOn: item.isOn, isEnabled: item.isEnabled,
                              action: .pickDictationKey(index)))
        }
        rows.append(.separator)
        rows.append(.header(speakHeader))
        for (index, item) in speak.enumerated() {
            rows.append(.item(title: item.title, isOn: item.isOn, isEnabled: item.isEnabled,
                              action: .pickSpeakKey(index)))
        }
        return rows
    }
}
