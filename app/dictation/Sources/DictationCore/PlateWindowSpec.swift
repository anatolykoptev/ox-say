import AppKit

/// The window configuration of every always-on-top panel the app draws over the user's work: the meeting plate (the
/// recording clock, the record prompt, its questions and errors) and the dictation pill.
///
/// Over ANOTHER app's full-screen Space a panel needs all of: an `.accessory` activation policy, a non-activating
/// panel, level `.screenSaver` (`.statusBar` and `.floating` sit below full-screen content) and
/// `.canJoinAllApplications` (`.canJoinAllSpaces` alone spans the app's own Spaces). Apple DTS, Developer Forums
/// thread 826308. The policy is `PlatePolicyHold`'s; the rest is here, once, so no panel carries a second copy.
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

extension WindowPolicy.Policy {
    public var nsPolicy: NSApplication.ActivationPolicy {
        switch self {
        case .regular: return .regular
        case .accessory: return .accessory
        }
    }
}

/// Panels that must be seen can need the app to be `.accessory`: a `.regular` app's panels do not appear over another
/// app's full-screen Space. While any holder is up the policy is `.accessory`, whatever the main window would want;
/// the Dock icon and the menu bar come back when the last holder lets go.
public final class PlatePolicyHold {
    public static let shared = PlatePolicyHold()
    private var holders: Set<String> = []
    /// The app re-evaluates its activation policy when this fires.
    public var onChange: (() -> Void)?

    public init() {}

    public var isHeld: Bool { !holders.isEmpty }

    public func effective(_ wanted: WindowPolicy.Policy) -> WindowPolicy.Policy { isHeld ? .accessory : wanted }

    /// True when the hold as a whole changed.
    @discardableResult
    public func set(_ name: String, held: Bool) -> Bool {
        let before = isHeld
        if held { holders.insert(name) } else { holders.remove(name) }
        guard isHeld != before else { return false }
        onChange?()
        return true
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
        /// The app is `.regular`: hold it `.accessory` so the panel can join the full-screen Space.
        case holdAccessory
        /// Nothing worked: say so outside the panel. Once per outage.
        case tell
    }

    private var misses = 0
    private var told = false

    public init() {}

    /// `expected`: false while the screen is locked or the display asleep — not a fault and not a miss.
    public mutating func observe(onscreen: Bool, expected: Bool, policy: WindowPolicy.Policy) -> [Action] {
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
        } else if misses == 2 && policy == .regular {
            actions.append(.holdAccessory)
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
