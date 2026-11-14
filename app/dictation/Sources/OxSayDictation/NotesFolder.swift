import AppKit
import DictationCore

/// The notes folder's two user actions, shared by the Meetings menu and the main window so they cannot drift.
enum NotesFolder {
    /// Opens the folder in Finder, making it first when it does not exist yet.
    static func open(_ defaults: UserDefaults) {
        let folder = MeetingSettings.folder(defaults)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Asks for a folder; the picked URL, nil on cancel. Storing is the caller's one step
    /// (`MeetingSettingsModel.folderPicked` in the window, `MeetingSettings.setFolder` in the
    /// menu), so the save and the iCloud recompute cannot drift apart.
    static func choose(_ defaults: UserDefaults) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = MeetingSettings.folder(defaults)
        panel.prompt = L10nKey.menuMeetingChooseFolder.text
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
