/// Where the one Find command (⌘F, Edit ▸ Find…) goes. A row in the menu fires the same
/// typed action whatever is on screen; the window asks this which field to wake.
public enum FindTarget: Equatable {
    /// The transcript's own find bar, while a transcript is on screen.
    case transcript
    /// The meetings list's system search field, while the list is up.
    case meetingsSearch

    /// The transcript's bar first — ⌘F searches the text in front of the user — the meetings
    /// search otherwise, and nowhere when neither is showing.
    public static func decide(transcriptOnScreen: Bool, meetingsSearchOnScreen: Bool) -> FindTarget? {
        if transcriptOnScreen { return .transcript }
        return meetingsSearchOnScreen ? .meetingsSearch : nil
    }
}
