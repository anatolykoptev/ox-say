import DictationCore
import SwiftUI

/// The only way the window makes a button that is just a symbol: the VoiceOver label (which is also
/// the tooltip) comes with it. Made for the places a titled row cannot go — a find bar, a notice's
/// close, a one-glyph action.
public struct IconButton: View {
    let symbol: String
    let labelKey: L10nKey
    let action: () -> Void

    public init(symbol: String, labelKey: L10nKey, action: @escaping () -> Void) {
        self.symbol = symbol
        self.labelKey = labelKey
        self.action = action
    }

    public var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .accessibilityLabel(labelKey.text)
            .help(labelKey.text)
    }
}
