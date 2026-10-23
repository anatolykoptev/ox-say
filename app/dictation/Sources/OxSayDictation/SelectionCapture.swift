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
    /// One report per speak press — the path taken and the AX read's error and
    /// source, never content. Lets the real app's AX path be checked from the log.
    var onSelection: ((SelectionReport) -> Void)?

    /// The selected text, or why it could not be read.
    func capture() -> (text: String?, problem: String?) {
        SelectionBorrow.capture(board: board,
                                selectedText: selectedText,
                                secureInput: IsSecureEventInputEnabled,
                                postCopy: postCommandC,
                                spin: { RunLoop.current.run(until: Date().addingTimeInterval($0)) },
                                readText: board.readText,
                                onRemoteCopy: onRemoteCopy,
                                onSelection: onSelection)
    }

    /// The focused element's AXSelectedText — the clipboard-free path. The
    /// system-wide element is asked first; when it yields no focused element
    /// (some callers get -25204 from it) the frontmost app's own element is.
    private func selectedText() -> AXSelection {
        AXSelection.read(
            systemWide: { read(from: AXUIElementCreateSystemWide(), source: .systemWide) },
            app: {
                guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
                    return AXSelection(hasElement: false, error: AXError.noValue.rawValue, source: .app)
                }
                return read(from: AXUIElementCreateApplication(pid), source: .app)
            })
    }

    /// A hung target must not freeze the main thread: every element queried
    /// answers within this, or the call fails with kAXErrorCannotComplete.
    private static let axTimeout: Float = 0.3

    /// `root` → focused element → its subrole and AXSelectedText.
    private func read(from root: AXUIElement, source: AXSelection.Source) -> AXSelection {
        guard AXIsProcessTrusted() else {
            return AXSelection(hasElement: false, error: AXError.apiDisabled.rawValue, source: source)
        }
        AXUIElementSetMessagingTimeout(root, Self.axTimeout)
        var focused: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused)
        guard focusError == .success else {
            return AXSelection(hasElement: false, error: focusError.rawValue, source: source)
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return AXSelection(hasElement: false, error: AXError.noValue.rawValue, source: source)
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.axTimeout)
        var subrole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        let secure = (subrole as? String) == (kAXSecureTextFieldSubrole as String)
        var value: CFTypeRef?
        let textError = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        return AXSelection(text: textError == .success ? value as? String : nil, secureField: secure,
                           hasElement: true, error: textError.rawValue, source: source)
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
