import DictationCore
import SwiftUI

/// The window's content: the section sidebar and the section's page, in a NavigationSplitView.
public struct MainWindowView: View {
    @ObservedObject var model: MainWindowModel
    private let switchShown: Bool
    private let live: Set<MainSection>

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
            // Settings sits apart at the bottom with the Advanced switch above it. The list answers only for its own
            // rows (the binding is nil while Settings is the section), and the Settings row sizes to its content.
            VStack(spacing: 0) {
                sidebarList(topSections)
                if switchShown { AdvancedSwitch(model: model) }
                if sections.contains(.settings) { SettingsRow(model: model) }
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

    private func sidebarList(_ rows: [MainSection]) -> some View {
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
    }

    private func binding(for rows: [MainSection]) -> Binding<MainSection?> {
        Binding(get: { rows.contains(model.section) ? model.section : nil },
                set: { if let s = $0 { model.section = s } })
    }

    /// A recording that runs shows on the Meetings row, wherever the user is.
    private func badge(for section: MainSection) -> Text? {
        guard section == .meetings, model.data.recordingElapsed != nil else { return nil }
        return Text("●").foregroundColor(.red)
    }

    @ViewBuilder private var page: some View {
        switch model.section {
        case .meetings: MeetingsPage(model: model)
        case .dictation: DictationPage(model: model)
        case .voices: VoicesPage(model: model)
        case .settings: SettingsPage(model: model)
        // Not live yet: unreachable until the section's own task lists it in `MainWindowSpec.liveSections`.
        case .speak, .transcribe, .models: EmptyView()
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

/// Settings, drawn under the list as a plain row: it sizes to its content (no fixed height, so a larger sidebar or
/// text size cannot clip it) and looks like a sidebar row. It is a button, so Space/Return and ⌘, reach it.
struct SettingsRow: View {
    @ObservedObject var model: MainWindowModel

    private var selected: Bool { model.section == .settings }

    var body: some View {
        Button { model.section = .settings } label: {
            Label {
                Text(MainSection.settings.titleKey.text)
            } icon: {
                Image(systemName: MainSection.settings.symbol)
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
