import AppKit
import Carbon
import DictationCore

/// The platform side of the speak-selection capture: the real AX read, the
/// synthetic ⌘C and the run-loop spin the copy lands through. The flow itself
/// — AX first, then the clipboard borrow — is `SelectionBorrow` in
/// DictationCore, so it runs against a fake pasteboard in tests.
final class SelectionCapture {
    private let board = SystemPasteboard(promised: false)
    /// The app's one memory of a slow clipboard, shared with `PasteOutput`.
    private let slowClipboard: SlowClipboardMemory
    /// One report per speak press — the path taken and every AX source's
    /// result, never content. Lets the real app's AX path be checked from the log.
    var onSelection: ((SelectionReport) -> Void)?

    init(slowClipboard: SlowClipboardMemory) { self.slowClipboard = slowClipboard }

    /// The selected text, or why it could not be read.
    func capture() -> (text: String?, problem: String?) {
        SelectionBorrow.capture(board: board,
                                selectedText: selectedText,
                                secureInput: IsSecureEventInputEnabled,
                                postCopy: postCommandC,
                                spin: { RunLoop.current.run(until: Date().addingTimeInterval($0)) },
                                readText: board.readText,
                                memory: slowClipboard,
                                onSelection: onSelection)
    }

    /// The focused element's AXSelectedText — the clipboard-free path. The
    /// system-wide element is asked first; when it yields no focused element
    /// (some callers get -25204 from it) the frontmost app's own element is.
    /// A Chromium/Electron app that still yields nothing is asked to publish its
    /// tree and read again (`ChromiumAXWake`, #220) before ⌘C is considered.
    private func selectedText() -> AXSelection {
        let front = NSWorkspace.shared.frontmostApplication
        func once() -> AXSelection {
            AXSelection.read(
                systemWide: { read(from: AXUIElementCreateSystemWide(), source: .systemWide) },
                app: {
                    guard let pid = front?.processIdentifier else {
                        return AXSelection(hasElement: false, error: AXError.noValue.rawValue, source: .app)
                    }
                    return read(from: AXUIElementCreateApplication(pid), source: .app)
                })
        }
        let first = once()
        guard AXIsProcessTrusted(), let front else { return first }
        let root = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(root, Self.axTimeout)
        return ChromiumAXWake.read(first: first,
                                   identity: { Self.identity(of: front) },
                                   attributes: AppElementAttributes(root: root),
                                   retry: once,
                                   spin: { RunLoop.current.run(until: Date().addingTimeInterval($0)) },
                                   now: Date.init)
    }

    /// The bundle id and the entries of `Contents/Frameworks`: what tells an
    /// Electron/Chromium app apart when no bundle-id list knows it.
    private static func identity(of app: NSRunningApplication) -> AppIdentity {
        var frameworks: [String] = []
        if let url = app.bundleURL?.appendingPathComponent("Contents/Frameworks"),
           let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            frameworks = names
        }
        return AppIdentity(bundleID: app.bundleIdentifier, frameworks: frameworks)
    }

    /// A hung target must not freeze the main thread: every element queried
    /// answers within this, or the call fails with kAXErrorCannotComplete.
    private static let axTimeout: Float = 0.3

    /// `root` → focused element → its subrole and AXSelectedText.
    private func read(from root: AXUIElement, source: AXSelection.Source) -> AXSelection {
        guard AXIsProcessTrusted() else {
            return AXSelection(hasElement: false, error: AXError.apiDisabled.rawValue, source: source)
        }
        // On the system-wide element (the `.systemWide` source) this sets the process-wide default, not a limit for
        // this one call: every AX element this app queries later answers within `axTimeout` too, until another
        // call changes it. On an app's element it bounds that app only.
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
        // The focused element: bound for this element alone (the process-wide default is set on `root` above).
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
        guard let events = PasteKey.commandEvents(.c, keyCode: c, source: source) else { return }
        events.down.post(tap: .cghidEventTap)
        events.up.post(tap: .cghidEventTap)
    }
}

/// The AXApplication element's boolean attributes, for `ChromiumAXWake`.
private struct AppElementAttributes: AXAppAttributes {
    let root: AXUIElement

    func read(_ name: String) -> AXAttributeValue {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(root, name as CFString, &value)
        switch error {
        case .success:
            guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return .unsupported }
            return .bool(CFBooleanGetValue((value as! CFBoolean)))
        case .attributeUnsupported, .noValue:
            return .unsupported
        default:
            return .error(error.rawValue)
        }
    }

    func write(_ name: String, _ value: Bool) -> Int32 {
        AXUIElementSetAttributeValue(root, name as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef).rawValue
    }
}
