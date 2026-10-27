import DictationCore
import MainWindowUI
import SwiftUI

/// The main window's content. The views live in MainWindowUI and take plain data;
/// this file is where the app hands them what it has.
///
/// PROTOTYPE: the data is `PreviewData` (sample), not the daemon, until the live
/// source lands. Nothing here polls: the model holds no timer, and `refresh` runs
/// when the window appears.
struct MainView: View {
    @StateObject private var model = MainWindowModel(data: PreviewData.make())

    var body: some View {
        MainWindowView(model: model)
    }
}
