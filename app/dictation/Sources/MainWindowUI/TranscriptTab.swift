import DictationCore
import SwiftUI

/// The transcript: one row per turn, find inside it (⌘F, ⌘G, ⇧⌘G), and a click on a row plays the call from there.
/// The rows are a lazy stack, so a two-hour call costs what is on screen.
struct TranscriptTab: View {
    @ObservedObject var model: MainWindowModel
    let detail: MeetingDetail
    @State private var find = TranscriptFindState()
    @State private var findOpen = false
    @FocusState private var findFocused: Bool
    @State private var query = ""
    /// The parsed turns and the speakers' order, kept while the text is the same: a playback tick re-evaluates this
    /// view, and a two-hour transcript must not be parsed again for it.
    @State private var parsed = ParsedTranscript()

    private var info: MeetingInfo { detail.info }

    var body: some View {
        let (turns, order) = parsed.read(info.transcriptMD)
        if turns.isEmpty {
            Text(L10nKey.meetingTranscriptNone.text).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let gate = PlaybackGate.decide(audioDeleted: info.audioDeleted, recordingRunning: model.data.recordingElapsed != nil,
                                           status: info.status)
            let playing = playingTurn(turns)
            VStack(spacing: 0) {
                if findOpen { findBar(turns) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(turns) { t in
                                TurnRow(turn: t, order: order[t.speaker] ?? 0, gate: gate, playing: playing == t.id,
                                        marks: find.marks(in: t.id)) { model.actions.playTurn(info.id, t) }
                                    .id(t.id)
                            }
                        }
                        .padding(.vertical, 18).padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear { scrollToFocus(turns, proxy) }
                    .onChange(of: model.focus) { _ in scrollToFocus(turns, proxy) }
                    // The serial, not `current`: a new query that lands on the first match again, or Next with one
                    // match, leaves `current` where it was and must still scroll.
                    .onChange(of: find.serial) { _ in scrollToCurrentMatch(proxy) }
                }
            }
            .background(shortcuts(turns))
            .onAppear {
                if let q = model.initialFind, !findOpen {
                    findOpen = true
                    query = q
                    find.setQuery(q, turns: turns)
                }
            }
        }
    }

    // MARK: find

    private func findBar(_ turns: [TranscriptTurn]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10nKey.findPlaceholder.text, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($findFocused)
                .onSubmit { find.next() }
                .onChange(of: query) { find.setQuery($0, turns: turns) }
                .frame(maxWidth: 260)
            Text(counter).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .leading)
            Button { find.previous() } label: { Image(systemName: "chevron.up") }
                .help(L10nKey.findPrevious.text).accessibilityLabel(L10nKey.findPrevious.text)
                .disabled(find.matches.isEmpty)
            Button { find.next() } label: { Image(systemName: "chevron.down") }
                .help(L10nKey.findNext.text).accessibilityLabel(L10nKey.findNext.text)
                .disabled(find.matches.isEmpty)
            Spacer()
            Button { closeFind() } label: { Image(systemName: "xmark") }
                .help(L10nKey.findClose.text).accessibilityLabel(L10nKey.findClose.text)
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var counter: String {
        if let p = find.position { return String(format: L10nKey.findCounter.text, p.index, p.total) }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : L10nKey.findNone.text
    }

    /// ⌘F opens the bar, ⌘G and ⇧⌘G step through the matches. Invisible buttons: they exist only while this tab does.
    private func shortcuts(_ turns: [TranscriptTurn]) -> some View {
        ZStack {
            Button("") { openFind(turns) }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { find.next() }.keyboardShortcut("g", modifiers: .command)
            Button("") { find.previous() }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }

    /// ⌘F: opens the bar, or with the bar already open only focuses the field; the match the user is on stays.
    private func openFind(_ turns: [TranscriptTurn]) {
        if !findOpen {
            findOpen = true
            find.setQuery(query, turns: turns)
        }
        // The field exists only after the bar is drawn: focus on the next turn of the run loop, not in this transaction.
        DispatchQueue.main.async { findFocused = true }
    }

    private func closeFind() {
        findOpen = false
        query = ""
        find.setQuery("", turns: [])
    }

    private func scrollToCurrentMatch(_ proxy: ScrollViewProxy) {
        guard let id = find.currentTurnID else { return }
        withAnimation { proxy.scrollTo(id, anchor: .center) }
    }

    /// A search hit that was clicked: the line it matched.
    private func scrollToFocus(_ turns: [TranscriptTurn], _ proxy: ScrollViewProxy) {
        guard let focus = model.focus, focus.meetingID == info.id,
              case .transcript(let start, let speaker) = focus.destination,
              let id = TurnLocator.turnID(start: start, speaker: speaker, in: turns) else { return }
        // After the rows are laid out.
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }

    private func playingTurn(_ turns: [TranscriptTurn]) -> Int? {
        guard let p = model.data.playback, p.meetingID == info.id else { return nil }
        return TurnClock.currentTurn(at: p.position, in: turns)
    }

}

