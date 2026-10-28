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

    private var info: MeetingInfo { detail.info }

    var body: some View {
        let turns = info.transcriptMD.map(TranscriptTurn.parse) ?? []
        if turns.isEmpty {
            Text(L10nKey.meetingTranscriptNone.text).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let order = speakerOrder(turns)
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
                    .onChange(of: find.current) { _ in scrollToCurrentMatch(proxy) }
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
            Button("") { findOpen = true; findFocused = true; find.setQuery(query, turns: turns) }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { find.next() }.keyboardShortcut("g", modifiers: .command)
            Button("") { find.previous() }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
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

    private func speakerOrder(_ turns: [TranscriptTurn]) -> [String: Int] {
        var order: [String: Int] = [:]
        for t in turns where order[t.speaker] == nil { order[t.speaker] = order.count }
        return order
    }
}

private struct TurnRow: View {
    let turn: TranscriptTurn
    let order: Int
    let gate: PlaybackGate
    let playing: Bool
    let marks: (ranges: [Range<Int>], current: Int?)
    let play: () -> Void

    var body: some View {
        let row = HStack(alignment: .top, spacing: 12) {
            SpeakerAvatar(name: turn.speaker, index: order, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(turn.speaker).fontWeight(.semibold)
                    Text(turn.time).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if gate.showsAffordance {
                        Image(systemName: playing ? "speaker.wave.2.fill" : "play.circle")
                            .font(.caption).foregroundStyle(playing ? Color.accentColor : Color.secondary)
                    }
                }
                // The turn's words as they are: no markup is read, so there is no link to make.
                Text(Highlights.styled(TextHighlight.attributed(turn.text, ranges: marks.ranges, current: marks.current)))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(playing ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        if gate.showsAffordance {
            row.contentShape(Rectangle()).onTapGesture(perform: play).help(L10nKey.playFromHere.text)
        } else {
            row
        }
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
