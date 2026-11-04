/// Who the one voice player answers to. A library sample answers to the session (it names the playing voice); a
/// recorded take answers to the record sheet. `sync` stops a player nobody claims — and must not stop the take.
public enum VoicePlayback {
    /// Whether the player is to be stopped: it is sounding, no library preview is named by the session, and no
    /// recorded take is being played.
    public static func shouldStop(previewID: String?, takePlaying: Bool, active: Bool) -> Bool {
        active && previewID == nil && !takePlaying
    }
}
