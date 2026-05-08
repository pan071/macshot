import Cocoa

/// Real NSView container for a row (horizontal) or column (vertical) of ToolbarButtonViews.
/// Dark rounded background matching the existing toolbar look.
class ToolbarStripView: NSView {

    enum Orientation { case horizontal, vertical }

    let orientation: Orientation
    private(set) var buttonViews: [ToolbarButtonView] = []
    /// Set to true in editor mode so gap clicks pass through to the image beneath.
    var passesThrough = false
    /// Suppress hover visuals/callbacks while a toolbar-initiated drag is moving
    /// the whole toolbar panel under the cursor.
    var suppressesHover = false {
        didSet {
            if suppressesHover {
                for bv in buttonViews { bv.setHovered(false) }
            }
        }
    }

    var onClick: ((ToolbarButtonAction) -> Void)?
    var onRightClick: ((ToolbarButtonAction, NSView) -> Void)?
    var onHover: ((ToolbarButtonAction, Bool) -> Void)?
    var onButtonPressBegan: ((ToolbarButtonAction, ToolbarButtonView, NSEvent) -> Void)?
    var onButtonPressDragged: ((ToolbarButtonAction, ToolbarButtonView, NSEvent) -> Void)?
    var onButtonPressEnded: ((ToolbarButtonAction, ToolbarButtonView, NSEvent) -> Void)?
    var onButtonSecondaryPressBegan: ((ToolbarButtonAction, ToolbarButtonView, NSEvent) -> Void)?
    var onButtonSecondaryPressDragged: ((ToolbarButtonAction, ToolbarButtonView, NSEvent) -> Void)?
    var onButtonSecondaryPressEnded: ((ToolbarButtonAction, ToolbarButtonView, NSEvent) -> Void)?
    var onReorder: (([ToolbarButtonAction]) -> Void)?
    var isReorderEnabled: Bool = false
    private(set) var isPerformingReorder: Bool = false

    private let padding: CGFloat = 4
    private let spacing: CGFloat = 2
    private let reorderLongPressDuration: TimeInterval = 0.35
    private let reorderActivationDistanceSquared: CGFloat = 16
    private var pendingReorderButtonView: ToolbarButtonView?
    private var pendingReorderStartPoint: NSPoint = .zero
    private var reorderTimer: Timer?
    private var draggedButtonView: ToolbarButtonView?
    private var draggedButtonOffsetY: CGFloat = 0

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Strip-level tracking area: clears all button hovers when the cursor leaves
    /// the whole strip (covers the case where AppKit drops the last button's
    /// mouseExited in a non-activating panel).
    private var stripTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = stripTracking { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        stripTracking = ta
    }
    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseExited(with event: NSEvent) {
        clearInteractionState(clearPressed: !suppressesHover)
    }

    /// Rebuild buttons from ToolbarButton data.
    func setButtons(_ buttons: [ToolbarButton]) {
        cancelPendingReorder()
        endReorderIfNeeded(shouldNotify: false)
        for bv in buttonViews { bv.removeFromSuperview() }
        buttonViews.removeAll()

        for data in buttons {
            let bv = ToolbarButtonView(action: data.action, sfSymbol: data.sfSymbol, tooltip: data.tooltip)
            bv.isOn = data.isSelected
            bv.tintColor = data.tintColor
            bv.selectedTintColor = data.selectedTintColor
            bv.swatchColor = data.bgColor
            bv.hasContextMenu = data.hasContextMenu
            bv.onClick = { [weak self] action in self?.onClick?(action) }
            bv.onRightClick = { [weak self] action, view in self?.onRightClick?(action, view) }
            bv.onHover = { [weak self] action, hovered in self?.onHover?(action, hovered) }
            bv.onPressBegan = { [weak self] buttonView, event in
                self?.onButtonPressBegan?(buttonView.action, buttonView, event)
            }
            bv.onPressDragged = { [weak self] buttonView, event in
                self?.onButtonPressDragged?(buttonView.action, buttonView, event)
            }
            bv.onPressEnded = { [weak self] buttonView, event in
                self?.onButtonPressEnded?(buttonView.action, buttonView, event)
            }
            bv.onSecondaryPressBegan = { [weak self] buttonView, event in
                self?.handleButtonSecondaryPressBegan(buttonView, event: event)
                self?.onButtonSecondaryPressBegan?(buttonView.action, buttonView, event)
            }
            bv.onSecondaryPressDragged = { [weak self] buttonView, event in
                self?.handleButtonSecondaryPressDragged(buttonView, event: event)
                self?.onButtonSecondaryPressDragged?(buttonView.action, buttonView, event)
            }
            bv.onSecondaryPressEnded = { [weak self] buttonView, event in
                self?.handleButtonSecondaryPressEnded(buttonView, event: event)
                self?.onButtonSecondaryPressEnded?(buttonView.action, buttonView, event)
            }
            addSubview(bv)
            buttonViews.append(bv)
        }
        layoutButtons()
    }

