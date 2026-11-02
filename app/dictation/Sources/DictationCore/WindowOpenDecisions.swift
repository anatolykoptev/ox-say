import Foundation

/// The return to `.accessory` after the main window closes is delayed (`WindowPolicy.accessoryRevertDelay`). An open that
/// lands inside that delay must win: the close hands out a ticket, an open (or a later close) invalidates it, and the
/// delayed block reverts only while its ticket is current.
public struct AccessoryRevert {
    public struct Ticket: Equatable {
        fileprivate let generation: Int
    }

    private var generation = 0

    public init() {}

    /// The window was opened or brought forward: every pending revert is void.
    public mutating func windowOpened() { generation += 1 }

    /// The window closed: the ticket the delayed revert carries.
    public mutating func windowClosed() -> Ticket {
        generation += 1
        return Ticket(generation: generation)
    }

    public func shouldRevert(_ ticket: Ticket) -> Bool { ticket.generation == generation }
}

/// Whether the main window opens by itself at launch: on the first ever launch, never at login and never after an update.
public enum FirstLaunch {
    /// Set on the first launch that reaches the decision, whatever it decides.
    public static let markerKey = "mainWindow.firstLaunchSeen"

    /// Keys earlier versions wrote at launch or on the first hotkey registration. A store that has one was used by a
    /// copy that ran before, so this launch is an update, not a first one. The first two are the hotkey sessions
    /// (`AppDelegate.keyInUseKey`, `speakKeyInUseKey`); the third is the launch migration's marker, which every copy
    /// since #342 wrote on its first run.
    public static let priorRunKeys = ["dictationKeyInUse", "speakKeyInUse", CallPolicy.pickMigrationKey]

    public static func shouldOpenWindow(markerSet: Bool, priorRun: Bool, atLogin: Bool) -> Bool {
        !markerSet && !priorRun && !atLogin
    }

    /// Reads the store, decides, and sets the marker so the decision is made once. Call before anything else writes
    /// the keys in `priorRunKeys` at launch.
    public static func claim(_ d: UserDefaults, atLogin: Bool) -> Bool {
        let open = shouldOpenWindow(markerSet: d.bool(forKey: markerKey),
                                    priorRun: priorRunKeys.contains { d.object(forKey: $0) != nil },
                                    atLogin: atLogin)
        d.set(true, forKey: markerKey)
        return open
    }

    // The launch Apple event: 'oapp' carrying 'prop' = 'lgit' is how launchd's login launch announces itself.
    public static let openApplicationEvent: UInt32 = 0x6F61_7070
    public static let propDataKeyword: UInt32 = 0x7072_6F70
    public static let launchedAsLoginItem: UInt32 = 0x6C67_6974

    public static func isLoginLaunch(eventID: UInt32?, propData: UInt32?) -> Bool {
        eventID == openApplicationEvent && propData == launchedAsLoginItem
    }
}
