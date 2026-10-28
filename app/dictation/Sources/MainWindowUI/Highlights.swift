import DictationCore
import SwiftUI

/// How the marks the core puts on text look: a match is tinted, the current one stronger. Colours, not weight, so a
/// word the text itself had in bold is never mistaken for a match.
enum Highlights {
    static func styled(_ text: AttributedString, emphasiseBold: Bool = false) -> AttributedString {
        var out = text
        for run in out.runs {
            guard let kind = run.oxsayHighlight else { continue }
            out[run.range].backgroundColor = kind == .current ? Color.orange.opacity(0.55) : Color.yellow.opacity(0.4)
            if emphasiseBold { out[run.range].inlinePresentationIntent = .stronglyEmphasized }
        }
        return out
    }
}
