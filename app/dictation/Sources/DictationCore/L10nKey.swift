/// Every user-visible string the main window and the new menu items carry, as
/// its Localizable.strings key. The enum is the source of truth: the window and
/// the menus resolve through it, and the localization test derives the used-key
/// set from `allCases` rather than from a hand-maintained list.
public enum L10nKey: String, CaseIterable {
    // The status menu's "Open OxSay…" row.
    case menuOpenOxSay = "menu.open_oxsay"
    // The status menu's dictation-recovery rows and the unread-paste notice.
    case menuRecentDictations = "menu.recent_dictations"
    case menuPasteLastDictation = "menu.paste_last_dictation"
    case noticePasteUnread = "notice.paste_unread"
    // Pause Music While Dictating: the Settings row and the Automation notice.
    case menuPauseMedia = "menu.pause_media"
    case noticeMediaDenied = "notice.media_denied"
    // The app menu while the app is .regular.
    case menuApp = "menu.app"
    case menuAppAbout = "menu.app.about"
    case menuAppHide = "menu.app.hide"
    case menuAppQuit = "menu.app.quit"
    // The Edit menu: the standard editing keys a text field needs.
    case menuEdit = "menu.edit"
    case menuEditUndo = "menu.edit.undo"
    case menuEditRedo = "menu.edit.redo"
    case menuEditCut = "menu.edit.cut"
    case menuEditCopy = "menu.edit.copy"
    case menuEditPaste = "menu.edit.paste"
    case menuEditSelectAll = "menu.edit.select_all"
    // The Window menu.
    case menuWindow = "menu.window"
    case menuWindowMinimize = "menu.window.minimize"
    case menuWindowClose = "menu.window.close"
    // The main window itself.
    case windowTitle = "window.title"
    case sectionReel = "section.reel"
    case sectionProjects = "section.projects"
    case sectionVoices = "section.voices"
    case sectionDictation = "section.dictation"
    case sectionSettings = "section.settings"
    case placeholderReel = "placeholder.reel"
    case placeholderProjects = "placeholder.projects"
    case placeholderVoices = "placeholder.voices"
    case placeholderDictation = "placeholder.dictation"
    case placeholderSettings = "placeholder.settings"
}
