import DictationCore
import SwiftUI

/// Meetings: the recordings on the left, the chosen one on the right. The list is a lazy `List`
/// grouped by day; the toolbar holds Record and, for a chosen meeting, Open Folder, Copy Notes and Delete.
struct MeetingsPage: View {
    @ObservedObject var model: MainWindowModel
    @State private var confirmDelete = false

    var body: some View {
        // An inset, not a stacked row: the bar does not change how tall the page must be.
        content
        .safeAreaInset(edge: .top, spacing: 0) {
            if let notice = model.data.notice { NoticeBar(text: notice) { model.actions.dismissNotice() } }
        }
        .navigationTitle(L10nKey.sectionMeetings.text)
        .toolbar { toolbar }
        .alert(L10nKey.meetingDeleteTitle.text, isPresented: $confirmDelete) {
            Button(L10nKey.meetingDeleteConfirm.text, role: .destructive) {
                if let id = model.selectedMeeting { model.actions.deleteMeeting(id) }
            }
            Button(L10nKey.commonCancel.text, role: .cancel) {}
        } message: {
            Text(L10nKey.meetingDeleteBody.text)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.pageState {
        case .off:
            EmptyState(symbol: "person.2.slash", title: L10nKey.meetingsOffTitle.text,
                       message: L10nKey.meetingsOffBody.text) {
                Button(L10nKey.meetingsTurnOn.text) {
                    var settings = model.data.meetingSettings
                    settings.enabled = true
                    model.setMeetingSettings(settings)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text(L10nKey.meetingsLoading.text).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unreachable(let sentence):
            EmptyState(symbol: "bolt.horizontal.circle", title: L10nKey.meetingsDownTitle.text, message: sentence) {
                Button(L10nKey.commonRetry.text) { model.actions.refresh() }.controlSize(.large)
            }
        case .empty:
            VStack(spacing: 0) {
                EmptyState(symbol: "waveform.badge.mic", title: L10nKey.meetingsEmptyTitle.text,
                           message: L10nKey.meetingsEmptyBody.text) {
                    Button(L10nKey.menuMeetingRecord.text) { model.actions.startRecording() }
                        .controlSize(.large)
                }
                PrivacyLine().padding(.bottom, 14)
            }
        case .list(let stale):
            VStack(spacing: 0) {
                if let stale {
                    NoticeBar(text: stale, symbol: "exclamationmark.triangle.fill", tint: .orange,
                              actionTitle: L10nKey.commonRetry.text) { model.actions.refresh() }
                }
                HStack(spacing: 0) {
                    MeetingList(model: model)
                        .frame(width: 290)
                    Divider()
                    detail
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let d = model.selectedDetail {
            MeetingDetailView(model: model, detail: d, tab: model.initialMeetingTab)
                .id(d.info.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "text.alignleft").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                Text(L10nKey.meetingsSelect.text).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if model.meetingsEnabled {
            ToolbarItem(placement: .primaryAction) {
                if let elapsed = model.data.recordingElapsed {
                    Button { model.actions.stopRecording() } label: {
                        Label(L10nKey.menuMeetingStop.text(MeetingBadgeModel.clock(elapsed)), systemImage: "stop.circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .tint(.red)
                } else {
                    Button { model.actions.startRecording() } label: {
                        Label(L10nKey.menuMeetingRecord.text, systemImage: "record.circle")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            if let d = model.selectedDetail, model.selectedMeeting != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.actions.openMeetingFolder(d.info.id) } label: {
                        Label(L10nKey.meetingOpenFolder.text, systemImage: "folder")
                    }
                    Button { model.actions.copyNotes(d.info.id) } label: {
                        Label(L10nKey.meetingCopyNotes.text, systemImage: "doc.on.doc")
                    }
                    .disabled(d.info.notesMD == nil)
                    Button { confirmDelete = true } label: {
                        Label(L10nKey.meetingDelete.text, systemImage: "trash")
                    }
                }
            }
        }
    }
}

/// The list pane: a recording banner while one runs, then the days, then the privacy line.
private struct MeetingList: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        let groups = MeetingRowModel.groups(model.data.meetings, now: model.clock())
        VStack(spacing: 0) {
            if let elapsed = model.data.recordingElapsed {
                RecordingBanner(elapsed: elapsed) { model.actions.stopRecording() }
            }
            List(selection: $model.selectedMeeting) {
                ForEach(groups.indices, id: \.self) { g in
                    Section(groups[g].title) {
                        ForEach(groups[g].meetings, id: \.id) { m in
                            MeetingRow(info: m).tag(m.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            PrivacyLine()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .onChange(of: model.selectedMeeting) { id in
            if let id { model.actions.selectMeeting(id) }
        }
    }
}

private struct MeetingRow: View {
    let info: MeetingInfo

    var body: some View {
        let status = MeetingRowModel.status(of: info)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(MeetingRowModel.displayTitle(of: info)).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 6)
                if let started = info.started {
                    Text(MeetingRowModel.time(started)).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                StatusLabel(status: status)
                if let d = MeetingRowModel.duration(info.durationSeconds) {
                    Text("· \(d)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct RecordingBanner: View {
    let elapsed: TimeInterval
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 9, height: 9)
            Text(L10nKey.meetingsRecordingNow.text).fontWeight(.medium)
            Text(MeetingBadgeModel.clock(elapsed)).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Button(L10nKey.badgeStop.text, action: stop).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.red.opacity(0.10))
    }
}
