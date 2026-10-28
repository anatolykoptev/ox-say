/// The little persistent memory registration needs (UserDefaults in the app,
/// a dictionary in tests).
public protocol ShortcutStore: AnyObject {
    func string(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)
}

/// What has already been said during this launch, so a menu open that
/// re-registers while a conflict lasts does not repeat it (and beep).
public struct RegistrationGates: Equatable {
    /// "<planned key>|<kind of refusal notice>" of the last refusal said.
    public var refusalShown: String?
    public init() {}
}

/// Registering the dictation key, as pure logic: the loop over the keys to
/// try, what to say and when to stay quiet. The app supplies the real
/// registration as `attempt` and shows the result.
public enum ShortcutRegistration {
    /// Where the key macOS last took (and was announced) is remembered.
    public static let macOSNoticeKey = "fallbackNoticeShownFor"

    public struct Outcome<Handle: AnyObject> {
        /// The index that registered; nil when none did.
        public var registered: Int?
        /// The registration that took, handed back so the caller keeps exactly
        /// this one; refused attempts are not retained.
        public var hotKey: Handle?
        /// The `Choice.id` to remember as the key in use; nil leaves the
        /// remembered one alone (nothing registered).
        public var keyInUse: String?
        /// Indexes another app refused, in the order tried.
        public var failed: [Int]
        /// What to say now (gates applied), macOS first.
        public var notices: [ShortcutMenu.Notice]
        /// The registered key changed, so a status line left by an earlier
        /// hotkey problem is stale. An unchanged key leaves unrelated
        /// status lines (unread paste, update) alone.
        public var clearsStatusLine: Bool
        /// The menu rows with the check on the key dictation is on.
        public var items: [ShortcutMenu.Item]
    }

    /// - Parameters:
    ///   - previous: the index registered before this run (nil: none).
    ///   - attempt: tries to register an index; the registration when it took, nil when refused.
    public static func run<Handle: AnyObject>(plan: ShortcutMenu.Plan, choices: [ShortcutMenu.Choice], previous: Int?,
                           attempt: (Int) -> Handle?, gates: inout RegistrationGates,
                           store: ShortcutStore) -> Outcome<Handle> {
        func items(on registered: Int?) -> [ShortcutMenu.Item] {
            plan.items.indices.map {
                ShortcutMenu.Item(title: plan.items[$0].title, isEnabled: plan.items[$0].isEnabled,
                                  isOn: $0 == registered)
            }
        }
        guard let planned = plan.key else {
            gates.refusalShown = nil
            return Outcome(registered: nil, hotKey: nil, keyInUse: nil, failed: [], notices: [.allMacOS], clearsStatusLine: false,
                           items: items(on: nil))
        }
        var failed: [Int] = []
        var registered: Int?
        var winner: Handle?
        while let index = ShortcutMenu.next(plan, failed: failed) {
            if let handle = attempt(index) { registered = index; winner = handle; break }
            failed.append(index)
        }
        if registered != nil && plan.movedFrom == nil { store.setString(nil, forKey: macOSNoticeKey) }
        let all = ShortcutMenu.registrationNotices(plan: plan, choices: choices, registered: registered,
                                                   failed: failed)
        let refusal = all.first { !$0.isAboutMacOS }
        let refusalKey = refusal.map { "\(choices[planned].title)|\($0.kind)" }
        let refusedBefore = refusalKey != nil && gates.refusalShown == refusalKey
        gates.refusalShown = failed.contains(planned) ? refusalKey : nil
        let notices = all.filter { part in
            guard part.isAboutMacOS else { return !refusedBefore }
            guard let from = plan.movedFrom, choices.indices.contains(from),
                  store.string(forKey: macOSNoticeKey) != choices[from].title else { return false }
            store.setString(choices[from].title, forKey: macOSNoticeKey)
            return true
        }
        return Outcome(registered: registered, hotKey: winner,
                       keyInUse: registered.map { choices[$0].id }, failed: failed, notices: notices,
                       clearsStatusLine: registered != nil && registered != previous,
                       items: items(on: registered))
    }
}
