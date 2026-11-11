import Foundation

/// Where the main window is pointed: a section, for Meetings the meeting that is open, for Озвучка the voiceover. Pure, so the decisions
/// about opening and restoring the window are tested without a window.
public struct MainRoute: Equatable {
    public var section: MainSection
    public var meetingID: String?
    /// The voiceover project that is open on Озвучка (a notification's click points here).
    public var speakID: String?

    public init(section: MainSection = MainWindowSpec.firstRunSection, meetingID: String? = nil, speakID: String? = nil) {
        self.section = section
        self.meetingID = meetingID
        self.speakID = speakID
    }

    /// The first-run section, nothing open: Voiceover once it is live, the Meetings list until then.
    public static var `default`: MainRoute { MainRoute(section: MainWindowSpec.firstRunSection) }

    /// A route resolved against what this build shows: a section the sidebar does not list falls back to the
    /// default (and takes its meeting with it); an empty meeting id is no meeting.
    public func resolved(visible: [MainSection] = MainWindowSpec.sections(advanced: true)) -> MainRoute {
        guard visible.contains(section) else { return .default }
        return MainRoute(section: section, meetingID: meetingID.flatMap { $0.isEmpty ? nil : $0 },
                         speakID: speakID.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The route against the meetings that exist: an id that is not among them is dropped, so the list shows
    /// instead of an empty detail. An empty list says nothing about the id — the daemon may still be coming
    /// up — so it is left for a list with rows to judge.
    public func pruned(knownMeetingIDs: [String]) -> MainRoute {
        guard let id = meetingID, !knownMeetingIDs.isEmpty, !knownMeetingIDs.contains(id) else { return self }
        return MainRoute(section: section, meetingID: nil, speakID: speakID)
    }

    /// The same for the voiceover: a project the daemon no longer lists is dropped, so the page shows its list. An empty
    /// list says nothing yet and keeps the id.
    public func pruned(knownSpeakIDs: [String]) -> MainRoute {
        guard let id = speakID, !knownSpeakIDs.isEmpty, !knownSpeakIDs.contains(id) else { return self }
        return MainRoute(section: section, meetingID: meetingID, speakID: nil)
    }
}

/// The last section and meeting, kept in UserDefaults so the next open (also after a quit) shows them. The frame is
/// not here: AppKit autosaves it under `MainWindowSpec.frameAutosaveName`.
public enum WindowRestoration {
    public static let sectionKey = "mainWindow.section"
    public static let meetingKey = "mainWindow.meeting"
    public static let speakKey = "mainWindow.speak"

    /// Whatever is stored, as a route this build can show. Missing, mistyped or unknown values give the defaults.
    /// `advanced` is the switch as it stands: a stored Models section is not shown while it is off.
    public static func load(_ d: UserDefaults, advanced: Bool) -> MainRoute {
        guard let raw = d.object(forKey: sectionKey) as? String, let section = MainSection(rawValue: raw) else { return .default }
        let meeting = d.object(forKey: meetingKey) as? String
        let speak = d.object(forKey: speakKey) as? String
        return MainRoute(section: section, meetingID: meeting, speakID: speak).resolved(visible: MainWindowSpec.sections(advanced: advanced))
    }

    public static func save(_ route: MainRoute, to d: UserDefaults) {
        d.set(route.section.rawValue, forKey: sectionKey)
        if let id = route.meetingID, !id.isEmpty {
            d.set(id, forKey: meetingKey)
        } else {
            d.removeObject(forKey: meetingKey)
        }
        if let id = route.speakID, !id.isEmpty {
            d.set(id, forKey: speakKey)
        } else {
            d.removeObject(forKey: speakKey)
        }
    }
}
