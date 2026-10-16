import AppKit
import DictationCore

// A menu-bar app: no Dock icon, no main window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// The accessory menu — the Edit menu alone: ⌘Z/⌘C/⌘V reach a modal's editor
// (the review sheet runs before the main window may ever open) while ⌘Q, ⌘H
// and ⌘W stay unbound where nothing shows the app is active.
MainMenuBar.install(appDelegateTarget: delegate, for: .accessory)
app.run()
