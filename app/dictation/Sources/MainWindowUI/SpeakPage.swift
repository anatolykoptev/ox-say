import AppKit
import DictationCore
import SwiftUI
import UniformTypeIdentifiers

/// Озвучка on the fast voice: the session's clips on the left; on the right the text, the voice, one big button and,
/// once a take exists, play, another variant and save. The states are `SpeakPageState`'s (offline, editing,
/// generating, ready, failed); a control is drawn only if `SpeakControls` lists it for the engine (the fast voice).
struct SpeakPage: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let notice = model.data.notice { NoticeBar(text: notice) { model.actions.dismissNotice() } }
            }
                        .toolbar {
                if model.advanced {
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.speakPanelShown.wrappedValue.toggle() } label: {
                            Label(L10nKey.speakPanelTitle.text, systemImage: "slider.horizontal.3").labelStyle(.titleAndIcon)
                        }
                        .help(L10nKey.speakPanelTitle.text)
                    }
                }
                // A reel is made on the studio voice, so the button exists only where that voice can run.
                if model.data.speak.studio == .available {
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.actions.speakNewReel() } label: {
                            Label(L10nKey.speakNewReel.text, systemImage: "film").labelStyle(.titleAndIcon)
                        }
                        .help(L10nKey.speakNewReel.text)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.actions.speakNewText() } label: {
                        Label(L10nKey.speakNewText.text, systemImage: "square.and.pencil")
                    }
                    .help(L10nKey.speakNewText.text)
                }
            }
    }

    @ViewBuilder private var content: some View {
        if case .offline(let sentence) = model.speakState {
            ContentUnavailableView {
                Label(L10nKey.meetingsDownTitle.text, systemImage: "bolt.horizontal.circle")
            } description: {
                Text(sentence)
            } actions: {
                Button(L10nKey.commonRetry.text) { model.actions.refresh() }.controlSize(.large)
            }
        } else {
            SpeakSplit(model: model, panelOpen: model.speakPanelOpen.wrappedValue)
        }
    }
}

/// The left pane: the studio projects the daemon keeps and this session's takes, a running project first.
struct SpeakClipsColumn: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        let items = model.data.speak.items
        List(selection: Binding(get: { model.data.speak.selectedID },
                                set: { if let id = $0 { model.actions.speakSelect(id) } })) {
            Section(L10nKey.speakListTitle.text) {
                ForEach(items) { item in
                    SpeakItemRow(item: item, now: model.clock()).tag(item.id)
                }
            }
        }
        .listStyle(.inset)
        // Choosing another item would drop the take that is being made.
        .disabled(!model.data.speak.phase.allowsSelection)
        .overlay {
            if items.isEmpty {
                Text(L10nKey.speakListEmpty.text)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(20)
            }
        }
    }
}

private struct SpeakItemRow: View {
    let item: SpeakListItem
    let now: Date

