/// Every user-visible string the main window and the new menu items carry, as
/// its Localizable.strings key. The enum is the source of truth: the window and
/// the menus resolve through it, and the localization test derives the used-key
/// set from `allCases` rather than from a hand-maintained list.
public enum L10nKey: String, CaseIterable {
    // The status menu's "Open OxSay…" row.
    case menuOpenOxSay = "menu.open_oxsay"
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
    // The Reel editor (section.reel's detail).
    case reelScript = "reel.script"
    case reelOpenDocument = "reel.open_document"
    case reelReadingDocument = "reel.reading_document"
    case reelVoice = "reel.voice"
    case reelDefaultVoice = "reel.default_voice"
    case reelPhrases = "reel.phrases"
    case reelCreate = "reel.create"
    case reelChecking = "reel.checking"
    case reelServiceMissing = "reel.service_missing"
    case reelStop = "reel.stop"
    case reelStopTitle = "reel.stop_title"
    case reelStopText = "reel.stop_text"
    case reelStopConfirm = "reel.stop_confirm"
    case reelKeepGoing = "reel.keep_going"
    case reelContinueBattery = "reel.continue_battery"
    case reelDuration = "reel.duration"
    case reelExport = "reel.export"
    case reelShowInFinder = "reel.show_in_finder"
    case reelReadError = "reel.read_error"
    case reelNothingToRead = "reel.nothing_to_read"
    case reelExportError = "reel.export_error"
}
