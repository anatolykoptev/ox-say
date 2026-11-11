import DictationCore
import SwiftUI

/// The Advanced voice panel, a native inspector on the right of Озвучка. It draws a row only if `VoicePanelModel.rows` lists it
/// for the engine of the page (plan constraint 3), and each row says under itself what happens to the sound and when
/// (`VoicePanelModel.captionKey`): pace and pause are heard at once without voicing again, a level too on a finished
/// voiceover, the rest with the next voiceover.
struct VoicePanel: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        let values = model.data.speak
        let engine = VoicePanelModel.engine(chosen: values.engine, projectSelected: values.selectedProject != nil)
        let controls = SpeakControls.shown(engine: engine, voiceIsDesigned: false, advanced: true)
        let ids = VoicePanelModel.rows(controls: controls, engine: engine).map(\.id)
        let scope = VoicePanelModel.scope(allText: values.panelAllText, phrase: values.panelPhrase, chunks: values.phraseChunks)
        let job = values.selectedProject
        // Phrases to change: a finished project whose phrases were read. Anything else has none to change yet.
        let finished = job.map { VoicePanelModel.loudnessAppliesNow(status: $0.status) && values.phrasesFor == $0.id && !values.phraseChunks.isEmpty } ?? false
        let busy = job.map { PhraseEditing.isBusy(values.phraseWork, project: $0.id) } ?? false
        let context = Context(engine: engine, finished: finished, allText: values.panelAllText, copies: values.copiesRecordingStyle,
                              reel: values.reel && job == nil, levelChosen: values.panel.loudness != nil)
        Form {
            if busy {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10nKey.speakPanelBusy.text).foregroundStyle(.secondary)
                    }
                }
            }
            if ids.contains("pace") || ids.contains("pause") {
                Section(L10nKey.speakPhrasesTitle.text) {
                    phraseScope(values, scope: scope, finished: finished, busy: busy)
                    if ids.contains("pace") { paceRow(values, scope: scope, context: context, off: !finished || busy || scope == nil) }
                    if ids.contains("pause") { pauseRow(values, scope: scope, context: context, off: !finished || busy || scope == nil) }
                    if finished {
                        Toggle(L10nKey.speakPanelAllText.text, isOn: Binding(get: { values.panelAllText }, set: { model.data.speak.panelAllText = $0 }))
                            .disabled(busy)
                    }
                }
            }
            Section {
                if ids.contains("loudness") { loudnessRow(values, context: context, off: busy) }
                if ids.contains("quality") { qualityRow(values, context: context) }
                if ids.contains("cloneMode") { styleRow(values, context: context) }
                if ids.contains("seed") { seedRow(values, context: context) }
                if ids.contains("takes") { takesRow(values, context: context) }
            }
        }
        .formStyle(.grouped)
    }

    private struct Context {
        let engine: SpeakEngine
        let finished: Bool
        let allText: Bool
        let copies: Bool
        let reel: Bool
        let levelChosen: Bool

        func caption(_ row: String) -> String? {
            VoicePanelModel.captionKey(row: row, timing: VoicePanelModel.timing(of: row, engine: engine, finishedProject: finished),
                                       allText: allText, copiesRecording: copies, reel: reel, levelChosen: levelChosen)?.text
        }
    }

    private func caption(_ text: String?) -> some View {
        Group {
            if let text { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    // MARK: phrases

    /// The phrase the person clicked in the list (one line), or «Все фразы»; with none chosen, the hint to choose one.
    @ViewBuilder private func phraseScope(_ values: SpeakValues, scope: PanelScope?, finished: Bool, busy: Bool) -> some View {
        if !finished {
            Text(L10nKey.speakPanelNeedsProject.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if case .phrase(let n)? = scope, let chunk = values.phraseChunks.first(where: { $0.index == n }) {
            LabeledContent(L10nKey.speakPanelPhrase.text) {
                Text("\(chunk.index + 1). \(PhraseScript.preview(chunk.text))").lineLimit(1).truncationMode(.tail)
            }
        } else if scope == .all {
            LabeledContent(L10nKey.speakPanelPhrase.text) { Text(L10nKey.speakPanelAllPhrases.text) }
        } else {
            Text(L10nKey.speakPanelPickPhrase.text).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// The chunks the change goes to, for the value a row starts from.
    private func targets(_ values: SpeakValues, _ scope: PanelScope?) -> [ProduceChunkDetail] {
        switch scope {
        case .phrase(let n)?: return values.phraseChunks.filter { $0.index == n }
        case .all?: return values.phraseChunks
        case nil: return []
        }
    }

    private func paceRow(_ values: SpeakValues, scope: PanelScope?, context: Context, off: Bool) -> some View {
        let shared = VoicePanelModel.sharedValue(targets(values, scope).map { $0.pace == 0 ? 1.0 : $0.pace })
        return VStack(alignment: .leading, spacing: 4) {
            PanelSlider(title: L10nKey.speakPanelPace.text, range: 0.85...1.15, step: 0.01, initial: shared ?? 1, mixed: shared == nil && scope != nil,
                        valueText: { VoicePanelModel.paceValue($0).map { String(format: L10nKey.speakPanelPaceValue.text, Int(($0 * 100).rounded())) } ?? L10nKey.speakPanelPaceNeutral.text },
                        commit: { model.actions.speakPace($0) })
                .id("pace-\(String(describing: scope))-\(shared ?? -1)-\(values.panelEpoch)")
                .disabled(off)
            if !off { caption(context.caption("pace")) }
        }
    }

    private func pauseRow(_ values: SpeakValues, scope: PanelScope?, context: Context, off: Bool) -> some View {
        let shared = VoicePanelModel.sharedValue(targets(values, scope).map(\.pauseAfter))
        return VStack(alignment: .leading, spacing: 4) {
            PanelSlider(title: L10nKey.speakPanelPause.text, range: VoicePanelModel.pauseRange, step: 0.05, initial: shared ?? 0, mixed: shared == nil && scope != nil,
                        valueText: {
                            let v = VoicePanelModel.pauseValue($0)
                            return v == 0 ? L10nKey.speakPanelPauseNone.text : L10nKey.speakPanelPauseValue.text(v.formatted(.number.precision(.fractionLength(2)).locale(L10nBundle.locale)))
                        },
                        commit: { model.actions.speakPause($0) })
                .id("pause-\(String(describing: scope))-\(shared ?? -1)-\(values.panelEpoch)")
                .disabled(off)
            if !off { caption(context.caption("pause")) }
        }
    }

    // MARK: sound

    private func loudnessRow(_ values: SpeakValues, context: Context, off: Bool) -> some View {
        let current = values.panel.loudness
        var customValue = -16.0
        if case .custom(let v)? = current { customValue = v }
        return VStack(alignment: .leading, spacing: 4) {
            Picker(L10nKey.speakPanelLoudness.text, selection: model.speakLoudness) {
                Text(L10nKey.speakPanelLoudnessDefault.text).tag(LoudnessTarget?.none)
                Divider()
                ForEach(LoudnessTarget.presets, id: \.lufs) { target in
                    Text(target.titleKey.text).tag(LoudnessTarget?.some(target))
                }
                Text(L10nKey.speakPanelLoudnessCustom.text).tag(LoudnessTarget?.some(.custom(customValue)))
            }
            .disabled(off)
            if case .custom? = current {
                CustomLevel(initial: customValue) { model.speakLoudness.wrappedValue = .custom($0) }.disabled(off)
            }
            caption(context.caption("loudness"))
        }
    }

    private func qualityRow(_ values: SpeakValues, context: Context) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(L10nKey.speakPanelQuality.text, selection: Binding(
                get: { values.panel.quality ?? .final },
                set: { var s = values.panel; s.quality = $0; model.speakPanelSettings.wrappedValue = s })) {
                Text(L10nKey.speakPanelQualityDraft.text).tag(PanelQuality.draft)
                Text(L10nKey.speakPanelQualityFinal.text).tag(PanelQuality.final)
            }
            .pickerStyle(.segmented)
            caption(context.caption("quality"))
        }
    }

    private func styleRow(_ values: SpeakValues, context: Context) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(L10nKey.speakPanelStyle.text, selection: Binding(
                get: { values.panel.copiesRecording },
                set: { var s = values.panel; s.copiesRecording = $0; model.speakPanelSettings.wrappedValue = s })) {
                Text(L10nKey.speakPanelStyleVoiceOnly.text).tag(false)
                Text(L10nKey.speakPanelStyleCopy.text).tag(true)
            }
            .pickerStyle(.radioGroup)
            caption(context.caption("cloneMode"))
        }
    }

    private func seedRow(_ values: SpeakValues, context: Context) -> some View {
        let pinned = values.panel.seed
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(L10nKey.speakPanelSeed.text, isOn: Binding(
                get: { pinned != nil },
                set: { on in
                    var s = values.panel
                    s.seed = on ? (values.selectedProject?.seed.map(VoicePanelModel.seed) ?? Int.random(in: 1...999_999_999)) : nil
                    model.speakPanelSettings.wrappedValue = s
                }))
            if let pinned {
                TextField(L10nKey.speakPanelSeedNumber.text, value: Binding(
                    get: { pinned },
                    set: { var s = values.panel; s.seed = VoicePanelModel.seed($0); model.speakPanelSettings.wrappedValue = s }),
                          format: .number.grouping(.never))
                    .monospacedDigit()
                Button(L10nKey.speakPanelRandom.text) {
                    var s = values.panel
                    s.seed = Int.random(in: 1...999_999_999)
                    model.speakPanelSettings.wrappedValue = s
                }
                .buttonStyle(.link)
                if let projectSeed = values.selectedProject?.seed, projectSeed != pinned {
                    Button(L10nKey.speakPanelSeedFromProject.text) {
                        var s = values.panel
                        s.seed = VoicePanelModel.seed(projectSeed)
                        model.speakPanelSettings.wrappedValue = s
                    }
                    .buttonStyle(.link)
                }
            }
            caption(context.caption("seed"))
        }
    }

    private func takesRow(_ values: SpeakValues, context: Context) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(L10nKey.speakPanelTakes.text, selection: Binding(
                get: { values.panel.takes },
                set: { var s = values.panel; s.takes = $0.map(VoicePanelModel.takes); model.speakPanelSettings.wrappedValue = s })) {
                Text(L10nKey.speakPanelLoudnessDefault.text).tag(Int?.none)
                Divider()
                ForEach(1...3, id: \.self) { n in Text(String(format: L10nKey.speakPanelTakesValue.text, n)).tag(Int?.some(n)) }
            }
            caption(context.caption("takes"))
        }
    }
}

