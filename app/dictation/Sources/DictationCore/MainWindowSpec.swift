import AppKit
import SwiftUI

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
    public static let liveSections: Set<MainSection> = [.speak, .meetings, .dictation, .voices, .transcribe, .settings]
    /// The switch is drawn only once something behind it differs: since the Advanced voice panel on Озвучка it does.
    public static let showsAdvancedSwitch = true
    /// The sidebar's column width. Its maximum is what the window floor must leave room for.
    public static let sidebarWidth = (minimum: 170.0, ideal: 190.0, maximum: 240.0)
    /// Meetings: the list pane's width (ideal 290) and the least the meeting pane may get, with the divider between.
    public static let meetingsListWidth = (minimum: 260.0, ideal: 290.0, maximum: 420.0)
    public static let meetingsDetailMinimum = 300.0
    public static let splitDividerWidth = 1.0
    /// The divider the NavigationSplitView draws between sidebar and detail: thin, 1 pt like our own split's.
    public static let outerSplitDividerWidth = 1.0
    /// The window never gets narrower than the widest sidebar plus BOTH dividers, the Meetings list at its least and
    /// the meeting at its least (240 + 1 + 260 + 1 + 300 = 802), so the meeting pane is never clipped. Leave out the
    /// outer divider and the detail column at the floor is one point short of the split: it overflows, the stored
    /// divider position never applies and drags are never stored.
    public static let minimumWidth = (sidebarWidth.maximum + outerSplitDividerWidth + meetingsListWidth.minimum + splitDividerWidth + meetingsDetailMinimum).rounded(.up)
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

    /// The sidebar's arrow-key hop between the sections list and the one-row Settings list: down from the last section
    /// reaches Settings, up from Settings returns to the last section. `nil` is "the list's own arrow": any other
    /// arrow or position, no Settings row, and any arrow held with a modifier (Cmd/Shift/Option-Down extends or jumps
    /// inside the list, it never leaves it).
    public static func sidebarMove(_ arrow: SidebarArrow, from list: SidebarList, plain: Bool, current: MainSection,
                                   sections: [MainSection]) -> SidebarMove? {
        guard plain else { return nil }
        let top = sections.filter { $0 != .settings }
        switch (list, arrow) {
        case (.sections, .down):
            guard sections.contains(.settings), current == top.last else { return nil }
            return SidebarMove(section: .settings, list: .settings)
        case (.settings, .up):
            guard let last = top.last else { return nil }
            return SidebarMove(section: last, list: .sections)
        default:
            return nil
        }
    }

    /// Where a first run lands: Voiceover once it is live, Meetings until then.
    public static var firstRunSection: MainSection { liveSections.contains(.speak) ? .speak : .meetings }
}

/// The two lists of the sidebar: the sections, and the one-row Settings list under the Advanced switch.
public enum SidebarList: Hashable { case sections, settings }
public enum SidebarArrow: Equatable {
    case up, down

    /// A bare arrow: no Shift, Control, Option or Command. AppKit adds `.numericPad` and `.function` to every real
    /// hardware arrow key, so "no modifiers at all" would reject the real keyboard; only the four user-held keys count.
    public static func isPlain(_ modifiers: EventModifiers) -> Bool {
        modifiers.isDisjoint(with: [.shift, .control, .option, .command])
    }
}
/// Where an arrow hop lands: the section it selects and the list that takes the keyboard.
public struct SidebarMove: Equatable {
    public let section: MainSection
    public let list: SidebarList
    public init(section: MainSection, list: SidebarList) { self.section = section; self.list = list }
}
