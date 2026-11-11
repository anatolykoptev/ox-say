import AppKit

/// The window configuration of every always-on-top panel the app draws over the user's work: the meeting plate (the
/// recording clock, the record prompt, its questions and errors) and the dictation pill.
///
/// Over ANOTHER app's full-screen Space a panel needs a non-activating panel, level `.screenSaver` (`.statusBar` and
/// `.floating` sit below full-screen content) and `.canJoinAllApplications` (`.canJoinAllSpaces` alone spans the app's
/// own Spaces): Apple DTS, Developer Forums thread 826308; Granola uses `screen-saver` for its recording notices. Apple
/// DTS also asks for an `.accessory` policy, but shipping apps (Granola, Anarlog) draw the same panels from a
/// `.regular` app, so the policy is NOT changed here: it is logged beside every miss, and a live run decides. Applied
/// at construction and again at every show, so nothing that changed the window since leaves it behind.
public enum PlateWindowSpec {
    public static let level: NSWindow.Level = .screenSaver
    public static let collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                                                                         .fullScreenAuxiliary, .stationary]

    public static func apply(to panel: NSPanel, extra: NSWindow.CollectionBehavior = []) {
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = level
        panel.collectionBehavior = collectionBehavior.union(extra)
    }
}

/// What a shown panel does when the window server says it is not on the screen the user is looking at (another
/// app's full-screen Space, a policy that keeps it off). One watch per panel; the panel feeds it the window server's
/// answer and carries out the actions. A recording must never run invisibly: the last step tells the user in a way
/// that does show over a full-screen Space (a notification).
public struct PlateWatch {
    public enum Event: Equatable {
        case missed(Int)
        case recovered
    }

    public enum Action: Equatable {
        case log(Event)
        /// Order the panel front again.
        case reorder
        /// Nothing worked: say so outside the panel. Once per outage.
        case tell
    }

    private var misses = 0
    private var told = false

    public init() {}

    /// `expected`: false while the screen is locked or the display asleep — not a fault and not a miss.
    public mutating func observe(onscreen: Bool, expected: Bool) -> [Action] {
        guard expected else { return [] }
        if onscreen {
            defer { misses = 0; told = false }
            return misses > 0 ? [.log(.recovered)] : []
        }
        misses += 1
        var actions: [Action] = []
        // The first three misses, then every tenth: a long outage is one line a while, not one per poll.
        if misses <= 3 || misses % 10 == 0 { actions.append(.log(.missed(misses))) }
        if misses == 1 {
            actions.append(.reorder)
        } else if !told {
            told = true
            actions.append(.tell)
        }
        return actions
    }
}

/// The recording plate collapses to a small red dot and clock; it never goes away while a recording runs.
public enum PlateCollapse {
    public enum Presentation: Equatable {
        case expanded, collapsed

        /// Collapsed is a smaller panel, not a hidden one.
        public var panelVisible: Bool { true }
    }

    /// Only a recording collapses: a prompt, a question or an error is always shown whole.
    public static func presentation(isRecording: Bool, userCollapsed: Bool) -> Presentation {
        isRecording && userCollapsed ? .collapsed : .expanded
    }
}