    /// Clear hover on every button except `keep`. Called when a button is
    /// entered, to defensively reset any sibling AppKit failed to send
    /// mouseExited to (happens in non-activating glass chrome panels).
    func clearHover(except keep: ToolbarButtonView) {
        if suppressesHover { return }
        for bv in buttonViews where bv !== keep { bv.setHovered(false) }
    }

    func clearInteractionState(
        suppressHoverUntilMouseMoved suppress: Bool = false,
        clearPressed: Bool = true
    ) {
        for bv in buttonViews {
            bv.clearInteractionState(
                suppressHoverUntilMouseMoved: suppress,
                clearPressed: clearPressed)
        }
    }

    /// Update button state without rebuilding views.
    func updateState(from buttons: [ToolbarButton]) {
        for (i, data) in buttons.enumerated() where i < buttonViews.count {
            buttonViews[i].configure(with: data)
        }
    }

    /// Returns the current action order represented by the strip.
    func currentActions() -> [ToolbarButtonAction] {
        buttonViews.map(\.action)
    }

    /// Lays out the toolbar buttons and optionally preserves the dragged button position.
    private func layoutButtons(preserveDraggedButtonPosition: Bool = false) {
        let btnSize = ToolbarButtonView.size
        let count = CGFloat(buttonViews.count)
        guard count > 0 else {
            frame.size = .zero
            return
        }

        switch orientation {
        case .horizontal:
            let w = count * btnSize + max(0, count - 1) * spacing + padding * 2
            let h = btnSize + padding * 2
            frame.size = NSSize(width: w, height: h)
            // Left-align buttons
            for (i, bv) in buttonViews.enumerated() {
                bv.frame.origin = NSPoint(x: padding + CGFloat(i) * (btnSize + spacing), y: padding)
            }
        case .vertical:
            let w = btnSize + padding * 2
            let h = count * btnSize + max(0, count - 1) * spacing + padding * 2
            frame.size = NSSize(width: w, height: h)
            for (i, bv) in buttonViews.enumerated() {
                if preserveDraggedButtonPosition && isPerformingReorder && bv === draggedButtonView {
                    continue
                }
                // First button at top
                bv.frame.origin = NSPoint(x: padding, y: h - padding - btnSize - CGFloat(i) * (btnSize + spacing))
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    // Consume clicks on gaps between buttons so they don't fall through to OverlayView.
    // In editor mode (passesThrough), let gap clicks pass through so drawing works
    // over the toolbar area.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let result = super.hitTest(point), result !== self { return result }
        if passesThrough { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    deinit {
        reorderTimer?.invalidate()
    }

    /// Schedules a right-click long-press reorder gesture for vertical right-toolbar buttons.
    private func handleButtonSecondaryPressBegan(_ buttonView: ToolbarButtonView, event: NSEvent) {
        guard shouldEnableReorder else { return }

        // Track the original press point so normal drags can cancel reordering before it begins.
        pendingReorderButtonView = buttonView
        pendingReorderStartPoint = convert(event.locationInWindow, from: nil)

        reorderTimer?.invalidate()
        reorderTimer = Timer.scheduledTimer(withTimeInterval: reorderLongPressDuration, repeats: false) {
            [weak self, weak buttonView] _ in
            guard let self, let buttonView else { return }
            self.beginReorder(for: buttonView)
        }
    }

    /// Updates the pending or active reorder gesture while the secondary pointer is moving.
    private func handleButtonSecondaryPressDragged(_ buttonView: ToolbarButtonView, event: NSEvent) {
        if isPerformingReorder, draggedButtonView === buttonView {
            updateReorder(for: buttonView, event: event)
            return
        }

        guard pendingReorderButtonView === buttonView else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        let dx = currentPoint.x - pendingReorderStartPoint.x
        let dy = currentPoint.y - pendingReorderStartPoint.y

        // Moving before the hold delay means the user wants the button's normal drag behavior.
        if dx * dx + dy * dy > reorderActivationDistanceSquared {
            cancelPendingReorder()
        }
    }

    /// Ends the secondary-click reorder gesture and emits the updated action order when needed.
    private func handleButtonSecondaryPressEnded(_ buttonView: ToolbarButtonView, event: NSEvent) {
        _ = event
        if isPerformingReorder, draggedButtonView === buttonView {
            endReorderIfNeeded(shouldNotify: true)
            return
        }
        if pendingReorderButtonView === buttonView {
            cancelPendingReorder()
        }
    }

    /// Returns whether this strip should allow long-press reordering.
    private var shouldEnableReorder: Bool {
        orientation == .vertical && isReorderEnabled && buttonViews.count > 1
    }

    /// Cancels a queued long-press reorder that has not started yet.
    private func cancelPendingReorder() {
        reorderTimer?.invalidate()
        reorderTimer = nil
        pendingReorderButtonView = nil
    }

    /// Enters reorder mode and lifts the pressed button above the rest of the strip.
    private func beginReorder(for buttonView: ToolbarButtonView) {
        guard shouldEnableReorder, pendingReorderButtonView === buttonView else { return }

        cancelPendingReorder()
        isPerformingReorder = true
        draggedButtonView = buttonView

        let buttonPoint = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        draggedButtonOffsetY = buttonPoint.y - buttonView.frame.minY

        // Prevent the context menu action from firing when the reorder finishes.
        buttonView.suppressCurrentRightClick()
        buttonView.alphaValue = 0.92
        addSubview(buttonView, positioned: .above, relativeTo: nil)
    }

    /// Repositions the dragged button and updates the action order based on its current slot.
    private func updateReorder(for buttonView: ToolbarButtonView, event: NSEvent) {
        let buttonPoint = convert(event.locationInWindow, from: nil)
        let minY = padding
        let maxY = bounds.height - padding - ToolbarButtonView.size
        let newY = max(minY, min(buttonPoint.y - draggedButtonOffsetY, maxY))
        buttonView.frame.origin = NSPoint(x: padding, y: newY)

        let destinationIndex = destinationIndexForDraggedButton(buttonView)
        guard let currentIndex = buttonViews.firstIndex(where: { $0 === buttonView }), destinationIndex != currentIndex else {
            needsDisplay = true
            return
        }

        // Move the dragged button in the logical order so the layout and persisted result match.
        buttonViews.remove(at: currentIndex)
        buttonViews.insert(buttonView, at: destinationIndex)
        layoutButtons(preserveDraggedButtonPosition: true)
        needsDisplay = true
    }

    /// Computes the slot index that best matches the dragged button's current vertical center.
    private func destinationIndexForDraggedButton(_ buttonView: ToolbarButtonView) -> Int {
        let centerY = buttonView.frame.midY
        for index in 0..<buttonViews.count {
            let slotCenterY = slotCenterY(for: index)
            if centerY >= slotCenterY {
                return index
            }
        }
        return max(0, buttonViews.count - 1)
    }

    /// Returns the visual center Y of a button slot for the given index.
    private func slotCenterY(for index: Int) -> CGFloat {
        let step = ToolbarButtonView.size + spacing
        let originY = bounds.height - padding - ToolbarButtonView.size - CGFloat(index) * step
        return originY + ToolbarButtonView.size / 2
    }

    /// Finishes reorder mode, snaps buttons into place, and optionally publishes the new order.
    private func endReorderIfNeeded(shouldNotify: Bool) {
        cancelPendingReorder()
        guard isPerformingReorder, let draggedButtonView else { return }

        isPerformingReorder = false
        self.draggedButtonView = nil
        self.draggedButtonOffsetY = 0
        draggedButtonView.alphaValue = 1.0
        layoutButtons()
        needsDisplay = true

        // Only persist real reorder completions so view rebuilds do not spam UserDefaults.
        if shouldNotify {
            onReorder?(currentActions())
        }
    }
}
