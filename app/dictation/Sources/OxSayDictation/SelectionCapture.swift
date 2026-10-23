import AppKit
import Carbon
import DictationCore

/// The platform side of the speak-selection capture: the real AX read, the
/// synthetic ⌘C and the run-loop spin the copy lands through. The flow itself
/// — AX first, then the clipboard borrow — is `SelectionBorrow` in
/// DictationCore, so it runs against a fake pasteboard in tests.
final class SelectionCapture {
    private let board = SystemPasteboard(promised: false)
    /// A ⌘C result landed over a Universal Clipboard copy: the iPhone copy is
    /// gone and cannot be put back. One log line, never user content.
    var onRemoteCopy: (() -> Void)?

    /// The selected text, or why it could not be read.
    func capture() -> (text: String?, problem: String?) {
        SelectionBorrow.capture(board: board,
                                selectedText: selectedText,
                                secureInput: IsSecureEventInputEnabled,
                                postCopy: postCommandC,
                                spin: { RunLoop.current.run(until: Date().addingTimeInterval($0)) },
                                readText: board.readText,
                                onRemoteCopy: onRemoteCopy)
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
