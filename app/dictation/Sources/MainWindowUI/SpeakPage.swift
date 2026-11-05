import AppKit
import DictationCore
import SwiftUI

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
            SpeakSplit(model: model)
        }
    }
}

/// The left pane: this session's takes, newest first.
struct SpeakClipsColumn: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        let clips = model.data.speak.clips
        List(selection: Binding(get: { model.data.speak.selectedID },
                                set: { if let id = $0 { model.actions.speakSelect(id) } })) {
            Section(L10nKey.speakListTitle.text) {
                ForEach(clips) { clip in
                    SpeakClipRow(clip: clip, now: model.clock()).tag(clip.id)
                }
            }
        }
        .listStyle(.inset)
        // Choosing another clip would drop the take that is being made.
        .disabled(!model.data.speak.phase.allowsSelection)
        .overlay {
            if clips.isEmpty {
                Text(L10nKey.speakListEmpty.text)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(20)
            }
        }
    }
}

private struct SpeakClipRow: View {
    let clip: SpeakClip
    let now: Date

    var body: some View {
        let length = SpeakClips.clock(clip.seconds)
        VStack(alignment: .leading, spacing: 2) {
            Text(clip.title).lineLimit(1)
            HStack(spacing: 4) {
                Text(length).monospacedDigit()
                Text("·")
                Text(Self.age(clip.created, now: now))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(clip.title), \(length)")
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

    var body: some View {
        let state = model.speakState
        let values = model.data.speak
        let shown = SpeakControls.shown(engine: .fast, voiceIsDesigned: false, advanced: values.advanced)
        VStack(spacing: 0) {
            Form {
                Section {
                    TextEditor(text: model.speakText)
                        .font(.body)
                        .frame(minHeight: 150)
                        .disabled(isGenerating(state))
                        .accessibilityLabel(L10nKey.speakEditorLabel.text)
                    if case .editing(let problem?) = state {
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
    }

    private func isGenerating(_ state: SpeakPageState) -> Bool {
        if case .generating = state { return true }
        return false
    }

    private var voicePicker: some View {
        Picker(L10nKey.speakVoice.text, selection: model.speakVoice) {
            Text(L10nKey.voicesStandard.text).tag(String?.none)
            Divider()
            ForEach(model.data.voices.voices, id: \.self) { id in
                Text(model.data.voices.title(for: id)).tag(String?.some(id))
            }
        }
        .disabled(isGenerating(model.speakState))
    }

    /// «Качество»: the fast voice works on every Mac, so «Обычное» is the one choice and is shown as a value, not as a
    /// one-segment control. The studio voice arrives with Task 15; until then this says why it cannot be chosen, or
    /// offers the install that exists.
    private var quality: some View {
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
                Button(L10nKey.speakStop.text) { model.actions.speakStop() }.keyboardShortcut(.cancelAction)
            }
        case .ready:
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

/// The clips and the detail side by side in a native split view. The list is 180...300 wide (ideal 220) and keeps its
/// width while the window grows; the detail never drops under 340. With the widest sidebar (240) that is 761, inside
/// the window floor (801).
struct SpeakSplit: NSViewControllerRepresentable {
    @ObservedObject var model: MainWindowModel

    func makeNSViewController(context: Context) -> SpeakSplitController { SpeakSplitController(model: model) }
    func updateNSViewController(_ controller: SpeakSplitController, context: Context) {}
}

final class SpeakSplitController: NSSplitViewController {
    static let listWidth: ClosedRange<CGFloat> = 180...300
    static let detailMinimum: CGFloat = 340

    init(model: MainWindowModel) {
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
