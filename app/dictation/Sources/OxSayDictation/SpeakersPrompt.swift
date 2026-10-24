import AppKit
import DictationCore

/// The Speakers prompt: one row per speaker of the other side with a name
/// field, the start of what they said, and, where there are several voices, a
/// "same person as" pick; with two voices still under one label, the "Split by
/// voice" switch. It only collects the user's draft; the diff against the
/// daemon's state (SpeakerDraft.edits) and the request are the caller's.
@MainActor
enum SpeakersPrompt {
    private static let fieldWidth: CGFloat = 170
    private static let sampleWidth: CGFloat = 380

    /// Shows the prompt and returns the draft the user confirmed, or nil on Cancel.
    static func ask(title: String, state: SpeakersState) -> SpeakerDraft? {
        let alert = NSAlert()
        alert.messageText = title.isEmpty ? L10nKey.speakersTitle.text : "\(L10nKey.speakersTitle.text) — \(title)"
        alert.informativeText = L10nKey.speakersHint.text
        alert.addButton(withTitle: L10nKey.speakersSave.text)
        alert.addButton(withTitle: L10nKey.speakersCancel.text)

        var draft = SpeakerDraft(from: state)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12

        var fields: [String: NSTextField] = [:]
        var picks: [String: (button: NSPopUpButton, targets: [SpeakerInfo])] = [:]
        for s in state.speakers {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let field = NSTextField(string: s.name)
            field.placeholderString = s.name.isEmpty ? s.label : L10nKey.speakersNamePlaceholder.text
            field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
            fields[s.id] = field
            row.addArrangedSubview(field)
            let targets = draft.mergeTargets(for: s.id, in: state)
            if s.isVoice, !targets.isEmpty || s.mergedTo != nil {
                let caption = NSTextField(labelWithString: L10nKey.speakersSameAs.text)
                let button = NSPopUpButton(frame: .zero, pullsDown: false)
                button.addItem(withTitle: L10nKey.speakersNotMerged.text)
                // a voice already folded away keeps its current target in the list so the pick shows it
                var choices = targets
                if let to = s.mergedTo, !choices.contains(where: { $0.id == to }), let held = state.speakers.first(where: { $0.id == to }) { choices.append(held) }
                choices.forEach { button.addItem(withTitle: $0.name.isEmpty ? $0.label : $0.name) }
                if let to = s.mergedTo, let i = choices.firstIndex(where: { $0.id == to }) { button.selectItem(at: i + 1) }
                picks[s.id] = (button, choices)
                row.addArrangedSubview(caption)
                row.addArrangedSubview(button)
            }
            stack.addArrangedSubview(row)
            if !s.sample.isEmpty {
                let sample = NSTextField(wrappingLabelWithString: "“\(s.sample)”")
                sample.textColor = .secondaryLabelColor
                sample.preferredMaxLayoutWidth = sampleWidth
                stack.addArrangedSubview(sample)
            }
        }
        var splitBox: NSButton?
        if state.offersSplit {
            let box = NSButton(checkboxWithTitle: L10nKey.speakersSplit.text, target: nil, action: nil)
            let hint = NSTextField(wrappingLabelWithString: L10nKey.speakersSplitHint.text)
            hint.textColor = .secondaryLabelColor
            hint.preferredMaxLayoutWidth = sampleWidth
            stack.addArrangedSubview(box)
            stack.addArrangedSubview(hint)
            splitBox = box
        }
        stack.setFrameSize(stack.fittingSize)
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        for (id, field) in fields { draft.names[id] = field.stringValue }
        for (id, pick) in picks {
            let i = pick.button.indexOfSelectedItem
            draft.mergeInto[id] = i > 0 && i - 1 < pick.targets.count ? pick.targets[i - 1].id : nil
        }
        if let splitBox { draft.split = splitBox.state == .on }
        return draft
    }
}
