import AppKit

/// The controls of OxSay's overlay panels (the meeting plate, the cue card): AppKit buttons whose action is a closure.
/// One implementation, so every panel draws and wires a button the same way. On a borderless non-activating panel that
/// never becomes key these fire on the first click while another app stays frontmost.
@MainActor
public enum PlateControls {
    /// Holds a control's closure. A control keeps its target weakly, so `attach` ties it to the control's lifetime.
    public final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc public func fire() { run() }
    }

    private static var actionKey = 0

    /// Binds `action` to `owner` for as long as the owner lives; point a control or a gesture recognizer at the result.
    @discardableResult
    public static func attach(_ action: @escaping () -> Void, to owner: NSObject) -> Action {
        let target = Action(action)
        objc_setAssociatedObject(owner, &actionKey, target, .OBJC_ASSOCIATION_RETAIN)
        return target
    }

    /// A small push button.
    public static func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.target = attach(action, to: b)
        b.action = #selector(Action.fire)
        return b
    }

    /// A panel's least loud action, drawn smaller than the real buttons.
    public static func quietButton(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = button(title, action)
        b.bezelStyle = .inline
        return b
    }

    /// A small symbol-only button, named for VoiceOver and the tooltip.
    public static func iconButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> NSButton {
        let b = button("", action)
        b.bezelStyle = .inline
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        b.imagePosition = .imageOnly
        b.toolTip = label
        b.setAccessibilityLabel(label)
        return b
    }
}

/// Which display a panel is on, in the two forms the panels file their remembered places under.
public enum PlateDisplay {
    public static func id(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The display's UUID: what a remembered spot is filed under. The numeric id changes when a monitor reconnects.
    public static func key(_ screen: NSScreen) -> String? {
        guard let id = id(screen), let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid) else { return nil }
        return text as String
    }
}
