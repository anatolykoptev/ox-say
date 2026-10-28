/// The decision behind the "Dictation key" submenu: which offered key
/// dictation should listen to and what each row shows, as a pure function of
/// the live system shortcuts. The app asks on every menu open, so a key macOS
/// freed or took since the last open is reflected right away — the answer
/// carries no AppKit and no registration side effects.
public enum ShortcutMenu {
    /// An offered dictation key, described the way Carbon reports shortcuts.
    public struct Choice: Equatable {
        public var title: String
        public var keyCode: Int
        public var modifiers: Int

        public init(title: String, keyCode: Int, modifiers: Int) {
            self.title = title
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
    }

    /// One submenu row.
    public struct Item: Equatable {
        /// The key's title, suffixed while macOS itself owns the combination.
        public var title: String
        /// Greyed out while the key is a macOS shortcut: picking it would
        /// register a hotkey that fights the system one.
        public var isEnabled: Bool
        /// Checked on the key dictation listens to.
        public var isOn: Bool

        public init(title: String, isEnabled: Bool, isOn: Bool) {
            self.title = title
            self.isEnabled = isEnabled
            self.isOn = isOn
        }
    }

    /// What the app should do: the rows to show, the key to register, and the
    /// key it was forced off when a move happens.
    public struct Plan: Equatable {
        /// Index into `choices` of the key to register; nil when every offered
        /// key is a macOS shortcut and nothing can be registered.
        public var key: Int?
        /// One row per offered key, in the same order as `choices`.
        public var items: [Item]
        /// Index of the key that was relied on (stored pick, or the active key)
        /// but is now a macOS shortcut. nil means no forced move — nothing to
        /// announce.
        public var movedFrom: Int?

        public init(key: Int?, items: [Item], movedFrom: Int?) {
            self.key = key
            self.items = items
            self.movedFrom = movedFrom
        }
    }

    /// Decides the key and the rows from the system shortcuts right now.
    ///
    /// A stored pick that is still free always wins; a stored pick macOS now
    /// owns falls back to the first free offer. With no stored pick the key
    /// already registered stays while it is free — a working key is not moved
    /// for preference alone, because a shortcut freed in System Settings was
    /// usually freed for something else and claiming it would fight that —
    /// and only losing it moves dictation to the first free offer.
    ///
    /// `lastSession` is the key the previous run registered. It stands in for
    /// `active` until this run has registered one, so a relaunch (the app
    /// starts at login) neither claims a key freed meanwhile nor moves off a
    /// key macOS took without saying so.
    public static func plan(stored: Choice?, active: Choice?, lastSession: Choice? = nil,
                            choices: [Choice], system: [SystemShortcut]) -> Plan {
        let active = active ?? lastSession
        func isFree(_ choice: Choice) -> Bool {
            !ShortcutConflict.taken(keyCode: choice.keyCode, modifiers: choice.modifiers, by: system)
        }
        let key: Int?
        var movedFrom: Int? = nil
        if let stored {
            if let index = choices.firstIndex(of: stored), isFree(stored) {
                key = index
            } else {
                movedFrom = choices.firstIndex(of: stored)
                key = choices.firstIndex(where: isFree)
            }
        } else if let active, let index = choices.firstIndex(of: active), isFree(active) {
            key = index
        } else {
            movedFrom = active.flatMap { choices.firstIndex(of: $0) }
            key = choices.firstIndex(where: isFree)
        }
        let items = choices.indices.map { index in
            let choice = choices[index]
            let free = isFree(choice)
            return Item(title: free ? choice.title : "\(choice.title) (a macOS shortcut)",
                        isEnabled: free, isOn: index == key)
        }
        return Plan(key: key, items: items, movedFrom: movedFrom)
    }

    /// The key to try next when registering the plan: the planned key first,
    /// then the other keys macOS does not own, in offered order; `failed` are
    /// the indexes whose registration was refused (another app holds them).
    /// nil when nothing is left, or when every key is a macOS shortcut.
    public static func next(_ plan: Plan, failed: [Int]) -> Int? {
        guard let planned = plan.key else { return nil }
        if !failed.contains(planned) { return planned }
        return plan.items.indices.first { plan.items[$0].isEnabled && !failed.contains($0) }
    }

    /// One thing worth telling the user after the keys were tried.
    public enum Notice: Equatable {
        /// macOS took a key and dictation moved to `now`.
        case movedByMacOS(taken: String, now: String)
        /// macOS took a key and no other key could be registered.
        case macOSOwns(taken: String)
        /// The planned key was refused by another app; dictation is on `now`.
        case fellBack(failed: String, now: String)
        /// The only key tried was refused: dictation has no hotkey.
        case taken(String)
        /// Every key tried was refused; `String` lists them.
        case allTaken(String)

        /// The macOS ones are told once per taken key, across launches; the
        /// others once per failing key per launch.
        public var isAboutMacOS: Bool {
            switch self {
            case .movedByMacOS, .macOSOwns: return true
            case .fellBack, .taken, .allTaken: return false
            }
        }

        public var text: String {
            switch self {
            case .movedByMacOS(let taken, let now): return L10nKey.noticeHotkeyMacOSMoved.text(taken, now)
            case .macOSOwns(let taken): return L10nKey.noticeHotkeyMacOSOwns.text(taken)
            case .fellBack(let failed, let now): return L10nKey.noticeHotkeyFellBack.text(failed, now)
            case .taken(let key): return L10nKey.noticeHotkeyTaken.text(key)
            case .allTaken(let keys): return L10nKey.noticeHotkeyAllTaken.text(keys)
            }
        }
    }

    /// What to say once registration is over, in the order to say it: the
    /// macOS part first. `registered` is the index that took, nil when none
    /// did; `failed` the indexes another app refused. Nothing to say when the
    /// planned key registered and macOS moved nothing.
    public static func registrationNotices(plan: Plan, choices: [Choice], registered: Int?,
                                           failed: [Int]) -> [Notice] {
        guard plan.key != nil else { return [] }
        func title(_ index: Int) -> String { choices[index].title }
        var notices: [Notice] = []
        if let from = plan.movedFrom, choices.indices.contains(from) {
            notices.append(registered.map { .movedByMacOS(taken: title(from), now: title($0)) }
                           ?? .macOSOwns(taken: title(from)))
        }
        let refused = failed.filter(choices.indices.contains).map(title)
        guard !refused.isEmpty else { return notices }
        if let registered {
            notices.append(.fellBack(failed: refused.joined(separator: ", "), now: title(registered)))
        } else if refused.count == 1 {
            notices.append(.taken(refused[0]))
        } else {
            notices.append(.allTaken(refused.joined(separator: ", ")))
        }
        return notices
    }

    /// The parts as the one message the pill can hold, in order.
    public static func sentence(_ notices: [Notice]) -> String {
        notices.map(\.text).joined(separator: " ")
    }

    /// What opening the menu does with a fresh plan. Idle, a planned key that
    /// differs from the registered one is registered, and the rows are the
    /// plan's. Busy (recording or transcribing), nothing re-registers, so the
    /// checkmark stays on the key that is actually registered — the rows'
    /// titles and enabled state still follow the system shortcuts.
    public static func onOpen(_ plan: Plan, registered: Int?, idle: Bool)
        -> (items: [Item], register: Bool) {
        if idle && plan.key != registered {
            return (plan.items, true)
        }
        let items = plan.items.indices.map { index in
            Item(title: plan.items[index].title, isEnabled: plan.items[index].isEnabled,
                 isOn: index == registered)
        }
        return (items, false)
    }
}
