import AppKit
import DictationCore
import SwiftUI

/// The list/detail vertical split the section pages share: the panes never size the window, the list is held in
/// `listLimits` while the detail takes the slack. `position` gives the divider's first place, applied at the first
/// layout wide enough to honour it; an optional `store` is where a user's drag writes (Meetings keeps it on the
/// model, Озвучка keeps nothing and always starts at its own position).
/// The split's own view: a mouseDown that reaches it is on its divider — the panes take every other point — and AppKit
/// tracks the drag inside the call, so the flag stands exactly while the inner divider is dragged. A width may be
/// written back only then: a drag of the window's outer sidebar divider resizes these subviews too (with the left
/// button down all the same), and a width the outer clamp forced on the list must not overwrite the user's stored one.
/// A divider moved by keyboard or VoiceOver never reaches mouseDown, so those moves are not persisted (accepted: issue #454).
private final class DividerDragSplitView: NSSplitView {
    private(set) var dividerDragActive = false

    override func mouseDown(with event: NSEvent) {
        dividerDragActive = true
        super.mouseDown(with: event)
        dividerDragActive = false
    }
}

class ListDetailSplitController: NSSplitViewController {
    private let listLimits: ClosedRange<CGFloat>
    private let detailMinimum: CGFloat
    private let position: () -> CGFloat
    private let store: ((CGFloat) -> Void)?
    private let dragView = DividerDragSplitView()
    /// The stored width has been applied (the split was wide enough to honour it).
    private var applied = false
    /// True while this controller moves the divider itself: that move is never the user's choice and never written back.
    private var restoring = false

    init<List: View, Detail: View>(list: NSHostingController<List>, detail: NSHostingController<Detail>,
                                   listLimits: ClosedRange<CGFloat>, detailMinimum: CGFloat,
                                   position: @escaping () -> CGFloat, store: ((CGFloat) -> Void)? = nil) {
        self.listLimits = listLimits
        self.detailMinimum = detailMinimum
        self.position = position
        self.store = store
        super.init(nibName: nil, bundle: nil)
        splitView = dragView
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        // The panes' own sizes never drive the window; the split item limits do.
        list.sizingOptions = []
        detail.sizingOptions = []
        let listItem = NSSplitViewItem(viewController: list)
        listItem.minimumThickness = listLimits.lowerBound
        listItem.maximumThickness = listLimits.upperBound
        listItem.canCollapse = false
        // A larger window gives its extra width to the detail, not to the list.
        listItem.holdingPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 10)
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = detailMinimum
        detailItem.canCollapse = false
        addSplitViewItem(listItem)
        addSplitViewItem(detailItem)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLayout() {
        super.viewDidLayout()
        // A first layout at a provisional width would clamp the stored one: wait for the first layout that can honour it.
        guard !applied, splitView.bounds.width >= listLimits.lowerBound + MainWindowSpec.splitDividerWidth + detailMinimum else { return }
        applied = true
        restoring = true
        defer { restoring = false }
        splitView.setPosition(min(max(position(), listLimits.lowerBound), listLimits.upperBound), ofDividerAt: 0)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        // Only a drag of OUR divider by the user is stored: not our own restore, not a window resize, and not a drag
        // of the window's outer sidebar divider (it resizes these subviews too, and its clamp must not overwrite the width).
        guard let store, applied, !restoring, dragView.dividerDragActive,
              let list = splitViewItems.first?.viewController.view else { return }
        store(list.frame.width)
    }
}
