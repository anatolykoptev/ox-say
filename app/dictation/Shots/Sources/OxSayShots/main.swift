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
    /// Sidebar scenes: the Advanced switch drawn, every section listed (the build lists only the live ones).
    var sidebar: Bool = false
    var advanced = false
    var query: (Bool) -> String = { _ in "" }
    var find: ((Bool) -> String)?
    var data: (Date, Bool) -> MainWindowData
    /// A sheet scene: the design sheet alone in the window (a sheet is a window of its own, which `screencapture -l` of
    /// the main window would not include). The flow is driven through its own public steps.
    var sheet: ((Bool) -> VoiceDesignFlow)?
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
    func loading(_ d: MainWindowData) -> MainWindowData { var d = d; d.meetings = []; d.details = [:]; d.meetingsLoad = .loading; return d }
    func down(_ d: MainWindowData) -> MainWindowData {
        var d = d; d.meetings = []; d.details = [:]
        d.meetingsLoad = .failed(MeetingErrorText.sentence(StudioError.daemonUnreachable, action: .refresh))
        return d
    }
    /// A short notice on top of the list (Copy as Markdown done).
    func stale(_ d: MainWindowData) -> MainWindowData {
        var d = d
        d.notice = L10nKey.meetingErrDeleteBusy.text
        return d
    }
    func voices(_ d: MainWindowData, _ change: (inout VoicesValues) -> Void) -> MainWindowData {
        var d = d; change(&d.voices); return d
    }
    /// The sheet's flow after the given steps, typed text in the language of the shot.
    func flow(_ ru: Bool, label: String = "", _ steps: (inout VoiceDesignFlow) -> Void) -> VoiceDesignFlow {
        var f = VoiceDesignFlow(description: ru ? "Спокойный диктор, мужской голос, неспешный и тёплый" : "A calm male narrator, unhurried and warm",
                                sentence: DesignForm.defaultSentence, label: label)
        steps(&f)
        return f
    }
    func takes() -> [DesignTake] {
        (1...3).map { DesignTake(path: "/t/\($0).wav", durationSeconds: 6, suggestedName: "calm-narrator-\($0)",
                                warning: $0 == 3 ? "this take may contain babble" : nil) }
    }
    let scenes: [Scene] = [
        Scene(name: "meetings-list", section: .meetings, meeting: nil) { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "meeting-notes", section: .meetings, meeting: "m7") { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "meeting-speakers", section: .meetings, meeting: "m7", tab: .speakers) { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "meeting-transcript", section: .meetings, meeting: "m7", tab: .transcript) { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "meeting-transcript-only", section: .meetings, meeting: "m3") { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "meetings-recording", section: .meetings, meeting: nil) { PreviewData.recording(now: $0, ru: $1) },
        Scene(name: "meetings-empty", section: .meetings, meeting: nil) { empty(PreviewData.make(now: $0, ru: $1)) },
        Scene(name: "meetings-off", section: .meetings, meeting: nil) { off(PreviewData.make(now: $0, ru: $1)) },
        Scene(name: "meetings-loading", section: .meetings, meeting: nil) { loading(PreviewData.make(now: $0, ru: $1)) },
        Scene(name: "meetings-down", section: .meetings, meeting: nil) { down(PreviewData.make(now: $0, ru: $1)) },
        Scene(name: "meetings-notice", section: .meetings, meeting: "m7") { stale(PreviewData.make(now: $0, ru: $1)) },
        // MW3: search, find in the transcript, play from a line.
        Scene(name: "search-results", section: .meetings, meeting: "m7", query: { $0 ? "оплату" : "payment" }) { PreviewData.searching(now: $0, ru: $1) },
        Scene(name: "search-none", section: .meetings, meeting: nil, query: { $0 ? "йогурт" : "yoghurt" }) { PreviewData.searchingNothing(now: $0, ru: $1) },
        Scene(name: "transcript-find", section: .meetings, meeting: "m7", tab: .transcript, find: { $0 ? "пятниц" : "friday" }) { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "transcript-playing", section: .meetings, meeting: "m7", tab: .transcript) { PreviewData.playing(now: $0, ru: $1) },
        Scene(name: "audio-removed", section: .meetings, meeting: "m5", tab: .transcript) { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "sidebar-simple", section: .meetings, meeting: nil, sidebar: true) { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "sidebar-advanced", section: .meetings, meeting: nil, sidebar: true, advanced: true) { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "dictation", section: .dictation, meeting: nil) { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "voices-list", section: .voices, meeting: nil) { PreviewData.make(now: $0, ru: $1) },
        Scene(name: "voices-playing", section: .voices, meeting: nil) { voices(PreviewData.make(now: $0, ru: $1)) { $0.playingID = "studio-mara" } },
        Scene(name: "voices-empty", section: .voices, meeting: nil) { voices(PreviewData.make(now: $0, ru: $1)) { $0.entries = []; $0.voices = []; $0.russianVoice = nil } },
        Scene(name: "voices-loading", section: .voices, meeting: nil) { voices(PreviewData.make(now: $0, ru: $1)) { $0.entries = []; $0.voices = []; $0.load = .loading } },
        Scene(name: "voices-down", section: .voices, meeting: nil) {
            voices(PreviewData.make(now: $0, ru: $1)) {
                $0.entries = []; $0.voices = []
                $0.load = .failed(StudioError.daemonUnreachable.message())
            }
        },
        Scene(name: "voices-stale", section: .voices, meeting: nil) {
            voices(PreviewData.make(now: $0, ru: $1)) { $0.load = .failed(StudioError.timedOut.message()) }
        },
        Scene(name: "voices-design-unavailable", section: .voices, meeting: nil) {
            voices(PreviewData.make(now: $0, ru: $1)) { $0.designAvailability = .unavailable(StudioMenu.unavailableText(reason: nil)) }
        },
        Scene(name: "voices-design-installable", section: .voices, meeting: nil) {
            voices(PreviewData.make(now: $0, ru: $1)) { $0.designAvailability = .installable }
        },
        Scene(name: "voice-design-form", section: .voices, meeting: nil, height: 420, data: { PreviewData.make(now: $0, ru: $1) },
              sheet: { ru in flow(ru, label: ru ? "Мой диктор" : "My narrator") { _ in } }),
        Scene(name: "voice-design-designing", section: .voices, meeting: nil, height: 230, data: { PreviewData.make(now: $0, ru: $1) },
              sheet: { ru in flow(ru) { f in _ = f.submit(taken: []) } }),
        Scene(name: "voice-design-review", section: .voices, meeting: nil, height: 330, data: { PreviewData.make(now: $0, ru: $1) },
              sheet: { ru in flow(ru, label: ru ? "Мой диктор" : "My narrator") { f in _ = f.submit(taken: []); f.designed(takes()) } }),
        Scene(name: "voice-design-review-warning", section: .voices, meeting: nil, height: 380, data: { PreviewData.make(now: $0, ru: $1) },
              sheet: { ru in flow(ru) { f in _ = f.submit(taken: []); f.designed(takes()); _ = f.next(); _ = f.next() } }),
        Scene(name: "voice-design-name-taken", section: .voices, meeting: nil, height: 200, data: { PreviewData.make(now: $0, ru: $1) },
              sheet: { ru in flow(ru, label: ru ? "Мой диктор" : "My narrator") { f in
                  _ = f.submit(taken: []); f.designed(takes()); _ = f.keep(); f.saveAnswered(.nameTaken)
              } }),
        Scene(name: "voice-design-failed", section: .voices, meeting: nil, height: 260, data: { PreviewData.make(now: $0, ru: $1) },
              sheet: { ru in flow(ru) { f in _ = f.submit(taken: []); f.fail(StudioError.timedOut.message()) } }),
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
                model.queryText = scene.query(lang == "ru")
                model.initialFind = scene.find?(lang == "ru")
                model.appsExpanded = scene.appsExpanded
                model.clock = { now }
                model.advanced = scene.advanced
                let hosting: NSViewController
                if let sheet = scene.sheet {
                    hosting = NSHostingController(rootView: VoiceDesignSheet(flow: sheet(lang == "ru")) { _ in })
                } else {
                    hosting = NSHostingController(rootView: scene.sidebar
                        ? MainWindowView(model: model, switchShown: true, live: Set(MainSection.allCases))
                        : MainWindowView(model: model))
                }
                (hosting as? NSHostingController<VoiceDesignSheet>)?.sizingOptions = []
                (hosting as? NSHostingController<MainWindowView>)?.sizingOptions = []
                window.contentViewController = hosting
                window.setContentSize(NSSize(width: scene.sheet == nil ? size.width : 440, height: scene.height))
                window.title = "OxSay"
                window.orderFrontRegardless()
                // Two short spins: the first lays the view out, the second lets lazy rows and the toolbar settle.
                RunLoop.main.run(until: Date().addingTimeInterval(0.9))
                window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                let file = out.appendingPathComponent("\(scene.name)-\(lang)-\(dark ? "dark" : "light").png")
                var captured = false
                if ProcessInfo.processInfo.environment["SHOTS_VIEW_CAPTURE"] == nil {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-o", "-l\(window.windowNumber)", file.path]
                    try? p.run()
                    p.waitUntilExit()
                    captured = p.terminationStatus == 0
                }
                // The screen is locked or the window is not on it (a night run): draw the window's views instead.
                // No title bar and no toolbar, but the content is the same.
                if !captured, let view = window.contentView?.superview ?? window.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    captured = (rep.representation(using: .png, properties: [:])).flatMap { try? $0.write(to: file) } != nil
                }
                print("\(captured ? "ok " : "ERR") \(file.path)")
            }
        }
    }
    window.close()
}

MainActor.assumeIsolated { run() }
