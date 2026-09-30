import Carbon
import DictationCore

/// A system-wide hotkey with press and release events, registered through Carbon's
/// RegisterEventHotKey. Unlike a CGEventTap it needs no Accessibility or Input
/// Monitoring permission, and it still sees the release that hold-to-talk needs.
/// While registered, the key combination no longer reaches other apps. It is
/// registered exclusively, which only catches another app that did the same:
/// ordinary registrations and macOS's own shortcuts do not make it fail (see
/// ShortcutConflict for the latter).
final class HotKey {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    private static var nextID: UInt32 = 1
    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Returns nil if the combination is taken by another app.
    init?(keyCode: UInt32, modifiers: UInt32) {
        id = HotKey.nextID
        HotKey.nextID += 1
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            // Every HotKey's handler sees every hotkey event: pass on the ones
            // that belong to another instance.
            var pressed = EventHotKeyID()
            let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard got == noErr, pressed.signature == HotKey.signature, pressed.id == hotKey.id else {
                return OSStatus(eventNotHandledErr)
            }
            switch GetEventKind(event) {
            case UInt32(kEventHotKeyPressed): hotKey.onDown?()
            case UInt32(kEventHotKeyReleased): hotKey.onUp?()
            default: return OSStatus(eventNotHandledErr)
            }
            return noErr
        }, types.count, &types, me, &handlerRef)
        guard installed == noErr else { return nil }
        let hotKeyID = EventHotKeyID(signature: HotKey.signature, id: id)
        let options = OptionBits(kEventHotKeyExclusive)
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), options, &hotKeyRef) == noErr else {
            // deinit still runs for a failed init and removes the handler; removing
            // it here too would dispose of it twice.
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private static let signature = OSType(0x4F58_5359) // 'OXSY'
}

/// The dictation key combinations the menu offers.
enum Shortcut: String, CaseIterable {
    case controlSpace
    case optionSpace

    var title: String {
        switch self {
        case .controlSpace: return "⌃Space"
        case .optionSpace: return "⌥Space"
        }
    }

    var keyCode: UInt32 { UInt32(kVK_Space) }

    /// Not an enabled macOS shortcut (⌃Space switches input sources on a stock Mac).
    var isFree: Bool {
        !ShortcutConflict.taken(keyCode: Int(keyCode), modifiers: Int(modifiers), by: Shortcut.systemShortcuts())
    }

    static func systemShortcuts() -> [SystemShortcut] {
        var ref: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&ref) == noErr,
              let entries = ref?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int else { return nil }
            let enabled = (entry[kHISymbolicHotKeyEnabled as String] as? Bool) ?? false
            return SystemShortcut(keyCode: code, modifiers: modifiers, enabled: enabled)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .controlSpace: return UInt32(controlKey)
        case .optionSpace: return UInt32(optionKey)
        }
    }
}
