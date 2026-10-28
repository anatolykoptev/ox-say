import DictationCore
import SwiftUI

/// The window's content: the section sidebar and the section's page. The package targets
/// macOS 13, where NavigationSplitView is available.
public struct MainWindowView: View {
    @ObservedObject var model: MainWindowModel

    public init(model: MainWindowModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(MainWindowSpec.visibleSections, selection: sectionBinding) { section in
                Label {
                    Text(section.titleKey.text)
                } icon: {
                    Image(systemName: section.symbol)
                }
                .badge(badge(for: section))
                .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            page
        }
        .frame(minWidth: MainWindowSpec.minimumWidth, minHeight: MainWindowSpec.minimumHeight)
        .environment(\.locale, L10nBundle.locale)
    }

    private var sectionBinding: Binding<MainSection?> {
        Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })
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
        case .reel, .projects: EmptyView()
        }
    }
}

extension MainSection {
    var symbol: String {
        switch self {
        case .meetings: return "person.2.fill"
        case .dictation: return "mic.fill"
        case .voices: return "person.wave.2.fill"
        case .settings: return "gearshape.fill"
        case .reel: return "film"
        case .projects: return "folder"
        }
    }
}
