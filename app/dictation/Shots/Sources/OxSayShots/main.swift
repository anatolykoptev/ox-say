import AppKit
import ImageIO
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
//
// SHOTS_PROBE=1 (or =edges) prints PROBE lines instead of PNGs for the sidebar scenes: the sidebar tables' rows and
// selection, the key-view loop, and (edges) the sidebar's width limits and collapse. It reads AppKit state, so it also
// works on a locked screen. SHOTS_SIDEBAR_SIZE_MODE=1|2|3 sets the process's sidebar icon size (small, medium, large).

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
    /// A sheet scene: the data opens a sheet on the Голоса page, exactly as the app does, and SwiftUI attaches it to
    /// the main window. A sheet is a window of its own, which `screencapture -l` of the main window leaves out, so the
    /// shot is the main window with the sheet window composited at its on-screen offset.
    var sheet = false
}

/// `screencapture -l` of one window of this process (no Screen Recording permission is asked); true when it wrote `file`.
func screencapture(_ w: NSWindow, to file: URL) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l\(w.windowNumber)", file.path]
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: file.path)
}

func cgImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func writePNG(_ image: CGImage, to file: URL) -> Bool {
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:]).flatMap { try? $0.write(to: file) } != nil
}

/// The sheet drawn onto the parent's image at its on-screen offset (SheetPlacement): one PNG, as a person sees the window.
func composite(main: CGImage, mainFrame: NSRect, sheet: CGImage, sheetFrame: NSRect) -> CGImage? {
    let scale = CGFloat(main.width) / mainFrame.width
    guard let ctx = CGContext(data: nil, width: main.width, height: main.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(main, in: CGRect(x: 0, y: 0, width: main.width, height: main.height))
    ctx.draw(sheet, in: SheetPlacement.rect(main: mainFrame, sheet: sheetFrame, scale: scale))
    return ctx.makeImage()
}

/// The window (and its attached sheet, if any) through `screencapture`, into `file`. `-l<main>` leaves the sheet out;
/// `-l<sheet>` returns the sheet together with its parent, already composed by the window server. When the sheet capture
/// is the size of the parent it is taken as the whole shot; otherwise (a sheet-sized image) the sheet is drawn onto the
/// parent's capture at its on-screen offset. A sheet capture that fails is a failure, never a sheet-less file.
func captureWindows(_ window: NSWindow, sheet: NSWindow?, to file: URL) -> Bool {
    guard let sheet else { return screencapture(window, to: file) }
    let main = file.deletingLastPathComponent().appendingPathComponent("main-part-\(file.lastPathComponent)")
    let part = file.deletingLastPathComponent().appendingPathComponent("sheet-part-\(file.lastPathComponent)")
    defer { for u in [main, part] { try? FileManager.default.removeItem(at: u) } }
    try? FileManager.default.removeItem(at: file)
    guard screencapture(window, to: main), screencapture(sheet, to: part), let m = cgImage(main), let s = cgImage(part) else { return false }
    if abs(s.width - m.width) <= 2 && abs(s.height - m.height) <= 2 { return writePNG(s, to: file) }
    guard let both = composite(main: m, mainFrame: window.frame, sheet: s, sheetFrame: sheet.frame) else { return false }
    return writePNG(both, to: file)
}

/// The fallback: `cacheDisplay` of each window's frame view, the sheet's drawn at its offset. A sheet scene whose sheet
/// cannot be drawn is an ERR, never a sheet-less file.
func drawWindows(_ window: NSWindow, sheet: NSWindow?, to file: URL) -> Bool {
    func image(_ w: NSWindow) -> CGImage? {
        guard let view = w.contentView?.superview ?? w.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }
    guard let m = image(window) else { return false }
    guard let sheet else { return writePNG(m, to: file) }
    guard let s = image(sheet), let both = composite(main: m, mainFrame: window.frame, sheet: s, sheetFrame: sheet.frame) else { return false }
    return writePNG(both, to: file)
}

// MARK: - Sidebar probe (SHOTS_PROBE=1): reads the sidebar's real AppKit state instead of looking at pixels.

func sidebarTables(_ v: NSView, in window: NSWindow) -> [NSTableView] {
    var found: [NSTableView] = []
    if let t = v as? NSTableView, t.convert(t.bounds, to: nil).midX < 260 { found.append(t) }
    for s in v.subviews { found += sidebarTables(s, in: window) }
    return found.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
}

func firstText(_ v: NSView) -> String? {
    if let f = v as? NSTextField, !f.stringValue.isEmpty { return f.stringValue }
    for s in v.subviews { if let t = firstText(s) { return t } }
    return nil
}

/// One line per sidebar table: its rows, which are selected, its height, its place from the top of the window.
@MainActor func describeSidebar(_ window: NSWindow, _ model: MainWindowModel, _ tag: String) {
    guard let root = window.contentView else { return }
    let tables = sidebarTables(root, in: window)
    var selectedTotal = 0
    for (i, t) in tables.enumerated() {
        let rows = t.selectedRowIndexes.map { String($0) }
        selectedTotal += t.selectedRowIndexes.count
        let w = t.convert(t.bounds, to: nil)
        let top = root.bounds.height - w.maxY
        let clip = t.enclosingScrollView
        print("PROBE \(tag) table\(i) nrows=\(t.numberOfRows) selectedRows=\(rows) selected=\(t.selectedRowIndexes.count) rowH=\(t.rowHeight) y=\(Int(top)) h=\(Int(w.height)) scrollH=\(Int(clip?.frame.height ?? -1)) bottomInset=\(Int(clip?.contentInsets.bottom ?? -1)) first=\(window.firstResponder === t) ax=\(t.accessibilityRole()?.rawValue ?? "-")/\(t.accessibilityLabel() ?? "-")/rows=\(t.accessibilityRows()?.count ?? -1)")
    }
    print("PROBE \(tag) model=\(model.section) highlights=\(selectedTotal) tables=\(tables.count)")
}

func spin(_ s: Double = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

/// A real click: the mouse-up is queued first so the table's tracking loop finds it.
func click(_ window: NSWindow, _ table: NSTableView, row: Int) {
    let r = table.rect(ofRow: row)
    let loc = table.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
    func ev(_ t: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let hit = window.contentView?.hitTest(window.contentView!.convert(loc, from: nil))
    print("PROBE click row \(row) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") isTable=\(hit === table) loc=\(loc) key=\(window.isKeyWindow)")
    NSApp.postEvent(ev(.leftMouseUp), atStart: false)
    window.sendEvent(ev(.leftMouseDown))
    spin(0.3)
    // Synthetic mouse events do not select in this headless window (checked: the table is the hit view, nothing moves),
    // so the row is selected through the table's own API, which fires the same selection-did-change a click does.
    if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
}

func key(_ window: NSWindow, _ code: UInt16, _ chars: String) {
    for t in [NSEvent.EventType.keyDown, .keyUp] {
        let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: chars,
                                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        window.sendEvent(e)
    }
}

@MainActor func probeSidebar(_ window: NSWindow, _ model: MainWindowModel, _ label: String) {
    guard let root = window.contentView else { return }
    describeSidebar(window, model, "\(label) start")
    probeKeyLoop(window, label + " start")
    var tables = sidebarTables(root, in: window)
    // Selection by a real click, each way round.
    if let settings = tables.last, tables.count >= 2 {
        click(window, settings, row: 0); spin()
        describeSidebar(window, model, "\(label) after-click-settings")
        tables = sidebarTables(root, in: window)
        click(window, tables[0], row: 1); spin()
        describeSidebar(window, model, "\(label) after-click-main-row1")
        tables = sidebarTables(root, in: window)
        click(window, tables.last!, row: 0); spin()
    } else if let only = tables.first {
        let last = only.numberOfRows - 1
        click(window, only, row: last); spin()
        describeSidebar(window, model, "\(label) after-click-last-row")
        click(window, only, row: 0); spin()
        describeSidebar(window, model, "\(label) after-click-first-row")
    }
    // Model-driven selection.
    for s in [MainSection.dictation, .settings, .voices] where model.section != s {
        model.section = s; spin()
        describeSidebar(window, model, "\(label) model=\(s)")
    }
    // Keyboard. Arrow down from the last row of the main list; then the key-view loop.
    tables = sidebarTables(root, in: window)
    if let main = tables.first {
        window.makeFirstResponder(main)
        main.selectRowIndexes([main.numberOfRows - 1], byExtendingSelection: false); spin()
        let before = model.section
        key(window, 125, "\u{F701}"); spin()
        print("PROBE \(label) arrow-down-from-last: section \(before) -> \(model.section)")
        describeSidebar(window, model, "\(label) after-arrow-down")
    }
    probeKeyLoop(window, label + " end")
}

/// The key-view loop: which views Tab visits from the main list, by the views' own links and by moving the first responder.
@MainActor func probeKeyLoop(_ window: NSWindow, _ label: String) {
    guard let root = window.contentView else { return }
    let ts = sidebarTables(root, in: window)
    func name(_ v: NSView?) -> String {
        guard let v else { return "nil" }
        if let i = ts.firstIndex(where: { $0 === v }) { return "sidebar-table\(i)" }
        return String(describing: type(of: v)).prefix(40) + "@x\(Int(v.convert(v.bounds, to: nil).midX))y\(Int(root.bounds.height - v.convert(v.bounds, to: nil).midY))"
    }
    func walk(_ step: (NSView) -> NSView?) -> String {
        var out: [String] = []; var v: NSView? = ts.first
        for _ in 0..<8 { guard let c = v, let n = step(c) else { break }; out.append(name(n)); v = n; if n === ts.first { break } }
        return out.joined(separator: " > ")
    }
    print("PROBE \(label) fullKeyboardAccess=\(NSApp.isFullKeyboardAccessEnabled)")
    print("PROBE \(label) tab-chain from table0: \(walk { $0.nextValidKeyView })")
    print("PROBE \(label) backtab-chain from table0: \(walk { $0.previousValidKeyView })")
    window.makeFirstResponder(ts.first)
    var moved: [String] = []
    for _ in 0..<4 { window.selectNextKeyView(nil); spin(0.1); moved.append(name(window.firstResponder as? NSView)) }
    print("PROBE \(label) tab-moves from table0: \(moved.joined(separator: " > "))")
}

func findSplit(_ vc: NSViewController?) -> NSSplitViewController? {
    guard let vc else { return nil }
    if let s = vc as? NSSplitViewController { return s }
    for c in vc.children { if let s = findSplit(c) { return s } }
    return nil
}

func findAll<T: NSView>(_ v: NSView, _ type: T.Type) -> [T] {
    ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { findAll($0, type) }
}

/// The sidebar at its widest and narrowest and collapsed: where the tables and the Advanced switch sit.
@MainActor func probeSidebarEdges(_ window: NSWindow, _ model: MainWindowModel, _ label: String) {
    guard let root = window.contentView,
          let split = findAll(root, NSSplitView.self).compactMap({ $0.delegate as? NSSplitViewController }).first ?? findSplit(window.contentViewController) else {
        print("PROBE \(label) edges: no split view controller found"); return
    }
    func geometry(_ tag: String) {
        let ts = sidebarTables(root, in: window)
        let sw = findAll(root, NSSwitch.self).first { $0.convert($0.bounds, to: nil).midX < 260 }
        let swTxt = sw.map { s -> String in let f = s.convert(s.bounds, to: nil); return "switch y=\(Int(root.bounds.height - f.maxY))..\(Int(root.bounds.height - f.minY)) x=\(Int(f.minX))..\(Int(f.maxX))" } ?? "switch none"
        let cols = ts.map { t -> String in
            let f = t.enclosingScrollView.map { $0.convert($0.bounds, to: nil) } ?? .zero
            return "scroll x=\(Int(f.minX))..\(Int(f.maxX)) y=\(Int(root.bounds.height - f.maxY))..\(Int(root.bounds.height - f.minY))"
        }
        print("PROBE \(label) \(tag): sidebar item collapsed=\(split.splitViewItems[0].isCollapsed) width=\(Int(split.splitViewItems[0].viewController.view.frame.width)) | \(swTxt) | \(cols.joined(separator: " | ")) | highlights=\(ts.reduce(0) { $0 + $1.selectedRowIndexes.count })")
    }
    geometry("default")
    for w in [100.0, 170.0, 240.0, 400.0] {
        split.splitView.setPosition(w, ofDividerAt: 0); spin(0.3)
        geometry("divider->\(Int(w))")
    }
    split.splitView.setPosition(190, ofDividerAt: 0); spin(0.3)
    split.toggleSidebar(nil); spin(0.8)
    geometry("collapsed")
    split.toggleSidebar(nil); spin(0.8)
    geometry("reopened")
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
    if let m = ProcessInfo.processInfo.environment["SHOTS_SIDEBAR_SIZE_MODE"].flatMap(Int.init) { UserDefaults.standard.register(defaults: ["NSTableViewDefaultSizeMode": m]) }

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
    /// The Голоса page with the design sheet open on a flow after the given steps (typed text in the language of the shot).
    func designSheet(_ now: Date, _ ru: Bool, _ steps: (inout VoiceDesignFlow) -> Void, label: (() -> String)? = nil) -> MainWindowData {
        var f = VoiceDesignFlow(description: ru ? "Спокойный диктор, мужской голос, неспешный и тёплый" : "A calm male narrator, unhurried and warm",
                                sentence: DesignForm.defaultSentence, label: label?() ?? "")
        steps(&f)
        return voices(PreviewData.make(now: now, ru: ru)) { $0.design = f; $0.designOpen = true }
    }
    /// The Голоса page with the file sheet open over a picked clip, after the given steps.
    func fileSheet(_ now: Date, _ ru: Bool, name: String, seconds: Double, bytes: Int64, _ steps: (inout VoiceFileAdd) -> Void) -> MainWindowData {
        var add = VoiceFileAdd(fileName: name, audioPath: "/Users/anya/Music/\(name)", seconds: seconds, bytes: bytes, ext: "m4a")
        steps(&add)
        return voices(PreviewData.make(now: now, ru: ru)) { $0.file = add }
    }
    /// The Голоса page with the recording sheet open on a reducer after the given steps (in the language of the shot).
    func recordSheet(_ now: Date, _ ru: Bool, levels: [Float] = [], _ steps: (inout VoiceRecording) -> Void) -> MainWindowData {
        var r = VoiceRecording(language: ru ? "ru" : "en")
        steps(&r)
        return voices(PreviewData.make(now: now, ru: ru)) { $0.record = VoiceRecordValues(recording: r, levels: levels) }
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
        Scene(name: "sidebar-settings", section: .settings, meeting: nil, sidebar: true, advanced: true) { PreviewData.make(now: $0, ru: $1) },
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
        // Sheet scenes: the same Голоса page as the app shows, with the data that opens the sheet.
        Scene(name: "voice-design-form", section: .voices, meeting: nil, data: { now, ru in
            designSheet(now, ru) { _ in } label: { ru ? "Мой диктор" : "My narrator" }
        }, sheet: true),
        Scene(name: "voice-design-designing", section: .voices, meeting: nil, data: { now, ru in
            designSheet(now, ru) { f in _ = f.submit(taken: []) }
        }, sheet: true),
        Scene(name: "voice-design-review", section: .voices, meeting: nil, data: { now, ru in
            designSheet(now, ru) { f in _ = f.submit(taken: []); f.designed(takes(), for: f.generation) } label: { ru ? "Мой диктор" : "My narrator" }
        }, sheet: true),
        Scene(name: "voice-design-review-warning", section: .voices, meeting: nil, data: { now, ru in
            designSheet(now, ru) { f in _ = f.submit(taken: []); f.designed(takes(), for: f.generation); _ = f.next(); _ = f.next() }
        }, sheet: true),
        Scene(name: "voice-design-name-taken", section: .voices, meeting: nil, data: { now, ru in
            designSheet(now, ru) { f in
                _ = f.submit(taken: []); f.designed(takes(), for: f.generation); _ = f.keep(); f.saveAnswered(.nameTaken)
            } label: { ru ? "Мой диктор" : "My narrator" }
        }, sheet: true),
        Scene(name: "voice-design-failed", section: .voices, meeting: nil, data: { now, ru in
            designSheet(now, ru) { f in _ = f.submit(taken: []); f.fail(StudioError.timedOut.message()) }
        }, sheet: true),
        // «Взять из файла»: the sheet over a picked clip — ordinary, refused (under 3 s), after the daemon's own 400.
        Scene(name: "voice-file-sheet", section: .voices, meeting: nil, data: { now, ru in
            fileSheet(now, ru, name: ru ? "Интервью 2026.m4a" : "interview-2026.m4a", seconds: 12.4, bytes: 1_900_000) { _ in }
        }, sheet: true),
        Scene(name: "voice-file-sheet-short", section: .voices, meeting: nil, data: { now, ru in
            fileSheet(now, ru, name: ru ? "Приветствие.m4a" : "greeting.m4a", seconds: 1.8, bytes: 60_000) { _ in }
        }, sheet: true),
        Scene(name: "voice-file-sheet-error", section: .voices, meeting: nil, data: { now, ru in
            fileSheet(now, ru, name: ru ? "Интервью 2026.m4a" : "interview-2026.m4a", seconds: 12.4, bytes: 1_900_000) { add in
                _ = add.submit(taken: [])
                add.refused("the clip could not be decoded")
            }
        }, sheet: true),
        // «Записать свой голос»: ready to record, recording, the review, a denied microphone, a take that is too short.
        Scene(name: "voice-record-ready", section: .voices, meeting: nil, data: { now, ru in
            recordSheet(now, ru) { _ = $0.micStatus(.authorized) }
        }, sheet: true),
        Scene(name: "voice-record-recording", section: .voices, meeting: nil, data: { now, ru in
            recordSheet(now, ru, levels: [0.2, 0.45, 0.7, 0.9, 0.6, 0.8, 0.5, 0.3, 0.15]) {
                _ = $0.micStatus(.authorized); _ = $0.start(); _ = $0.tick(seconds: 7.5)
            }
        }, sheet: true),
        Scene(name: "voice-record-review", section: .voices, meeting: nil, data: { now, ru in
            recordSheet(now, ru) { _ = $0.micStatus(.authorized); _ = $0.start(); $0.stop(seconds: 9.2) }
        }, sheet: true),
        Scene(name: "voice-record-mic-denied", section: .voices, meeting: nil, data: { now, ru in
            recordSheet(now, ru) { _ = $0.micStatus(.denied) }
        }, sheet: true),
        Scene(name: "voice-record-too-short", section: .voices, meeting: nil, data: { now, ru in
            recordSheet(now, ru) { _ = $0.micStatus(.authorized); _ = $0.start(); $0.stop(seconds: 3.4) }
        }, sheet: true),
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

    // SHOTS_WIDTHS=760,1400 renders each scene at those widths (file names get a -w<width> suffix); default is one 980 pt shot.
    let widths = ProcessInfo.processInfo.environment["SHOTS_WIDTHS"].map { $0.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) } }
    for lang in ["en", "ru"] {
        guard let bundle = Bundle(path: root.appendingPathComponent("Resources/\(lang).lproj").path) else {
            FileHandle.standardError.write(Data("no \(lang).lproj under \(root.path)\n".utf8)); exit(1)
        }
        L10nBundle.bundle = bundle
        L10nBundle.locale = Locale(identifier: lang)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for scene in scenes {
              for width in widths ?? [size.width] {
                if let only, !only.contains(scene.name) { continue }
                let model = MainWindowModel(data: scene.data(now, lang == "ru"), section: scene.section,
                                            selectedMeeting: scene.meeting)
                model.initialMeetingTab = scene.tab
                model.queryText = scene.query(lang == "ru")
                model.initialFind = scene.find?(lang == "ru")
                model.appsExpanded = scene.appsExpanded
                model.clock = { now }
                model.advanced = scene.advanced
                let hosting = NSHostingController(rootView: scene.sidebar
                    ? MainWindowView(model: model, switchShown: true, live: Set(MainSection.allCases))
                    : MainWindowView(model: model))
                hosting.sizingOptions = []
                window.contentViewController = hosting
                window.setContentSize(NSSize(width: width, height: scene.height))
                window.title = "OxSay"
                window.orderFrontRegardless()
                // Two short spins: the first lays the view out, the second lets lazy rows and the toolbar settle.
                RunLoop.main.run(until: Date().addingTimeInterval(0.9))
                window.displayIfNeeded()
                // SwiftUI presents the sheet a beat after the page is up, and animates it in.
                RunLoop.main.run(until: Date().addingTimeInterval(scene.sheet ? 1.5 : 0.5))
                if ProcessInfo.processInfo.environment["SHOTS_PROBE"] != nil {
                    if scene.sidebar {
                        let tag = "\(scene.name)-\(lang)-\(dark ? "dark" : "light")-w\(Int(width))"
                        if ProcessInfo.processInfo.environment["SHOTS_PROBE"] == "edges" { probeSidebarEdges(window, model, tag) } else { probeSidebar(window, model, tag) }
                    }
                    continue
                }
                let file = out.appendingPathComponent("\(scene.name)-\(lang)-\(dark ? "dark" : "light")\(widths == nil ? "" : "-w\(Int(width))").png")
                if scene.sheet != (window.attachedSheet != nil) {
                    // A silent wrong shot is the bug class here: a sheet scene without its sheet, or a plain one with a stray sheet.
                    // The scene's previous PNG goes first: a rerun must not show a stale image beside a reported failure.
                    try? FileManager.default.removeItem(at: file)
                    print("ERR \(file.path) (sheet \(window.attachedSheet == nil ? "missing" : "unexpected"))")
                    if let s = window.attachedSheet { window.endSheet(s) }
                    continue
                }
                let viewCapture = ProcessInfo.processInfo.environment["SHOTS_VIEW_CAPTURE"] != nil
                var captured = false
                if !viewCapture {
                    captured = captureWindows(window, sheet: window.attachedSheet, to: file)
                }
                // The screen is locked or the window is not on it (a night run): draw the window's views instead.
                // No title bar and no toolbar, but the content is the same, and the sheet is drawn at its offset.
                if !captured { captured = drawWindows(window, sheet: window.attachedSheet, to: file) }
                // A failed capture leaves whatever the last run wrote; the ERR must not sit next to a stale image.
                if !captured { try? FileManager.default.removeItem(at: file) }
                print("\(captured ? "ok " : "ERR") \(file.path)")
                // Close the sheet before the next scene: clear the state that presents it, so SwiftUI dismisses it itself.
                if scene.sheet {
                    model.data.voices.designOpen = false
                    model.data.voices.file = nil
                    model.data.voices.record = nil
                    for _ in 0..<20 where window.attachedSheet != nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
                    if let s = window.attachedSheet { window.endSheet(s) }
                }
              }
            }
        }
    }
    window.close()
}

MainActor.assumeIsolated { run() }
