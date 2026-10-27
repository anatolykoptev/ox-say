import AppKit
import DictationCore
import MainWindowUI
import SwiftUI

// Renders the main window with sample data to PNG files, in English and Russian, light and dark.
//
//   OxSayShots <app/dictation dir> <output dir>
//
// SwiftUI's List, Form and NavigationSplitView are AppKit-backed and draw nothing through
// ImageRenderer, so each shot is a real NSWindow captured with `screencapture -l` (a window of
// this process: no Screen Recording permission is asked). The app's own bundle, hotkeys,
// daemon and UserDefaults are never touched: nothing but MainWindowUI and sample data runs.

/// A window that claims to be key (this does not change how the window server paints it as unfocused).
final class ShotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

struct Scene {
    var name: String
    var section: MainSection
    var meeting: String?
    var tab: MeetingTab = .notes
    var height: CGFloat = 680
    var appsExpanded = false
    var data: (Date, Bool) -> MainWindowData
}

@MainActor func run() {
    let args = CommandLine.arguments
    guard args.count == 3 else {
        FileHandle.standardError.write(Data("usage: OxSayShots <app/dictation dir> <output dir>\n".utf8))
        exit(2)
    }
    let root = URL(fileURLWithPath: args[1], isDirectory: true)
    let out = URL(fileURLWithPath: args[2], isDirectory: true)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    let app = NSApplication.shared
    // .prohibited: the harness never takes focus. The shots therefore show an unfocused window
    // (grey title buttons, grey selection, pale switches); a focused one has accent colours.
    app.setActivationPolicy(.prohibited)

    let cal = Calendar(identifier: .gregorian)
    var parts = DateComponents()
    parts.year = 2026; parts.month = 10; parts.day = 26; parts.hour = 18; parts.minute = 30
    let now = cal.date(from: parts)!

    func empty(_ d: MainWindowData) -> MainWindowData { var d = d; d.meetings = []; d.details = [:]; return d }
    func off(_ d: MainWindowData) -> MainWindowData { var d = d; d.meetingSettings.enabled = false; return d }
    let scenes: [Scene] = [
        Scene(name: "meetings-list", section: .meetings, meeting: nil) { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "meeting-notes", section: .meetings, meeting: "m7") { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "meeting-speakers", section: .meetings, meeting: "m7", tab: .speakers) { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "meeting-transcript", section: .meetings, meeting: "m7", tab: .transcript) { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "meeting-transcript-only", section: .meetings, meeting: "m3") { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "meetings-recording", section: .meetings, meeting: nil) { PreviewData.recording(now: $0, ru: $1) },
        Scene(name: "meetings-empty", section: .meetings, meeting: nil) { empty(PreviewData.make(now: $0, ru: $1)) },
        Scene(name: "meetings-off", section: .meetings, meeting: nil) { off(PreviewData.make(now: $0, ru: $1)) },
        Scene(name: "dictation", section: .dictation, meeting: nil) { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "voices", section: .voices, meeting: nil) { PreviewData.make(now: $0, ru: $1) },
        // Settings is taller than a window: the shot is made as tall as the screen allows.
        Scene(name: "settings", section: .settings, meeting: nil, height: 1100) { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "settings-apps", section: .settings, meeting: nil, height: 1100, appsExpanded: true) { PreviewData.make(now: $0, ru: $1) },
    ]

    let size = NSSize(width: 980, height: 680)
    let window = ShotWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable],
                            backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // Only these two flags are asked for on the command line, to keep a run short.
    let only = ProcessInfo.processInfo.environment["SHOTS_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }

    for lang in ["en", "ru"] {
        guard let bundle = Bundle(path: root.appendingPathComponent("Resources/\(lang).lproj").path) else {
            FileHandle.standardError.write(Data("no \(lang).lproj under \(root.path)\n".utf8)); exit(1)
        }
        L10nBundle.bundle = bundle
        L10nBundle.locale = Locale(identifier: lang)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for scene in scenes {
                if let only, !only.contains(scene.name) { continue }
                let model = MainWindowModel(data: scene.data(now, lang == "ru"), section: scene.section,
                                            selectedMeeting: scene.meeting)
                model.initialMeetingTab = scene.tab
                model.appsExpanded = scene.appsExpanded
                model.clock = { now }
                window.contentViewController = NSHostingController(rootView: MainWindowView(model: model))
                window.setContentSize(NSSize(width: size.width, height: scene.height))
                window.title = "OxSay"
                window.orderFrontRegardless()
                // Two short spins: the first lays the view out, the second lets lazy rows and the toolbar settle.
                RunLoop.main.run(until: Date().addingTimeInterval(0.9))
                window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                let file = out.appendingPathComponent("\(scene.name)-\(lang)-\(dark ? "dark" : "light").png")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l\(window.windowNumber)", file.path]
                try? p.run()
                p.waitUntilExit()
                print("\(p.terminationStatus == 0 ? "ok " : "ERR") \(file.path)")
            }
        }
    }
    window.close()
}

MainActor.assumeIsolated { run() }
