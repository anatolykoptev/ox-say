import DictationCore
import SwiftUI
import UniformTypeIdentifiers

/// Voice cleanup, at the foot of the Расшифровка page: the one place where a file is picked or dropped to be cleaned, how it
/// is going, and, when it is done, the cleaned file against the original. Every decision is `CleanSession`'s and
/// `CleanPlayback`'s; this view draws `CleanValues` and calls closures. It belongs to the file page only: nothing on
/// Встречи or Диктовка offers it, because meetings and dictation are never cleaned.
struct CleanBar: View {
    @ObservedObject var model: MainWindowModel
    @State private var pickingFile = false
    @State private var targeted = false

    private var values: CleanValues { model.data.clean }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(targeted ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.bar))
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result { model.actions.cleanPick(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard case .idle = values.state, let url = urls.first else { return false }
            model.actions.cleanPick(url)
            return true
        } isTargeted: { targeted = $0 }
    }

    @ViewBuilder private var content: some View {
        switch values.state {
        case .unavailable(let reason):
            row(symbol: "waveform.badge.minus", tint: .secondary, title: L10nKey.cleanTitle.text, detail: reason)
        case .idle(let firstUse):
            row(symbol: "waveform.badge.minus", tint: .accentColor, title: L10nKey.cleanTitle.text,
                detail: targeted ? L10nKey.cleanDropTargeted.text
                    : firstUse ? "\(L10nKey.cleanCaption.text) \(L10nKey.cleanCaptionFirstUse.text)" : L10nKey.cleanCaption.text) {
                Button(L10nKey.cleanPick.text) { pickingFile = true }
            }
        case .installing:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10nKey.cleanTitle.text)
                    Text(L10nKey.cleanInstalling.text).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
            }
            .accessibilityElement(children: .combine)
        case .working(let name, let cancelling):
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10nKey.cleanWorking.text(name)).lineLimit(1).truncationMode(.middle)
                    Text(L10nKey.cleanWorkingHint.text).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if cancelling {
                    Text(L10nKey.cleanCancelling.text).foregroundStyle(.secondary)
                } else {
                    Button(L10nKey.commonCancel.text) { model.actions.cleanCancel() }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10nKey.cleanWorking.text(name))
        case .done(let done):
            VStack(alignment: .leading, spacing: 10) {
                row(symbol: "checkmark.circle.fill", tint: .green, title: L10nKey.cleanDone.text(done.name),
                    detail: done.video ? L10nKey.cleanDoneVideo.text : L10nKey.cleanDoneAudio.text) {
                    Button(L10nKey.cleanReveal.text) { model.actions.cleanReveal() }
                    IconButton(symbol: "xmark", labelKey: .cleanClose) { model.actions.cleanDismiss() }
                }
                compare(done)
            }
        case .failed(let sentence):
            row(symbol: "exclamationmark.triangle.fill", tint: .orange, title: sentence, detail: nil) {
                Button(L10nKey.cleanTryAnother.text) { pickingFile = true }
                IconButton(symbol: "xmark", labelKey: .a11yDismiss) { model.actions.cleanDismiss() }
            }
        }
    }

    /// One line: a symbol, a title with an optional second line, and the buttons on the right.
    private func row<Trailing: View>(symbol: String, tint: Color, title: String, detail: String?,
                                     @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(3)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }

    /// The original against the cleaned file: one position, two sides.
    private func compare(_ done: CleanDone) -> some View {
        let playback = values.playback
        let length = max(playback.duration ?? done.seconds, 1)
        return HStack(spacing: 12) {
            Picker(L10nKey.cleanCompare.text, selection: Binding(get: { playback.side }, set: { model.actions.cleanSide($0) })) {
                Text(L10nKey.cleanSideOriginal.text).tag(CleanSide.original)
                Text(L10nKey.cleanSideCleaned.text).tag(CleanSide.cleaned)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            IconButton(symbol: playback.isPlaying ? "pause.fill" : "play.fill",
                       labelKey: playback.isPlaying ? .playPause : .playPlay) { model.actions.cleanPlayPause() }
            Slider(value: Binding(get: { min(playback.position, length) }, set: { model.actions.cleanSeek($0) }), in: 0...length)
                .accessibilityLabel(L10nKey.playPosition.text)
                .accessibilityValue(Self.clock(playback.position))
            Text("\(Self.clock(playback.position)) / \(Self.clock(length))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        return whole >= 3600
            ? String(format: "%d:%02d:%02d", whole / 3600, whole % 3600 / 60, whole % 60)
            : String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
