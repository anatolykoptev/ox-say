import Foundation

/// Where the main window is pointed: a section, and for Meetings the meeting that is open. Pure, so the decisions
/// about opening and restoring the window are tested without a window.
public struct MainRoute: Equatable {
    public var section: MainSection
    public var meetingID: String?

    public init(section: MainSection = MainWindowSpec.firstRunSection, meetingID: String? = nil) {
        self.section = section
        self.meetingID = meetingID
    }

    /// The first-run section, nothing open: Voiceover once it is live, the Meetings list until then.
    public static var `default`: MainRoute { MainRoute(section: MainWindowSpec.firstRunSection) }

    /// A route resolved against what this build shows: a section the sidebar does not list falls back to the
    /// default (and takes its meeting with it); an empty meeting id is no meeting.
    public func resolved(visible: [MainSection] = MainWindowSpec.sections(advanced: true)) -> MainRoute {
        guard visible.contains(section) else { return .default }
        return MainRoute(section: section, meetingID: meetingID.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The route against the meetings that exist: an id that is not among them is dropped, so the list shows
    /// instead of an empty detail. An empty list says nothing about the id — the daemon may still be coming
    /// up — so it is left for a list with rows to judge.
    public func pruned(knownMeetingIDs: [String]) -> MainRoute {
        guard let id = meetingID, !knownMeetingIDs.isEmpty, !knownMeetingIDs.contains(id) else { return self }
        return MainRoute(section: section, meetingID: nil)
    }
}

/// The last section and meeting, kept in UserDefaults so the next open (also after a quit) shows them. The frame is
/// not here: AppKit autosaves it under `MainWindowSpec.frameAutosaveName`.
public enum WindowRestoration {
    public static let sectionKey = "mainWindow.section"
    public static let meetingKey = "mainWindow.meeting"

    /// Whatever is stored, as a route this build can show. Missing, mistyped or unknown values give the defaults.
    /// `advanced` is the switch as it stands: a stored Models section is not shown while it is off.
    public static func load(_ d: UserDefaults, advanced: Bool) -> MainRoute {
        guard let raw = d.object(forKey: sectionKey) as? String, let section = MainSection(rawValue: raw) else { return .default }
        let meeting = d.object(forKey: meetingKey) as? String
        return MainRoute(section: section, meetingID: meeting).resolved(visible: MainWindowSpec.sections(advanced: advanced))
    }

    public static func save(_ route: MainRoute, to d: UserDefaults) {
        d.set(route.section.rawValue, forKey: sectionKey)
        if let id = route.meetingID, !id.isEmpty {
            d.set(id, forKey: meetingKey)
        } else {
            d.removeObject(forKey: meetingKey)
        }
    }
}
