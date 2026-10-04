import AppKit
import Carbon
import DictationCore

/// Reads the frontmost app's text selection for the speak hotkey. AX is asked
/// first — it costs nothing and touches nothing. When AX gives nothing, the
/// clipboard is borrowed: snapshotted, ⌘C is posted, the copy is read, and the
/// snapshot is put back. Dictation's own machinery, run in reverse.
final class SelectionCapture {
    private let board = SystemPasteboard(promised: false)

    /// The selected text, or why it could not be read.
    func capture() -> (text: String?, problem: String?) {
        let snapshot = PasteboardSnapshot.capture(board)
        switch SelectionPolicy.plan(axText: selectedText(),
                                    secureInput: IsSecureEventInputEnabled(),
                                    clipboardRestorable: snapshot.problems.isEmpty && !snapshot.isSensitive) {
        case .speak(let text): return (text, nil)
        case .decline(let reason): return (nil, reason)
        case .copy: break
        }
        let before = board.changeCount
        postCommandC()
        // The copy lands on the pasteboard asynchronously; a selection-less
        // ⌘C changes nothing and simply times out.
        let deadline = Date().addingTimeInterval(0.4)
        while board.changeCount == before && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        defer { board.restore(snapshot) }
        guard let text = board.readText(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, "Nothing selected to speak.")
        }
        return (text, nil)
    }

    /// The focused element's AXSelectedText — the clipboard-free path.
    private func selectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        return text
    }

    private func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let c = CGKeyCode(PasteKey.commandC(lookup: PasteOutput.layoutCharacter()))
        // Only Command: a modifier still held from the hotkey must not turn this into ⌃⌥C.
        let down = CGEvent(keyboardEventSource: source, virtualKey: c, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: c, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
