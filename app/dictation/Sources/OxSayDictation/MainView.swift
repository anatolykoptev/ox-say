import DictationCore
import MainWindowUI
import SwiftUI

/// The main window's content. The views live in MainWindowUI and take plain data;
/// the data is `MainWindowSource`'s, read from the daemon and the app's own stores.
struct MainView: View {
    let source: MainWindowSource

    var body: some View {
        MainWindowView(model: source.model)
    }
}
