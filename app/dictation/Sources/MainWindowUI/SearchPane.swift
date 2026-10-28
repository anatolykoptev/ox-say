import DictationCore
import SwiftUI

/// The search field above the meetings list.
struct SearchField: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10nKey.searchPlaceholder.text, text: $model.queryText)
                .textFieldStyle(.plain)
            if !model.queryText.isEmpty {
                Button {
                    model.queryText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10nKey.searchClear.text)
                .accessibilityLabel(L10nKey.searchClear.text)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10).padding(.vertical, 8)
        .onChange(of: model.queryText) { model.actions.searchTyped($0) }
    }
}

/// What the list shows while a search is on: searching, nothing found, the daemon unreachable, or the meetings with
/// the places that matched.
struct SearchResults: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        let state = model.data.search
        switch state.phase {
        case .idle:
            EmptyView()
        case .searching:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L10nKey.searchSearching.text).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noResults(let result):
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                Text(L10nKey.searchNoneTitle.text).font(.headline)
                Text(L10nKey.searchNoneBody.text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                // Texts that could not be searched are not "nothing": the line says so.
                if let line = result.footnote() {
                    Text(line).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .busy:
            VStack(spacing: 8) {
                Text(L10nKey.searchBusy.text).foregroundStyle(.secondary)
                Button(L10nKey.commonRetry.text) { model.actions.retrySearch() }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let sentence):
            VStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                Text(sentence).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(L10nKey.commonRetry.text) { model.actions.retrySearch() }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results(let result):
            List {
                ForEach(result.meetings) { m in
                    Section {
                        // Row ids are unique across the whole list: a List reuses rows by id, and "hit 0" of two meetings
                        // must not be the same row.
                        ForEach(Array(m.hits.enumerated()), id: \.offset) { i, hit in
                            HitRow(hit: hit, query: state.query) { model.openHit(m.id, hit) }
                                .id("\(m.id)#\(i)")
                        }
                    } header: {
                        Text(MeetingRowModel.displayTitle(of: m.asInfo)).fontWeight(.semibold).lineLimit(1)
                    }
                }
                if let line = result.footnote() {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct HitRow: View {
    let hit: SearchHit
    let query: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    if hit.field == .transcript {
                        if let speaker = hit.speaker { Text(speaker).font(.caption2).foregroundStyle(.secondary) }
                        if let start = hit.start {
                            Text(MeetingBadgeModel.clock(start)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                // The snippet is other people's text: emphasised where it matched, and with no link in it.
                Text(Highlights.styled(SearchSnippet.attributed(hit.snippet, query: query), emphasiseBold: true))
                    .font(.callout).lineLimit(3).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var label: String {
        switch hit.field {
        case .title: return L10nKey.searchFieldTitle.text
        case .notes: return L10nKey.meetingTabNotes.text
        case .transcript: return L10nKey.meetingTabTranscript.text
        }
    }
}
