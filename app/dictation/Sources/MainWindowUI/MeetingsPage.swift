import DictationCore
import AppKit
import SwiftUI

/// Meetings: the recordings on the left, the chosen one on the right, in a native split view (`MeetingsSplit`, an
/// NSSplitViewController) inside the window's detail column. The window keeps ONE two-column NavigationSplitView for
/// every section: a second, three-column shape for Meetings would rebuild the sidebar on each switch and lose its width
/// and keyboard focus; SwiftUI's HSplitView ignores the list's ideal and maximum width and lets the detail overflow.
/// The toolbar, the search field, the notice bar and the delete alert stay on this page, outside the AppKit split, so
/// they reach the window as before.
struct MeetingsPage: View {
    @ObservedObject var model: MainWindowModel
    @State private var confirmDelete = false

    var body: some View {
        // An inset, not a stacked row: the bar does not change how tall the page must be.
        content
        .safeAreaInset(edge: .top, spacing: 0) { MeetingsNotice(model: model) }
        .toolbar {
            RecordToolbar(model: model)
            SelectionToolbar(model: model, confirmDelete: $confirmDelete)
        }
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
            ContentUnavailableView {
                Label(L10nKey.meetingsOffTitle.text, systemImage: "person.2.slash")
            } description: {
                Text(L10nKey.meetingsOffBody.text)
            } actions: {
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
            ContentUnavailableView {
                Label(L10nKey.meetingsDownTitle.text, systemImage: "bolt.horizontal.circle")
            } description: {
                Text(sentence)
            } actions: {
                Button(L10nKey.commonRetry.text) { model.actions.refresh() }.controlSize(.large)
            }
        case .empty:
            VStack(spacing: 0) {
                ContentUnavailableView {
                    Label(L10nKey.meetingsEmptyTitle.text, systemImage: "waveform.badge.mic")
                } description: {
                    Text(L10nKey.meetingsEmptyBody.text)
                } actions: {
                    Button(L10nKey.menuMeetingRecord.text) { model.actions.startRecording() }
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                PrivacyLine().padding(.bottom, 14)
            }
        case .list:
            VStack(spacing: 0) {
                // The failed-refresh bar spans the page, above both panes, as the notice bar does.
                if case .list(let stale?) = model.pageState {
                    NoticeBar(text: stale, symbol: "exclamationmark.triangle.fill", tint: .orange,
                              actionTitle: L10nKey.commonRetry.text) { model.actions.refresh() }
                }
                MeetingsSplit(model: model)
            }
                // The system search field, in the window toolbar: only while there is a list to search, so Off, Loading,
                // Down and Empty carry none. It writes the query the results are read from; Esc and the clear button are its own.
                .searchable(text: $model.queryText, placement: .toolbar, prompt: L10nKey.searchPlaceholder.text)
                .onChange(of: model.queryText) { _, text in model.actions.searchTyped(text) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The notice bar, when there is one, on top of the column it is inset into.
struct MeetingsNotice: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        if let notice = model.data.notice { NoticeBar(text: notice) { model.actions.dismissNotice() } }
    }
}

/// Record, or Stop while one runs: a window-level item, whatever column is up.
struct RecordToolbar: ToolbarContent {
    @ObservedObject var model: MainWindowModel

    var body: some ToolbarContent {
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
        }
    }
}

/// Open Folder, Copy Notes and Delete: items only while the list is up and a meeting is chosen, so none can act on a
/// meeting that is not on screen. Delete asks first (`confirmDelete`, answered by the page's alert).
struct SelectionToolbar: ToolbarContent {
    @ObservedObject var model: MainWindowModel
    @Binding var confirmDelete: Bool

    var body: some ToolbarContent {
        if case .list = model.pageState, let d = model.selectedDetail, model.selectedMeeting != nil {
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

/// The left pane: the recordings, 260...420 wide (the split's own limits), ideal 290.
struct MeetingsListColumn: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        MeetingList(model: model)
    }
}

/// The right pane: the chosen meeting, or the placeholder.
struct MeetingDetailColumn: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
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
}

/// The list and the meeting side by side, divided by a native split view. AppKit's NSSplitViewController honours the
/// list's 260...420 limits and its ideal width, keeps the list fixed while the window grows, and never lets the detail
/// drop under 300 (SwiftUI's HSplitView honoured none of these). The divider is remembered on the model, so it
/// survives a switch to another section and back.
struct MeetingsSplit: NSViewControllerRepresentable {
    @ObservedObject var model: MainWindowModel

    func makeNSViewController(context: Context) -> MeetingsSplitController { MeetingsSplitController(model: model) }
    func updateNSViewController(_ controller: MeetingsSplitController, context: Context) {}
}

final class MeetingsSplitController: NSSplitViewController {
    static let listLimits: ClosedRange<CGFloat> = CGFloat(MainWindowSpec.meetingsListWidth.minimum)...CGFloat(MainWindowSpec.meetingsListWidth.maximum)
    static let detailMinimum = CGFloat(MainWindowSpec.meetingsDetailMinimum)

    private let model: MainWindowModel
    /// The stored width has been applied (the split was wide enough to honour it).
    private var applied = false
    /// True while this controller moves the divider itself: that move is never the user's choice and never written back.
    private var restoring = false

    init(model: MainWindowModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let list = NSHostingController(rootView: MeetingsListColumn(model: model).environment(\.locale, L10nBundle.locale))
        let detail = NSHostingController(rootView: MeetingDetailColumn(model: model).environment(\.locale, L10nBundle.locale))
        // The panes' own sizes never drive the window; the split item limits do.
        list.sizingOptions = []
        detail.sizingOptions = []
        let listItem = NSSplitViewItem(viewController: list)
        listItem.minimumThickness = Self.listLimits.lowerBound
        listItem.maximumThickness = Self.listLimits.upperBound
        listItem.canCollapse = false
        // A larger window gives its extra width to the meeting, not to the list.
        listItem.holdingPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 10)
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = Self.detailMinimum
        detailItem.canCollapse = false
        addSplitViewItem(listItem)
        addSplitViewItem(detailItem)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLayout() {
        super.viewDidLayout()
        // A first layout at a provisional width would clamp the stored one: wait for the first layout that can honour it.
        guard !applied, splitView.bounds.width >= Self.listLimits.lowerBound + MainWindowSpec.splitDividerWidth + Self.detailMinimum else { return }
        applied = true
        restoring = true
        defer { restoring = false }
        splitView.setPosition(min(max(model.meetingsListWidth, Self.listLimits.lowerBound), Self.listLimits.upperBound), ofDividerAt: 0)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        // Only a drag of the divider by the user is stored: not our own restore, not a window resize.
        guard applied, !restoring, NSEvent.pressedMouseButtons & 1 != 0, view.window?.inLiveResize != true,
              let list = splitViewItems.first?.viewController.view else { return }
        model.meetingsListWidth = list.frame.width
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
            if model.data.search.phase == .idle {
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
            } else {
                SearchResults(model: model)
            }
            Divider()
            PrivacyLine()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .onChange(of: model.selectedMeeting) { _, id in
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
