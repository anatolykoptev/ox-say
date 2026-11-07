import AppKit
import DictationCore
import MainWindowUI
import SwiftUI

// MARK: - Sidebar probe (SHOTS_PROBE=1): reads the sidebar's real AppKit state instead of looking at pixels.

/// The probe is a gate: any state that breaks an expectation prints PROBE FAIL and the run exits 1 (see `finishProbe`).
nonisolated(unsafe) var probeFailures = 0
func probeExpect(_ ok: Bool, _ message: @autoclosure () -> String) {
    if !ok { probeFailures += 1; print("PROBE FAIL \(message())") }
}
func finishProbe() -> Never {
    print("PROBE \(probeFailures == 0 ? "ok" : "FAILED: \(probeFailures) expectation(s)")")
    exit(probeFailures == 0 ? 0 : 1)
}

func sidebarTables(_ v: NSView, in window: NSWindow) -> [NSTableView] {
    var found: [NSTableView] = []
    if let t = v as? NSTableView, t.convert(t.bounds, to: nil).midX < 260 { found.append(t) }
    for s in v.subviews { found += sidebarTables(s, in: window) }
    return found.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
}

func firstText(_ v: NSView) -> String? {
    if let f = v as? NSTextField, !f.stringValue.isEmpty { return f.stringValue }
    for s in v.subviews { if let t = firstText(s) { return t } }
    return nil
}

/// One line per sidebar table: its rows, which are selected, its height, its place from the top of the window.
@MainActor func describeSidebar(_ window: NSWindow, _ model: MainWindowModel, _ tag: String) {
    guard let root = window.contentView else { return }
    let tables = sidebarTables(root, in: window)
    var selectedTotal = 0
    for (i, t) in tables.enumerated() {
        let rows = t.selectedRowIndexes.map { String($0) }
        selectedTotal += t.selectedRowIndexes.count
        let w = t.convert(t.bounds, to: nil)
        let top = root.bounds.height - w.maxY
        let clip = t.enclosingScrollView
        if t.numberOfRows == 1, let clip {
            probeExpect(t.rect(ofRow: 0).maxY <= clip.documentVisibleRect.maxY, "\(tag): the one row of table\(i) is clipped (row ends \(t.rect(ofRow: 0).maxY), list shows to \(clip.documentVisibleRect.maxY))")
        }
        print("PROBE \(tag) table\(i) nrows=\(t.numberOfRows) selectedRows=\(rows) selected=\(t.selectedRowIndexes.count) rowH=\(t.rowHeight) y=\(Int(top)) h=\(Int(w.height)) scrollH=\(Int(clip?.frame.height ?? -1)) bottomInset=\(Int(clip?.contentInsets.bottom ?? -1)) topInset=\(Int(clip?.contentInsets.top ?? -1)) row0=\(Int(t.rect(ofRow: 0).minY))..\(Int(t.rect(ofRow: 0).maxY)) visible=\(Int(clip?.documentVisibleRect.minY ?? -1))..\(Int(clip?.documentVisibleRect.maxY ?? -1)) first=\(window.firstResponder === t) ax=\(t.accessibilityRole()?.rawValue ?? "-")/\(t.accessibilityLabel() ?? "-")/rows=\(t.accessibilityRows()?.count ?? -1)")
    }
    print("PROBE \(tag) model=\(model.section) highlights=\(selectedTotal) tables=\(tables.count)")
    // Exactly one row is highlighted in the whole sidebar, and it is the model's section.
    probeExpect(selectedTotal == 1, "\(tag): \(selectedTotal) highlights, model says \(model.section)")
}

