import DictationCore
import SwiftUI

/// The window's content: the section sidebar and the section's page. The package targets
/// macOS 13, where NavigationSplitView is available.
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
            // Settings sits apart at the bottom with the Advanced switch above it. Two lists share one selection:
            // each binding answers only for its own rows, so a single row is selected at a time.
            VStack(spacing: 0) {
                sidebarList(topSections)
                if switchShown { AdvancedSwitch(model: model) }
                sidebarList(bottomSections).frame(height: 56)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
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
    private var bottomSections: [MainSection] { sections.filter { $0 == .settings } }

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

/// The Advanced switch: one row above Settings. Its flip is the app's to save (`advancedChanged`).
struct AdvancedSwitch: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        Toggle(L10nKey.advancedMode.text, isOn: $model.advanced)
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityHint(L10nKey.advancedModeHint.text)
            .onChange(of: model.advanced) { model.advancedChanged($0) }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
