import AppKit

/// The main window's sidebar sections, in sidebar order: Voiceover, Voices, Dictation, Meetings, Transcribe,
/// then Models (Advanced mode only) and Settings, which the sidebar draws apart at the bottom. A section is
/// listed only once something real is behind it (`MainWindowSpec.liveSections`).
public enum MainSection: String, CaseIterable, Equatable, Identifiable {
    case speak
    case voices
    case dictation
    case meetings
    case transcribe
    case models
    case settings

    public var id: String { rawValue }

    public var titleKey: L10nKey {
        switch self {
        case .speak: return .sectionSpeak
        case .voices: return .sectionVoices
        case .dictation: return .sectionDictation
        case .meetings: return .sectionMeetings
        case .transcribe: return .sectionTranscribe
        case .models: return .sectionModels
        case .settings: return .sectionSettings
        }
    }

    /// Shown only while the Advanced switch is on.
    public var isAdvancedOnly: Bool { self == .models }
}

/// The Advanced switch: one stored preference, plus the one decision that follows a flip.
public enum AdvancedMode {
    public static let key = "mainWindow.advanced"

    public static func isOn(_ d: UserDefaults) -> Bool { d.bool(forKey: key) }

    public static func set(_ on: Bool, in d: UserDefaults) { d.set(on, forKey: key) }

    /// Where the window goes when the switch flips: off while on Models -> the first section left.
    public static func section(after flipTo: Bool, current: MainSection) -> MainSection {
        !flipTo && current.isAdvancedOnly ? (MainWindowSpec.sections(advanced: false).first ?? .meetings) : current
    }
}

/// The main window's fixed parameters and which sections the sidebar lists.
public enum MainWindowSpec {
    /// Sections that have real content on this build. Each section task adds its own case here (one line);
    /// a new case lands unlisted, which is the safe side of a forgotten flag.
    public static let liveSections: Set<MainSection> = [.meetings, .dictation, .voices, .settings]
    /// The switch is drawn only once something behind it differs (turned on by the first task that reveals
    /// advanced content).
    public static let showsAdvancedSwitch = false
    public static let minimumWidth = 760.0
    public static let minimumHeight = 520.0
    /// The frame autosave name: the window reopens where it was closed.
    public static let frameAutosaveName = "MainWindow"

    /// The window comes to the user, never the other way round: it moves to the Space that is current when it is shown,
    /// and may join another app's full-screen Space. Apple's NSWindow.h allows one Space bit (this is
    /// MoveToActiveSpace, exclusive with CanJoinAllSpaces) and one full-screen bit (FullScreenAuxiliary, exclusive
    /// with Primary and None); the two groups are independent. Managed stays implied, so it moves, minimises and
    /// takes part in Mission Control like any window.
    public static let collectionBehavior: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

    /// The window is one "OxSay" whichever section is selected; the section is its subtitle.
    public static let windowTitleKey: L10nKey = .windowTitle

    public static func subtitleKey(for section: MainSection) -> L10nKey { section.titleKey }

    /// The sidebar's sections, in order: the live ones, with the Advanced-only ones only while the switch is on.
    public static func sections(advanced: Bool, live: Set<MainSection> = liveSections) -> [MainSection] {
        MainSection.allCases.filter { live.contains($0) && (advanced || !$0.isAdvancedOnly) }
    }

    /// Where a first run lands: Voiceover once it is live, Meetings until then.
    public static var firstRunSection: MainSection { liveSections.contains(.speak) ? .speak : .meetings }
}