    var body: some View {
        let title = item.title.isEmpty ? L10nKey.speakUntitled.text : item.title
        let status = item.status { $0.text }
        VStack(alignment: .leading, spacing: 2) {
            Text(title).lineLimit(1)
            HStack(spacing: 4) {
                if item.state == .running { ProgressView().controlSize(.mini) }
                Text(status).monospacedDigit()
                if item.state == .ready || item.state == .review {
                    Text("·")
                    Text(Self.age(item.created, now: now))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(status)")
    }

    private static func age(_ date: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = L10nBundle.locale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }
}

/// The right pane: the editor, the voice and quality rows, and the state's own action area.
struct SpeakDetailColumn: View {
    @ObservedObject var model: MainWindowModel
    @State private var choosingDocument = false

    /// The kinds `DocumentReader` reads: text, Markdown, Word, RTF, OpenDocument, PDF.
    private static let documentTypes = DocumentReader.supportedExtensions.compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        if let project = model.data.speak.selectedProject {
            SpeakProjectDetail(model: model, job: project)
        } else {
            editor
        }
    }

    private var editor: some View {
        let state = model.speakState
        let values = model.data.speak
        let shown = SpeakControls.shown(engine: values.engine, voiceIsDesigned: false, advanced: values.advanced)
        return VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Button { choosingDocument = true } label: {
                            Label(L10nKey.speakOpenDocument.text, systemImage: "doc.text")
                        }
                        .disabled(isGenerating(state) || values.reading)
                        if values.reading {
                            ProgressView().controlSize(.small)
                            Text(L10nKey.speakReadingDocument.text).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    TextEditor(text: model.speakText)
                        .font(.body)
                        // A whole document is far taller than the page: the editor scrolls inside its box, so the length line,
                        // the offer to keep the first part and the voice rows stay in view.
                        .frame(minHeight: 150, maxHeight: 300)
                        .disabled(isGenerating(state) || values.reading)
                        .accessibilityLabel(L10nKey.speakEditorLabel.text)
                    if values.engine == .studio {
                        // The studio voice counts and sends the trimmed script, and says how long it will take.
                        Text(SpeakText.statusLine(editorText: values.text) { $0.text }).font(.callout).foregroundStyle(.secondary)
                        if SpeakStudio.offersFirstPart(text: values.text, engine: values.engine) {
                            Button(L10nKey.reviewKeepFirst.text) { model.actions.speakKeepFirstPart() }
                                .buttonStyle(.link).disabled(isGenerating(state))
                        }
                        if values.reel {
                            Text(L10nKey.speakReelHint.text).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if case .editing(let problem?) = state {
                        Text(problem).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if shown.contains(.voice) { voicePicker }
                    if shown.contains(.quality) { quality }
                }
            }
            .formStyle(.grouped)
            action(state).padding(.horizontal, 20).padding(.bottom, 16)
        }
        .fileImporter(isPresented: $choosingDocument, allowedContentTypes: Self.documentTypes) { result in
            if case .success(let url) = result { model.actions.speakOpenDocument(url) }
        }
    }

    private func isGenerating(_ state: SpeakPageState) -> Bool {
        if case .generating = state { return true }
        return false
    }

    private var voicePicker: some View {
        SpeakVoicePicker(model: model).disabled(isGenerating(model.speakState))
    }

    /// «Качество»: «Обычное» works on every Mac, «Студийное» only where the studio voice can run. Where it cannot, the
    /// control is a value with the reason under it (and the install, when that is what is missing), never a dead segment.
    @ViewBuilder private var quality: some View {
        if model.data.speak.studio == .available {
            VStack(alignment: .leading, spacing: 4) {
                Picker(L10nKey.speakQuality.text, selection: model.speakQuality) {
                    Text(L10nKey.speakQualityStandard.text).tag(SpeakEngine.fast)
                    Text(L10nKey.speakQualityStudio.text).tag(SpeakEngine.studio)
                }
                .pickerStyle(.segmented)
                .disabled(isGenerating(model.speakState))
                if model.data.speak.quality == .studio {
                    Text(L10nKey.speakQualityStudioHint.text).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(L10nKey.speakQuality.text) { Text(L10nKey.speakQualityStandard.text) }
                if let note = model.speakStudioNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.data.speak.studio == .notInstalled {
                        Button(L10nKey.voicesDescribeInstall.text) { model.actions.installStudioVoice() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder private func action(_ state: SpeakPageState) -> some View {
        switch state {
        case .offline:
            EmptyView()
        case .editing(let problem):
            HStack {
                Spacer()
                Button(L10nKey.speakCreate.text) { model.actions.speakGenerate() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(problem != nil)
            }
        case .generating:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L10nKey.speakGenerating.text).foregroundStyle(.secondary)
                Spacer()
                // A studio project is already on its way to the daemon; the person stops it from its row once it runs.
                if model.data.speak.engine == .fast {
                    Button(L10nKey.speakStop.text) { model.actions.speakStop() }.keyboardShortcut(.cancelAction)
                }
            }
        case .ready:
            VStack(spacing: 10) {
                if !model.data.speak.peaks.isEmpty {
                    WaveformView(peaks: model.data.speak.peaks, playedFraction: model.data.speak.playedFraction)
                }
                HStack(spacing: 10) {
                    let playing = model.data.speak.playback == .playing
                    IconButton(symbol: playing ? "pause.fill" : "play.fill", labelKey: playing ? .speakPause : .speakPlay) {
                        model.actions.speakPlayPause()
                    }
                    .font(.title2)
                    if let clip = model.data.speak.selectedClip {
                        Text(SpeakClips.clock(clip.seconds)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10nKey.speakVariant.text) { model.actions.speakVariant() }
                    Button(L10nKey.speakSave.text) { model.actions.speakSave() }
                }
            }
        case .failed(let sentence):
            HStack(spacing: 10) {
                Label(sentence, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L10nKey.commonRetry.text) { model.actions.speakGenerate() }
            }
        }
    }
}

/// «Голос»: the standard voice and every voice of the library. One picker for the page and the voice panel.
struct SpeakVoicePicker: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        Picker(L10nKey.speakVoice.text, selection: model.speakVoice) {
            Text(L10nKey.voicesStandard.text).tag(String?.none)
            Divider()
            ForEach(model.data.voices.voices, id: \.self) { id in
                Text(model.data.voices.title(for: id)).tag(String?.some(id))
            }
        }
    }
}

/// A studio project on the right: its progress while it runs, its track once it is done, and what happened when it did not
/// finish. The state is `SpeakProjectState`'s; the track plays through the same player as a fast clip.
struct SpeakProjectDetail: View {
    @ObservedObject var model: MainWindowModel
    let job: ProduceJob

    var body: some View {
        let values = model.data.speak
        let state = SpeakProjectState.of(job, serviceWaiting: values.serviceWaiting,
                                         trackMissing: values.trackMissing.contains(job.id)) { $0.text }
        VStack(spacing: 0) {
            header(values, state)
            PhraseList(model: model, job: job)
        }
    }

    private func header(_ values: SpeakValues, _ state: SpeakProjectState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(job.title.isEmpty ? L10nKey.speakUntitled.text : job.title).font(.title2).lineLimit(2)
            switch state {
            case .running(let label, let fraction):
                VStack(alignment: .leading, spacing: 8) {
                    Text(label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let fraction { ProgressView(value: fraction) } else { ProgressView() }
                }
            case .ready(let note, let seconds):
                VStack(alignment: .leading, spacing: 10) {
                    if !values.peaks.isEmpty {
                        WaveformView(peaks: values.peaks, playedFraction: values.playedFraction)
                    }
                    HStack(spacing: 10) {
                        // A phrase's take sounding is not the track: the track's button offers ▶ then.
                        let playing = values.playback == .playing && values.playingPhrase == nil
                        IconButton(symbol: playing ? "pause.fill" : "play.fill", labelKey: playing ? .speakPause : .speakPlay) {
                            model.actions.speakPlayPause()
                        }
                        .font(.title2)
                        if let seconds { Text(SpeakClips.clock(seconds)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                    if let note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            case .trackMissing:
                Label(L10nKey.speakTrackMissing.text, systemImage: "questionmark.folder").foregroundStyle(.secondary)
            case .ended(let sentence):
                Label(sentence, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if values.phrases.isEmpty { Spacer() }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: values.phrases.isEmpty ? .infinity : nil, alignment: .topLeading)
    }
}

/// The clips and the detail side by side in a native split view. The list is 180...300 wide (ideal 220) and keeps its
/// width while the window grows; the detail never drops under 340. With the widest sidebar (240) that is 761, inside
/// the window floor (801).
struct SpeakSplit: NSViewControllerRepresentable {
    @ObservedObject var model: MainWindowModel
    /// The voice panel (Advanced) is open: the third pane of the split.
    let panelOpen: Bool

    func makeNSViewController(context: Context) -> SpeakSplitController {
        let controller = SpeakSplitController(model: model)
        controller.setPanel(open: panelOpen, animated: false)
        return controller
    }

    func updateNSViewController(_ controller: SpeakSplitController, context: Context) {
        controller.setPanel(open: panelOpen, animated: true)
    }
}

final class SpeakSplitController: NSSplitViewController {
    static let listWidth: ClosedRange<CGFloat> = 180...300
    static let detailMinimum: CGFloat = 340
    /// The voice panel's width when open, and the text's width the window keeps for it (what the text had before the panel).
    static let panelWidth: ClosedRange<CGFloat> = 300...380
    static let detailComfortable: CGFloat = 520
    private var panelItem: NSSplitViewItem?
    private weak var model: MainWindowModel?

    init(model: MainWindowModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let list = NSHostingController(rootView: SpeakClipsColumn(model: model).environment(\.locale, L10nBundle.locale))
        let detail = NSHostingController(rootView: SpeakDetailColumn(model: model).environment(\.locale, L10nBundle.locale))
        list.sizingOptions = []
        detail.sizingOptions = []
        let listItem = NSSplitViewItem(viewController: list)
        listItem.minimumThickness = Self.listWidth.lowerBound
        listItem.maximumThickness = Self.listWidth.upperBound
        listItem.canCollapse = false
        listItem.holdingPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 10)
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = Self.detailMinimum
        detailItem.canCollapse = false
        addSplitViewItem(listItem)
        addSplitViewItem(detailItem)
        // The voice panel is the system's inspector pane: collapsed until the toolbar button opens it (Advanced only).
        let panel = NSHostingController(rootView: VoicePanel(model: model).environment(\.locale, L10nBundle.locale))
        panel.sizingOptions = []
        let panelItem = NSSplitViewItem(inspectorWithViewController: panel)
        panelItem.minimumThickness = Self.panelWidth.lowerBound
        panelItem.maximumThickness = Self.panelWidth.upperBound
        panelItem.isCollapsed = true
        addSplitViewItem(panelItem)
        self.panelItem = panelItem
    }

    /// Opens or closes the voice panel; the same call twice changes nothing. The window makes room for it, so the text keeps its
    /// width instead of being squeezed under its least (`PanelWindow`).
    func setPanel(open: Bool, animated: Bool) {
        guard let panelItem, panelItem.isCollapsed == open else { return }
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if open { makeRoom(animate: animate) } else { giveBackRoom(animate: animate) }
        if animate {
            panelItem.animator().isCollapsed = !open
        } else {
            panelItem.isCollapsed = !open
        }
    }

    private var grewBy = 0.0

    /// The page goes away (another section, the daemon offline, the window closing) with the panel open: the window gives its
    /// room back and the panel closes for good, so coming back starts closed with the window at its own size. Left as it was,
    /// the open state would outlive this controller and the next one would open the panel into a window with no room made.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        guard let panelItem, !panelItem.isCollapsed else { return }
        giveBackRoom(animate: false)
        panelItem.isCollapsed = true
        DispatchQueue.main.async { [weak model] in model?.data.speak.panelShown = false }
    }

    /// The panel needs more than the window floor: widen the window so the text keeps the width it had (to the screen's edge at
    /// most), and keep the window from being dragged under what the panes need at their least.
    private func makeRoom(animate: Bool) {
        guard let window = view.window else { return }
        let sidebar = view.convert(view.bounds, to: nil).minX
        let divider = MainWindowSpec.splitDividerWidth
        let least = PanelWindow.neededWidth(sidebar: sidebar, list: Self.listWidth.lowerBound, detail: Self.detailMinimum,
                                            panel: Self.panelWidth.lowerBound, divider: divider, panelOpen: true)
        let needed = PanelWindow.neededWidth(sidebar: sidebar, list: Self.listWidth.lowerBound, detail: Self.detailComfortable,
                                             panel: Self.panelWidth.lowerBound, divider: divider, panelOpen: true)
        window.contentMinSize.width = PanelWindow.minimumWidth(floor: MainWindowSpec.minimumWidth, needed: least, panelOpen: true)
        let visible = window.screen?.visibleFrame ?? window.frame
        let growth = PanelWindow.growth(needed: needed, current: window.contentLayoutRect.width, room: visible.width - window.frame.width)
        guard growth > 0 else { return }
        var frame = window.frame
        frame.size.width += growth
        if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
        window.setFrame(frame, display: true, animate: animate)
        grewBy = growth
    }

    /// The window goes back to its floor, and gives back only the width the opening added.
    private func giveBackRoom(animate: Bool) {
        guard let window = view.window else { return }
        window.contentMinSize.width = MainWindowSpec.minimumWidth
        let back = PanelWindow.shrink(grewBy: grewBy, current: window.contentLayoutRect.width, floor: MainWindowSpec.minimumWidth)
        grewBy = 0
        guard back > 0 else { return }
        var frame = window.frame
        frame.size.width -= back
        window.setFrame(frame, display: true, animate: animate)
    }


    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    private var placed = false

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !placed, splitView.bounds.width >= Self.listWidth.lowerBound + MainWindowSpec.splitDividerWidth + Self.detailMinimum else { return }
        placed = true
        splitView.setPosition(220, ofDividerAt: 0)
    }
}
