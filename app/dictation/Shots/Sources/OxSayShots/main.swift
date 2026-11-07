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
    /// The Озвучка page: the sample text of the shot's language, the daemon answering, and the given changes.
    func speak(_ now: Date, _ ru: Bool, _ change: (inout SpeakValues) -> Void) -> MainWindowData {
        var d = PreviewData.make(now: now, ru: ru)
        var v = SpeakValues(text: ru ? L10nKey.speakSampleRu.text : L10nKey.speakSampleEn.text, reach: .reachable)
        change(&v)
        d.speak = v
        return d
    }
    func speakClips(_ now: Date, _ ru: Bool) -> [SpeakClip] {
        let texts = ru
            ? ["Привет! Это мой первый голос. Сегодня расскажу, почему короткие ролики работают лучше длинных.", "Добро пожаловать в студию. Начнём с самого простого.", "Спасибо, что дослушали до конца."]
            : ["Hi! This is my first voice. Today I will explain why short videos work better than long ones.", "Welcome to the studio. Let us start with the simplest thing.", "Thank you for listening to the end."]
        return texts.enumerated().map { i, t in
            SpeakClip(id: "c\(i)", title: SpeakClips.title(of: t), text: t, voice: nil, seconds: [14.0, 7.5, 3.0][i], wav: Data(count: 16),
                      created: now.addingTimeInterval(-Double(i) * 1500 - 60))
        }
    }
    /// A project id the way the daemon writes it (`yyyyMMdd-HHmmss-xxxxxx`, UTC) for `age` seconds before `now`.
    func projectID(_ now: Date, age: Double, _ tail: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: now.addingTimeInterval(-age)) + "-" + tail
    }
    func projectTitle(_ ru: Bool) -> String { ru ? "Подкаст: глава 3" : "Podcast: chapter 3" }
    /// A project on the Озвучка page, with the studio voice available, the list next to it and the project selected.
    func speakProject(_ now: Date, _ ru: Bool, _ job: (String) -> ProduceJob, _ change: (inout SpeakValues) -> Void = { _ in }) -> MainWindowData {
        speak(now, ru) { v in
            let id = projectID(now, age: 600, "a1b2c3")
            let older = ProduceJob(id: projectID(now, age: 90_000, "d4e5f6"), title: ru ? "Рассказ: вступление" : "Story: introduction",
                                   status: .done, outputPath: "/x/old.wav", durationS: 412)
            v.studio = .available; v.quality = .studio
            v.clips = Array(speakClips(now, ru).prefix(1))
            v.projects = [job(id), older]; v.selectedID = id
            change(&v)
        }
    }
    /// A pseudo-waveform with phrases and pauses, like a read text.
    func sampleBars() -> [Float] {
        (0..<96).map { i in
            let phrase = abs(sin(Double(i) / 5.5)) * 0.6 + 0.15
            return i % 17 < 2 ? 0.06 : Float(min(1, phrase + 0.25 * abs(sin(Double(i) * 1.7))))
        }
    }
    /// The phrases of a short reel: one with a mood, one left for a listen, one with three variants of which the second plays.
    func reelChunks(_ ru: Bool) -> [ProduceChunkDetail] {
        let words = ru
            ? ["Привет! Это мой первый ролик.", "Сегодня расскажу, как озвучить текст за одну минуту.", "Выбирайте настроение для каждой фразы.", "Спасибо, что досмотрели до конца."]
            : ["Hi! This is my first reel.", "Today I will show how to voice a text in one minute.", "Pick a mood for every phrase.", "Thank you for watching to the end."]
        let files = ["a": "/x/a.wav", "b": "/x/b.wav", "c": "/x/c.wav"]
        return [
            ProduceChunkDetail(index: 0, paragraph: 0, text: words[0], style: Mood.warm.styleWord, status: .ok, pick: "a", takeKeys: ["a"], takeFiles: files),
            ProduceChunkDetail(index: 1, paragraph: 1, text: words[1], status: .review, pick: "b", takeKeys: ["a", "b", "c"], takeFiles: files),
            ProduceChunkDetail(index: 2, paragraph: 2, text: words[2], status: .ok, pick: "a", takeKeys: ["a"], takeFiles: files),
            ProduceChunkDetail(index: 3, paragraph: 3, text: words[3], status: .ok, pick: "a", takeKeys: ["a"], takeFiles: files),
        ]
    }
    /// A finished reel project with its phrases read, made with the given voice.
    func speakPhrases(_ now: Date, _ ru: Bool, voice: String, status: ProduceStatus = .done, _ change: (inout SpeakValues) -> Void = { _ in }) -> MainWindowData {
        speakProject(now, ru, { ProduceJob(id: $0, title: ru ? "Ролик: первый" : "Reel: the first one", status: status, outputPath: "/x/out.wav", durationS: 41) }) { v in
            v.peaks = sampleBars()
            v.phraseChunks = reelChunks(ru); v.phrasesFor = v.selectedID
            v.projectVoices[v.selectedID ?? ""] = voice
            change(&v)
        }
    }
    let siliconReason = "Studio voices (VoxCPM2) need a Mac with Apple Silicon; this computer cannot run them."
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
        // Озвучка on the fast voice: first run on an Intel Mac, a finished take, generating, failed, offline, too long,
        // and the studio voice not downloaded.
        Scene(name: "speak-first-run", section: .speak, meeting: nil) { now, ru in
            speak(now, ru) { $0.studio = .unsupported(siliconReason) }
        },
        Scene(name: "speak-ready", section: .speak, meeting: nil) { now, ru in
            speak(now, ru) { v in
                v.clips = speakClips(now, ru); v.selectedID = "c0"; v.text = v.clips[0].text; v.phase = .ready
                v.playback = .paused; v.studio = .available
            }
        },
        Scene(name: "speak-generating", section: .speak, meeting: nil) { now, ru in
            speak(now, ru) { v in v.clips = Array(speakClips(now, ru).dropFirst()); v.phase = .generating; v.studio = .available }
        },
        Scene(name: "speak-failed", section: .speak, meeting: nil) { now, ru in
            speak(now, ru) { v in v.clips = speakClips(now, ru); v.phase = .failed(SpeechError.engineUnavailable.message()) }
        },
        Scene(name: "speak-offline", section: .speak, meeting: nil) { now, ru in
            speak(now, ru) { v in v.reach = .unreachable(SpeechError.daemonUnreachable("").message()) }
        },
        Scene(name: "speak-too-long", section: .speak, meeting: nil) { now, ru in
            speak(now, ru) { v in v.text = String(repeating: ru ? "Длинный текст. " : "A long text. ", count: 400) }
        },
        Scene(name: "speak-studio-note", section: .speak, meeting: nil) { now, ru in
            speak(now, ru) { v in v.studio = .notInstalled }
        },
        // Озвучка on the studio voice: a project running, finished, finished with parts to listen to, interrupted, its file
        // gone, and a second start refused because another voiceover runs.
        Scene(name: "speak-studio-running", section: .speak, meeting: nil) { now, ru in
            speakProject(now, ru, { ProduceJob(id: $0, title: projectTitle(ru), status: .running, partsTotal: 5, partsDone: 3) })
        },
        Scene(name: "speak-studio-done", section: .speak, meeting: nil) { now, ru in
            speakProject(now, ru, { ProduceJob(id: $0, title: projectTitle(ru), status: .done, outputPath: "/x/out.wav", durationS: 724) }) { v in
                v.peaks = sampleBars(); v.playback = .paused; v.playedFraction = 0.35
            }
        },
        Scene(name: "speak-studio-review-needed", section: .speak, meeting: nil) { now, ru in
            speakProject(now, ru, { ProduceJob(id: $0, title: projectTitle(ru), status: .review, partsToReview: 2, outputPath: "/x/out.wav", durationS: 724) }) { v in
                v.peaks = sampleBars()
            }
        },
        Scene(name: "speak-studio-interrupted", section: .speak, meeting: nil) { now, ru in
            speakProject(now, ru, { ProduceJob(id: $0, title: projectTitle(ru), status: .interrupted, partsTotal: 5, partsDone: 2) })
        },
        Scene(name: "speak-studio-file-missing", section: .speak, meeting: nil) { now, ru in
            speakProject(now, ru, { ProduceJob(id: $0, title: projectTitle(ru), status: .done, outputPath: "/x/gone.wav", durationS: 724) }) { v in
                v.trackMissing = [v.selectedID ?? ""]
            }
        },
        Scene(name: "speak-studio-conflict", section: .speak, meeting: nil) { now, ru in
            speak(now, ru) { v in
                v.studio = .available; v.quality = .studio
                v.projects = [ProduceJob(id: projectID(now, age: 120, "a1b2c3"), title: projectTitle(ru), status: .running, partsTotal: 5, partsDone: 1)]
                v.phase = .failed(ru ? "Другая озвучка уже идёт. Дождитесь её конца и повторите." : "Another voiceover is already running. Wait for it to finish, then try again.")
            }
        },
        // Phrases: mood and variants on a designed voice; a new reel draft; a document over the cap; one phrase being remade;
        // no mood chips on a cloned voice.
        Scene(name: "speak-phrases", section: .speak, meeting: nil) { now, ru in
            speakPhrases(now, ru, voice: "warm-narrator")
        },
        Scene(name: "speak-reel", section: .speak, meeting: nil) { now, ru in
            speak(now, ru) { v in v.studio = .available; v.quality = .studio; v.reel = true }
        },
        Scene(name: "speak-document-too-long", section: .speak, meeting: nil) { now, ru in
            speak(now, ru) { v in
                v.studio = .available; v.quality = .studio
                v.text = String(repeating: ru ? "Глава из документа, которая не помещается целиком.\n\n" : "A chapter from the document that does not fit whole.\n\n", count: 800)
            }
        },
        Scene(name: "speak-phrase-regenerating", section: .speak, meeting: nil) { now, ru in
            speakPhrases(now, ru, voice: "warm-narrator", status: .running) { v in
                v.phraseWork = PhraseWork(chunk: 1, kind: .variant)
                v.projects[0].partsTotal = 4; v.projects[0].partsDone = 4
            }
        },
        Scene(name: "speak-mood-hidden-on-clone", section: .speak, meeting: nil) { now, ru in
            speakPhrases(now, ru, voice: "anna")
        },
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
    if ProcessInfo.processInfo.environment["SHOTS_PROBE"] != nil { finishProbe() }
}

MainActor.assumeIsolated { run() }
