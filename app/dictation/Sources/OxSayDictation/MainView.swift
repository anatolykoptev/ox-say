import DictationCore
import SwiftUI

/// The main window's content: a section sidebar and, for now, a placeholder
/// per section. NavigationSplitView — the package targets macOS 13, where it
/// is available, so no HSplitView fallback is needed.
struct MainView: View {
    @State private var selection: MainSection? = .reel

    var body: some View {
        NavigationSplitView {
            List(MainWindowSpec.visibleSections, selection: $selection) { section in
                Label(section.titleKey.text, systemImage: section.symbol)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            Placeholder(section: selection ?? .reel)
        }
        .frame(minWidth: MainWindowSpec.minimumWidth, minHeight: MainWindowSpec.minimumHeight)
    }
}

/// A title and one line while the section's real content does not exist yet.
private struct Placeholder: View {
    let section: MainSection

    var body: some View {
        VStack(spacing: 8) {
            Text(section.titleKey.text)
                .font(.title2)
            Text(section.placeholderKey.text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension MainSection {
    var symbol: String {
        switch self {
        case .reel: return "film"
        case .projects: return "folder"
        case .voices: return "person.wave.2"
        case .dictation: return "mic"
        case .settings: return "gear"
        }
    }
}