/// The turns of one transcript text and the order their speakers first speak in, parsed once per text. A class, so
/// reading it during a view update changes no state and triggers no update.
final class ParsedTranscript {
    private var text: String?
    private var turns: [TranscriptTurn] = []
    private var order: [String: Int] = [:]

    func read(_ markdown: String?) -> ([TranscriptTurn], [String: Int]) {
        if text != markdown || (text == nil && turns.isEmpty && markdown != nil) {
            text = markdown
            turns = markdown.map(TranscriptTurn.parse) ?? []
            order = [:]
            for t in turns where order[t.speaker] == nil { order[t.speaker] = order.count }
        }
        return (turns, order)
    }
}

private struct TurnRow: View {
    let turn: TranscriptTurn
    let order: Int
    let gate: PlaybackGate
    let playing: Bool
    let marks: (ranges: [Range<Int>], current: Int?)
    let play: () -> Void
    @State private var hovering = false

    /// Speaker, time and the play glyph: the part of a turn that plays it. The words below stay a plain selectable text,
    /// so a double or triple click selects them and never starts the audio.
    private func header(glyph: Bool) -> some View {
        HStack(spacing: 6) {
            Text(turn.speaker).fontWeight(.semibold)
            Text(turn.time).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if glyph {
                Image(systemName: playing ? "speaker.wave.2.fill" : "play.circle")
                    .font(.caption).foregroundStyle(playing ? Color.accentColor : Color.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SpeakerAvatar(name: turn.speaker, index: order, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                if gate.showsAffordance {
                    Button(action: play) { header(glyph: true) }
                        .buttonStyle(.plain)
                        .help(L10nKey.playFromHere.text)
                        .accessibilityLabel("\(L10nKey.playFromHere.text), \(turn.speaker) \(turn.time)")
                        .accessibilityAddTraits(.isButton)
                } else {
                    header(glyph: false)
                }
                // The turn's words as they are: no markup is read, so there is no link to make.
                Text(Highlights.styled(TextHighlight.attributed(turn.text, ranges: marks.ranges, current: marks.current)))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }

    private var rowFill: Color {
        if playing { return Color.accentColor.opacity(0.12) }
        return hovering && gate.showsAffordance ? Color.primary.opacity(0.05) : Color.clear
    }
}

/// Play or pause, where it is, scrub, stop. Shown under the tabs while this meeting's audio plays.
struct MiniPlayer: View {
    @ObservedObject var model: MainWindowModel
    let values: PlaybackValues
    @State private var scrub: Double?

    var body: some View {
        let total = max(values.duration ?? values.position, 1)
        HStack(spacing: 10) {
            Button { model.actions.togglePlayback() } label: {
                Image(systemName: values.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help((values.isPlaying ? L10nKey.playPause : L10nKey.playPlay).text)
            .accessibilityLabel((values.isPlaying ? L10nKey.playPause : L10nKey.playPlay).text)
            Text(MeetingBadgeModel.clock(scrub ?? values.position)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Slider(value: Binding(get: { min(scrub ?? values.position, total) }, set: { scrub = $0 }), in: 0...total) { editing in
                if !editing, let to = scrub {
                    model.actions.seekPlayback(to)
                    scrub = nil
                }
            }
            .accessibilityLabel(L10nKey.playPosition.text)
            Text(values.duration.map(MeetingBadgeModel.clock) ?? "–:––").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button { model.actions.stopPlayback() } label: { Image(systemName: "xmark") }
                .help(L10nKey.playStop.text).accessibilityLabel(L10nKey.playStop.text)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
