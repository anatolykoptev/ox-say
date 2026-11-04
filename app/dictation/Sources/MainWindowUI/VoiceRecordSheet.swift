import DictationCore
import SwiftUI

/// «Записать свой голос»: a passage to read aloud, the live timer and meter, then the review (play, record again, name,
/// save). A window-modal sheet on the Voices page. It holds the name being typed and nothing else: which step comes
/// next, how long a take must be and what a meeting recording does to it are the model's (VoiceRecording), and every
/// button is one `VoiceRecordAction`. Return is the main button of the step; Esc stops and discards.
struct VoiceRecordSheet: View {
    let values: VoiceRecordValues
    let send: (VoiceRecordAction) -> Void
    @State private var label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(values: VoiceRecordValues, send: @escaping (VoiceRecordAction) -> Void) {
        self.values = values
        self.send = send
        _label = State(initialValue: values.recording.label)
    }

    private var recording: VoiceRecording { values.recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10nKey.voiceRecordTitle.text).font(.headline)
            switch recording.phase {
            case .needsMicrophone(let denied): microphone(denied: denied)
            case .ready, .failed: passageStep
            case .recording: recordingStep
            case .review(let seconds): reviewStep(seconds: seconds)
            case .saving, .saved: working
            }
        }
        .onChange(of: label) { _ in send(.edit(label: label)) }
        .padding(20)
        .frame(width: 460)
        // Esc stops and discards on every step; while the take is being sent the model keeps the sheet up (mayClose).
        .background(Button("") { send(.escape) }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true))
    }

    // MARK: steps

    /// The text to read, then «Записать».
    private var passageStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10nKey.voiceRecordIntro.text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            passage
            if case .failed(let sentence) = recording.phase {
                Label(sentence, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            whyLine
            HStack {
                Button(L10nKey.voiceRecordOtherText.text) { send(.nextPrompt) }.buttonStyle(.link)
                Spacer()
                Button(L10nKey.commonCancel.text) { send(.escape) }
                Button(L10nKey.voiceRecordStart.text) { send(.start) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var passage: some View {
        Text(recording.prompt)
            .font(.title3)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private var whyLine: some View {
        Label(L10nKey.voiceRecordWhy.text, systemImage: "mic")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func microphone(denied: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(denied ? L10nKey.voiceRecordNeedMic.text : L10nKey.voiceRecordWaitingMic.text,
                  systemImage: denied ? "mic.slash" : "mic")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            whyLine
            HStack {
                Spacer()
                Button(L10nKey.commonCancel.text) { send(.escape) }
                if denied {
                    Button(L10nKey.voiceRecordOpenSettings.text) { send(.openSettings) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var recordingStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            passage
            HStack(spacing: 14) {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(secondsText(recording.seconds))
                    .font(.system(.title3, design: .monospaced))
                    .accessibilityLabel(secondsText(recording.seconds))
                // Under Reduce Motion no bar moves: the seconds above are the only indicator.
                if !reduceMotion { meter }
                Spacer()
            }
            whyLine
            HStack {
                Spacer()
                Button(L10nKey.voiceRecordStop.text) { send(.stop) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var meter: some View {
        let bars = VoiceRecording.meterBars(levels: values.levels, reduceMotion: reduceMotion)
        return HStack(alignment: .center, spacing: 3) {
            ForEach(bars.indices, id: \.self) { index in
                Capsule().fill(.tint)
                    .frame(width: 4, height: 6 + CGFloat(bars[index]) * 22)
            }
        }
        .frame(height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10nKey.voiceRecordMeterLabel.text)
    }

    private func reviewStep(seconds: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            passage
            HStack(spacing: 10) {
                IconButton(symbol: values.playing ? "stop.fill" : "play.fill",
                           labelKey: values.playing ? .a11yPlayStop : .voiceRecordPlay) {
                    send(values.playing ? .stopPlay : .play)
                }
                Text(secondsText(seconds)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(L10nKey.voicesRenameField.text).font(.caption).foregroundStyle(.secondary)
                TextField("", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10nKey.voicesRenameField.text)
            }
            if let problem = recording.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !recording.canSave {
                Label(String(format: L10nKey.voiceRecordTooShort.text, Int(VoiceRecording.minimumSeconds)),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10nKey.commonCancel.text) { send(.escape) }
                Spacer()
                Button(L10nKey.voiceRecordAgain.text) { send(.start) }
                Button(L10nKey.voiceRecordSave.text) { send(.save) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!recording.canSave || VoiceLabel.clean(label) == nil)
            }
        }
    }

    private var working: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L10nKey.voiceRecordSaving.text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func secondsText(_ seconds: Double) -> String {
        L10nKey.voiceRecordSeconds.text(String(format: "%.1f", seconds))
    }
}
