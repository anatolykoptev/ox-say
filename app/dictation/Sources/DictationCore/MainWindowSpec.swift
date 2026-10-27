/// The main window's sidebar sections, in sidebar order. Meetings, Dictation,
/// Voices and Settings have real content; Reel and Projects are planned and
/// stay out of the sidebar (and out of what users see) until something is behind them.
public enum MainSection: String, CaseIterable, Equatable, Identifiable {
    case meetings
    case dictation
    case voices
    case settings
    case reel
    case projects

    public var id: String { rawValue }

    public var titleKey: L10nKey {
        switch self {
        case .meetings: return .sectionMeetings
        case .dictation: return .sectionDictation
        case .voices: return .sectionVoices
        case .settings: return .sectionSettings
        case .reel: return .sectionReel
        case .projects: return .sectionProjects
        }
    }

    /// Planned sections: they exist in the model and wait for their own phase.
    public var isPlanned: Bool { self == .reel || self == .projects }

    /// The one line the placeholder detail shows for a planned section; the live
    /// sections have no placeholder.
    public var placeholderKey: L10nKey? {
        switch self {
        case .reel: return .placeholderReel
        case .projects: return .placeholderProjects
        case .meetings, .dictation, .voices, .settings: return nil
        }
    }
}

/// The main window's fixed parameters and which sections the sidebar lists.
public enum MainWindowSpec {
    /// Planned sections wait for their phase; a new planned case lands hidden by
    /// default, which is the safe side of a forgotten flag.
    public static let showsPlannedSections = false
    public static let minimumWidth = 760.0
    public static let minimumHeight = 520.0
    /// The frame autosave name: the window reopens where it was closed.
    public static let frameAutosaveName = "MainWindow"

    /// The sidebar's sections: the live four, or all of them behind the flag.
    public static func sections(includePlanned: Bool) -> [MainSection] {
        includePlanned ? MainSection.allCases : MainSection.allCases.filter { !$0.isPlanned }
    }

    /// What the sidebar lists on this build.
    public static var visibleSections: [MainSection] {
        sections(includePlanned: showsPlannedSections)
    }
}
