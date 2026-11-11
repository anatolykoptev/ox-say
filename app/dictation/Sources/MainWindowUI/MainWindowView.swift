import DictationCore
import SwiftUI

/// The window's content: the section sidebar and the section's page, in a NavigationSplitView.
public struct MainWindowView: View {
    @ObservedObject var model: MainWindowModel
    private let switchShown: Bool
    private let live: Set<MainSection>
    /// Which of the two sidebar lists has the keyboard, so an arrow key that leaves one list can hand it to the other.
    @FocusState private var focusedList: SidebarList?

    /// `switchShown` and `live` default to what this build ships; the screenshot harness passes more to draw the parts
    /// that are not live yet.
    public init(model: MainWindowModel, switchShown: Bool = MainWindowSpec.showsAdvancedSwitch,
                live: Set<MainSection> = MainWindowSpec.liveSections) {
        self.model = model
        self.switchShown = switchShown
        self.live = live
    }

    public var body: some View {
        NavigationSplitView {
            // The sections are one List; Settings is a one-row List under the Advanced switch, in the bottom inset. Both
            // are bound to the model's one `section` (each answers only for its own rows), so the system draws the
            // selection in either and never in both.
            sidebarList(topSections, id: .sections)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        // The bar material and a hairline, as the bottom bar of Xcode's navigator has: before the
                        // scroll-edge effect of macOS 26, the sections list scrolls under this area and must not show
                        // through it.
                        Divider()
                        if switchShown { AdvancedSwitch(model: model) }
                        if sections.contains(.settings) {
                            OneRowList { sidebarList([.settings], id: .settings) }
                        }
                    }
                    .background(.bar)
                }
                .navigationSplitViewColumnWidth(min: MainWindowSpec.sidebarWidth.minimum, ideal: MainWindowSpec.sidebarWidth.ideal,
                                                max: MainWindowSpec.sidebarWidth.maximum)
        } detail: {
            page
                // One recognisable window: "OxSay" is the title whichever page is up, the section is the subtitle.
                // No page sets its own title; SwiftUI writes the last one it sees into the window.
                .navigationTitle(MainWindowSpec.windowTitleKey.text)
                .navigationSubtitle(MainWindowSpec.subtitleKey(for: model.section).text)
        }
        .frame(minWidth: MainWindowSpec.minimumWidth, minHeight: MainWindowSpec.minimumHeight)
        .environment(\.locale, L10nBundle.locale)
    }

    private var sections: [MainSection] { MainWindowSpec.sections(advanced: model.advanced, live: live) }
    private var topSections: [MainSection] { sections.filter { $0 != .settings } }

    private func sidebarList(_ rows: [MainSection], id: SidebarList) -> some View {
        List(rows, selection: binding(for: rows)) { section in
            Label {
                Text(section.titleKey.text)
            } icon: {
                Image(systemName: section.symbol)
            }
            .badge(badge(for: section))
            .tag(section)
        }
        .listStyle(.sidebar)
        .focused($focusedList, equals: id)
        // `onMoveCommand` never fires on a List (the table takes the arrow keys first; probed), `onKeyPress` does.
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in move(.down, from: id, plain: SidebarArrow.isPlain(press.modifiers)) }
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in move(.up, from: id, plain: SidebarArrow.isPlain(press.modifiers)) }
    }

    /// Down from the last section reaches Settings and up from Settings returns, as in Finder and Mail: the two lists
    /// read as one. Every other arrow, every arrow inside a list and every arrow with a modifier is the list's own
    /// (`.ignored`); the decision is `MainWindowSpec.sidebarMove`.
    private func move(_ arrow: SidebarArrow, from list: SidebarList, plain: Bool) -> KeyPress.Result {
        guard let hop = MainWindowSpec.sidebarMove(arrow, from: list, plain: plain, current: model.section, sections: sections) else {
            return .ignored
        }
        model.section = hop.section
        focusedList = hop.list
        return .handled
    }

    private func binding(for rows: [MainSection]) -> Binding<MainSection?> {
        Binding(get: { rows.contains(model.section) ? model.section : nil },
                set: {
                    if let s = $0 {
                        model.section = s
                    } else {
                        // A deselect to nothing (Cmd-click on the selected row) is not a choice. The model does not
                        // change, so nothing would redraw and the table would stay empty: ask for the getter again. The
                        // setter can run inside a view update (Advanced turned off on an advanced section), where a
                        // synchronous publish is SwiftUI's "Publishing changes from within view updates": send it on the
                        // next run-loop turn.
                        DispatchQueue.main.async { model.objectWillChange.send() }
                    }
                })
    }

    /// A recording that runs shows on the Meetings row, wherever the user is.
    private func badge(for section: MainSection) -> Text? {
        guard section == .meetings, model.data.recordingElapsed != nil else { return nil }
        return Text("●").foregroundColor(.red)
    }

    @ViewBuilder private var page: some View {
        switch model.section {
        case .speak: SpeakPage(model: model)
        case .meetings: MeetingsPage(model: model)
        case .dictation: DictationPage(model: model)
        case .voices: VoicesPage(model: model)
        case .transcribe: TranscribePage(model: model)
        case .settings: SettingsPage(model: model)
        // Not live yet: unreachable until the section's own task lists it in `MainWindowSpec.liveSections`.
        case .models: EmptyView()
        }
    }
}

extension MainSection {
    var symbol: String {
        switch self {
        case .speak: return "waveform"
        case .voices: return "person.wave.2.fill"
        case .dictation: return "mic.fill"
        case .meetings: return "person.2.fill"
        case .transcribe: return "doc.text"
        case .models: return "shippingbox"
        case .settings: return "gearshape.fill"
        }
    }
}

/// The one-row Settings list at the height its row needs. A List has no height of its own (`fixedSize` collapses it to 0),
/// so the height is the row plus the room around it. `contentMargins` does not move the table's own 10 pt above the
/// first row (probed), so `room` is that 10 pt plus 10 pt below: 4 pt more than the 6 pt measured on macOS 26, as slack for
/// the row metrics of macOS 14 and 15, which were not measured. The Shots probe fails the run if the row is clipped.
/// The row heights are the sidebar's for each icon size (System Settings > Appearance, passed down as `sidebarRowSize`):
/// 24 / 32 / 40 pt, measured on macOS 26 only. An older system draws the same or smaller rows (no clipping, a little more
/// air below); a row a few points larger still fits the slack, and the largest size is the fallback for a size not known yet.
struct OneRowList<Rows: View>: View {
    static var room: CGFloat { 20 }
    @Environment(\.sidebarRowSize) private var rowSize
    @ViewBuilder var rows: () -> Rows

    private var rowHeight: CGFloat {
        switch rowSize {
        case .small: return 24
        case .medium: return 32
        case .large: return 40
        @unknown default: return 40
        }
    }

    var body: some View {
        rows().scrollDisabled(true).frame(height: rowHeight + Self.room)
    }
}

/// The Advanced switch: one row above Settings. Its flip is the app's to save (`advancedChanged`).
struct AdvancedSwitch: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        // The words sit beside a mini switch on one line at the default sidebar width; the label stays the
        // switch's accessibility name (`labelsHidden` only hides it from view).
        HStack(spacing: 4) {
            Text(L10nKey.advancedMode.text).font(.system(size: 11)).lineLimit(1)
                // The Toggle below carries the name; reading both would say it twice.
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Toggle(L10nKey.advancedMode.text, isOn: $model.advanced)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityHint(L10nKey.advancedModeHint.text)
                .onChange(of: model.advanced) { model.advancedChanged($0) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