/// A slider that changes the sound only when it is let go and was really moved: dragging it must not send a change per tick, and
/// a tap must not rewrite a stored value through the snap. Starts from the value the phrase has; when the phrases differ
/// (`mixed`) it says «разные» and sends nothing until it is moved.
private struct PanelSlider: View {
    let title: String
    let range: ClosedRange<Double>
    let step: Double
    let initial: Double
    let mixed: Bool
    let valueText: (Double) -> String
    let commit: (Double) -> Void
    @State private var value: Double
    @State private var moved = false

    init(title: String, range: ClosedRange<Double>, step: Double, initial: Double, mixed: Bool,
         valueText: @escaping (Double) -> String, commit: @escaping (Double) -> Void) {
        self.title = title
        self.range = range
        self.step = step
        self.initial = initial
        self.mixed = mixed
        self.valueText = valueText
        self.commit = commit
        _value = State(initialValue: initial)
    }

    private var shownText: String { mixed && !moved ? L10nKey.speakPanelMixed.text : valueText(value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(shownText).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step) { editing in
                if !editing, VoicePanelModel.shouldCommit(moved: moved, mixed: mixed, initial: initial, value: value) {
                    commit(value)
                    moved = false
                }
            }
            .onChange(of: value) { _, _ in moved = true }
            .accessibilityLabel(title)
            .accessibilityValue(shownText)
        }
    }
}

/// «Своё» level: typed, and sent on Return, so typing never sends half a number.
private struct CustomLevel: View {
    let commit: (Double) -> Void
    @State private var level: Double

    init(initial: Double, commit: @escaping (Double) -> Void) {
        self.commit = commit
        _level = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(L10nKey.speakPanelLoudnessLevel.text, value: $level, format: .number)
                .monospacedDigit()
                .onSubmit { commit(level) }
            Text(L10nKey.speakPanelLoudnessCustomHint.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
