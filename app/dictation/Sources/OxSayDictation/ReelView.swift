import DictationCore
import SwiftUI

/// The «Ролик» detail: the script editor that is also the phrase list, the
/// voice pick and the «Озвучить» button, then per-phrase progress and the
/// finished file's actions. It only draws what ReelModel decides.
struct ReelView: View {
    @ObservedObject var model: ReelModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                editor
                controls
                phrases
                progress
                result
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
    }

    /// The multi-line script field — the text IS the phrase editor — with the
    /// document import and the live length/phrase lines under it.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10nKey.reelScript.text).font(.headline)
            TextEditor(text: $model.editorText)
                .font(.body)
                .frame(minHeight: 140, maxHeight: 240)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
            HStack(alignment: .firstTextBaseline) {
                Button(L10nKey.reelOpenDocument.text) { model.openDocument() }
                    .disabled(model.readingDocument || model.jobActive)
                if model.readingDocument {
                    Text(L10nKey.reelReadingDocument.text).foregroundStyle(.secondary)
                }
                Spacer()
                Text(ScriptLimit.statusLine(editorText: model.editorText))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(String(format: L10nKey.reelPhrases.text, model.phraseCount))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// The voice pick and the create button with, under them, why it is grey
    /// (in plain words) or the last refusal.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Picker(L10nKey.reelVoice.text, selection: $model.voiceIndex) {
                    ForEach(model.voiceNames.indices, id: \.self) { i in
                        Text(model.voiceNames[i] ?? L10nKey.reelDefaultVoice.text).tag(i)
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.jobActive)
                Spacer()
                Button(L10nKey.reelCreate.text) { model.create() }
                    .disabled(!model.canCreate)
            }
            if let reason = model.blockReason {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// A row per phrase: its number, the start of its text, a status icon.
    private var phrases: some View {
        ForEach(model.rows) { row in
            HStack(alignment: .firstTextBaseline) {
                Text("\(row.index + 1).")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                Text(row.preview).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                icon(for: row.state)
            }
        }
    }

    /// The overall line ProduceText words, plus Stop / Continue on Battery.
    private var progress: some View {
        Group {
            if let job = model.job, !job.status.isTerminal {
                HStack(alignment: .firstTextBaseline) {
                    Text(ProduceText.progressRow(job, serviceWaiting: model.serviceWaiting))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if job.status == .pausedOnBattery {
                        Button(L10nKey.reelContinueBattery.text) { model.continueOnBattery() }
                    }
                    Button(L10nKey.reelStop.text) { model.stop() }
                }
            }
        }
    }

    /// A finished job: the daemon's own summary, the duration, and where the
    /// WAV can go (the person picks the place; nothing writes a default).
    private var result: some View {
        Group {
            if let job = model.job, job.status.isTerminal {
                if let finish = ProduceText.finishAlert(job) {
                    Text(finish.text).font(.callout).foregroundStyle(.secondary)
                }
                if let duration = ReelScript.durationText(job.durationS) {
                    Text(String(format: L10nKey.reelDuration.text, duration))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if job.outputPath != nil {
                    HStack {
                        Button(L10nKey.reelExport.text) { model.export() }
                        Button(L10nKey.reelShowInFinder.text) { model.reveal() }
                    }
                }
            }
        }
    }

    private func icon(for state: PhraseState) -> some View {
        switch state {
        case .pending:
            return AnyView(Image(systemName: "circle").foregroundStyle(.tertiary))
        case .rendering:
            return AnyView(ProgressView().controlSize(.small))
        case .done:
            return AnyView(Image(systemName: "checkmark.circle.fill").foregroundStyle(.green))
        case .failed:
            return AnyView(Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange))
        }
    }
}
