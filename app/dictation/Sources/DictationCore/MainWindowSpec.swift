/// The main window's sidebar sections, in sidebar order. Reel and Projects are
/// live in P2; the rest exist in the model and wait behind the flag for their
/// own phase.
public enum MainSection: String, CaseIterable, Equatable, Identifiable {
    case reel
    case projects
    case voices
    case dictation
    case settings

    public var id: String { rawValue }

    public var titleKey: L10nKey {
        switch self {
        case .reel: return .sectionReel
        case .projects: return .sectionProjects
        case .voices: return .sectionVoices
        case .dictation: return .sectionDictation
        case .settings: return .sectionSettings
        }
    }

    /// The one line the placeholder detail shows for the section.
    public var placeholderKey: L10nKey {
        switch self {
        case .reel: return .placeholderReel
        case .projects: return .placeholderProjects
        case .voices: return .placeholderVoices
        case .dictation: return .placeholderDictation
        case .settings: return .placeholderSettings
        }
    }
}

/// The main window's fixed parameters and which sections the sidebar lists.
public enum MainWindowSpec {
    /// Sections past Projects wait for their phase; a new case lands hidden by
    /// default, which is the safe side of a forgotten flag.
    public static let showsHiddenSections = false
    public static let minimumWidth = 760.0
    public static let minimumHeight = 520.0
    /// The frame autosave name: the window reopens where it was closed.
    public static let frameAutosaveName = "MainWindow"

    /// The sidebar's sections: the live two, or all of them behind the flag.
    public static func sections(includeHidden: Bool) -> [MainSection] {
        includeHidden ? MainSection.allCases : [.reel, .projects]
    }

    /// What the sidebar lists on this build.
    public static var visibleSections: [MainSection] {
        sections(includeHidden: showsHiddenSections)
    }
}
