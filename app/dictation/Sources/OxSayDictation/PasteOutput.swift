import AppKit
import Carbon
import DictationCore

/// NSPasteboard.general as a DictationPasteboard.
final class SystemPasteboard: DictationPasteboard {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item -> [String: Data] in
            var types: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { types[type.rawValue] = data }
            }
            return types
        }
        return PasteboardSnapshot(items: items)
    }

    @discardableResult
    func writeText(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()
        let items = snapshot.items.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

/// Puts dictated text where the cursor is: borrows the clipboard, sends Cmd+V to
/// the frontmost app and gives the clipboard back. When pasting is not allowed or
/// not possible, the text stays on the clipboard and `onNotice` says why.
final class PasteOutput: TextOutput {
    var onNotice: ((String) -> Void)?
    /// Time for the target app to read the clipboard before it is restored.
    var restoreDelay: TimeInterval = 0.5

    private let board = SystemPasteboard()

    func deliver(_ text: String) {
        switch OutputPolicy.decide(secureInput: IsSecureEventInputEnabled(), accessibilityTrusted: AXIsProcessTrusted()) {
        case .clipboardOnly(let reason):
            board.writeText(text)
            onNotice?(reason)
        case .paste:
            let lease = ClipboardLease(board: board, text: text)
            postCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { lease.release() }
        }
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        // Only Command: a modifier still held from the hotkey must not turn this into ⌥⌘V.
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