func spin(_ s: Double = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

/// Selects a row through the table's own API, which fires the same selection-did-change a click does. A synthetic
/// mouse event does not select in this headless window (the table is the hit view, nothing moves), so this is not a click.
func selectRow(_ table: NSTableView, row: Int) {
    table.selectRowIndexes([row], byExtendingSelection: false)
    spin(0.4)
    print("PROBE select-row \(row)")
}

func key(_ window: NSWindow, _ code: UInt16, _ chars: String, flags: NSEvent.ModifierFlags = []) {
    for t in [NSEvent.EventType.keyDown, .keyUp] {
        let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: chars,
                                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        window.sendEvent(e)
    }
}

@MainActor func probeSidebar(_ window: NSWindow, _ model: MainWindowModel, _ label: String) {
    guard let root = window.contentView else { return }
    func tables() -> [NSTableView] { sidebarTables(root, in: window) }
    describeSidebar(window, model, "\(label) start")
    probeKeyLoop(window, label + " start")
    // Selection, each way round.
    selectRow(tables().last!, row: 0)
    describeSidebar(window, model, "\(label) after-select-last-table")
    selectRow(tables()[0], row: 1)
    describeSidebar(window, model, "\(label) after-select-main-row1")
    // Model-driven selection.
    for s in [MainSection.dictation, .settings, .voices] where model.section != s {
        model.section = s; spin()
        describeSidebar(window, model, "\(label) model=\(s)")
    }
    // A deselect to nothing (Cmd-click on the selected row does this): the sidebar must show the model's section again.
    for i in 0..<tables().count {
        for s in [MainSection.voices, .settings] {
            model.section = s; spin()
            let t = tables()[i]
            let before = model.section
            t.deselectAll(nil); spin()
            describeSidebar(window, model, "\(label) deselect-table\(i)-from-\(s)")
            probeExpect(model.section == before, "\(label): deselect changed the model \(before) -> \(model.section)")
        }
    }
    // Arrow keys across the two lists, as Finder and Mail do: down from the last section reaches Settings, up returns.
    let tops = MainWindowSpec.sections(advanced: model.advanced, live: Set(MainSection.allCases)).filter { $0 != .settings }
    if tables().count == 2, let last = tops.last {
        if tops.count >= 2 {
            model.section = tops[tops.count - 2]; spin()
            window.makeFirstResponder(tables()[0]); spin(0.2)
            key(window, 125, "\u{F701}"); spin()
            probeExpect(model.section == last, "\(label): down-arrow from the second-last section left \(model.section), wanted \(last) (the list's own move)")
        }
        model.section = last; spin()
        window.makeFirstResponder(tables()[0]); spin(0.2)
        key(window, 125, "\u{F701}"); spin()
        probeExpect(model.section == .settings, "\(label): down-arrow from the last section left the section at \(model.section)")
        describeSidebar(window, model, "\(label) after-arrow-down")
        probeExpect(window.firstResponder === tables()[1], "\(label): after down-arrow the Settings list does not have the keyboard")
        key(window, 126, "\u{F700}"); spin()
        probeExpect(model.section == last, "\(label): up-arrow from Settings left the section at \(model.section), wanted \(last)")
        describeSidebar(window, model, "\(label) after-arrow-up")
        probeExpect(window.firstResponder === tables()[0], "\(label): after up-arrow the sections list does not have the keyboard")
        // A real keyboard's arrow carries .numericPad and .function: the hop must still happen.
        key(window, 125, "\u{F701}", flags: [.numericPad, .function]); spin()
        probeExpect(model.section == .settings, "\(label): down-arrow with numericPad+function left the section at \(model.section)")
        key(window, 126, "\u{F700}"); spin()
        probeExpect(model.section == last, "\(label): up-arrow after the flagged hop left the section at \(model.section)")
    }
    probeKeyLoop(window, label + " end")
}

/// The key-view loop: which views Tab visits from the main list, by the views' own links and by moving the first responder.
@MainActor func probeKeyLoop(_ window: NSWindow, _ label: String) {
    guard let root = window.contentView else { return }
    let ts = sidebarTables(root, in: window)
    func name(_ v: NSView?) -> String {
        guard let v else { return "nil" }
        if let i = ts.firstIndex(where: { $0 === v }) { return "sidebar-table\(i)" }
        return String(describing: type(of: v)).prefix(40) + "@x\(Int(v.convert(v.bounds, to: nil).midX))y\(Int(root.bounds.height - v.convert(v.bounds, to: nil).midY))"
    }
    func walk(_ step: (NSView) -> NSView?) -> String {
        var out: [String] = []; var v: NSView? = ts.first
        for _ in 0..<8 { guard let c = v, let n = step(c) else { break }; out.append(name(n)); v = n; if n === ts.first { break } }
        return out.joined(separator: " > ")
    }
    print("PROBE \(label) fullKeyboardAccess=\(NSApp.isFullKeyboardAccessEnabled)")
    print("PROBE \(label) tab-chain from table0: \(walk { $0.nextValidKeyView })")
    print("PROBE \(label) backtab-chain from table0: \(walk { $0.previousValidKeyView })")
    window.makeFirstResponder(ts.first)
    var moved: [String] = []
    for _ in 0..<4 { window.selectNextKeyView(nil); spin(0.1); moved.append(name(window.firstResponder as? NSView)) }
    print("PROBE \(label) tab-moves from table0: \(moved.joined(separator: " > "))")
}

func findSplit(_ vc: NSViewController?) -> NSSplitViewController? {
    guard let vc else { return nil }
    if let s = vc as? NSSplitViewController { return s }
    for c in vc.children { if let s = findSplit(c) { return s } }
    return nil
}

func findAll<T: NSView>(_ v: NSView, _ type: T.Type) -> [T] {
    ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { findAll($0, type) }
}

/// The sidebar at its widest and narrowest and collapsed: where the tables and the Advanced switch sit.
@MainActor func probeSidebarEdges(_ window: NSWindow, _ model: MainWindowModel, _ label: String) {
    guard let root = window.contentView,
          let split = findAll(root, NSSplitView.self).compactMap({ $0.delegate as? NSSplitViewController }).first ?? findSplit(window.contentViewController) else {
        print("PROBE \(label) edges: no split view controller found"); return
    }
    func geometry(_ tag: String) {
        let ts = sidebarTables(root, in: window)
        let sw = findAll(root, NSSwitch.self).first { $0.convert($0.bounds, to: nil).midX < 260 }
        let swTxt = sw.map { s -> String in let f = s.convert(s.bounds, to: nil); return "switch y=\(Int(root.bounds.height - f.maxY))..\(Int(root.bounds.height - f.minY)) x=\(Int(f.minX))..\(Int(f.maxX))" } ?? "switch none"
        let cols = ts.map { t -> String in
            let f = t.enclosingScrollView.map { $0.convert($0.bounds, to: nil) } ?? .zero
            return "scroll x=\(Int(f.minX))..\(Int(f.maxX)) y=\(Int(root.bounds.height - f.maxY))..\(Int(root.bounds.height - f.minY))"
        }
        print("PROBE \(label) \(tag): sidebar item collapsed=\(split.splitViewItems[0].isCollapsed) width=\(Int(split.splitViewItems[0].viewController.view.frame.width)) | \(swTxt) | \(cols.joined(separator: " | ")) | highlights=\(ts.reduce(0) { $0 + $1.selectedRowIndexes.count })")
        probeExpect(ts.reduce(0) { $0 + $1.selectedRowIndexes.count } == 1, "\(label) \(tag): not exactly one highlight")
        let w = split.splitViewItems[0].viewController.view.frame.width
        if !split.splitViewItems[0].isCollapsed { probeExpect(w >= 170 && w <= 240, "\(label) \(tag): sidebar width \(w) outside 170...240") }
    }
    geometry("default")
    for w in [100.0, 170.0, 240.0, 400.0] {
        split.splitView.setPosition(w, ofDividerAt: 0); spin(0.3)
        geometry("divider->\(Int(w))")
    }
    split.splitView.setPosition(190, ofDividerAt: 0); spin(0.3)
    split.toggleSidebar(nil); spin(0.8)
    geometry("collapsed")
    split.toggleSidebar(nil); spin(0.8)
    geometry("reopened")
}

