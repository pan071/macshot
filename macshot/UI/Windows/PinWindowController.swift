import Cocoa
import UniformTypeIdentifiers

@MainActor
protocol PinWindowControllerDelegate: AnyObject {
    func pinWindowDidClose(_ controller: PinWindowController)
}

@MainActor
class PinWindowController {

    weak var delegate: PinWindowControllerDelegate?

    private var window: NSPanel?
    private var pinView: PinView?
    private var image: NSImage
    private var initialWindowSize: NSSize
    private var initialWindowOrigin: NSPoint
    private static let minScale: CGFloat = 0.1
    private static let maxScale: CGFloat = 5.0

    init(image: NSImage, preferredScreen: NSScreen? = nil, preferredFrame: NSRect? = nil) {
        self.image = image

        let size = image.size
        let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame

        let windowSize: NSSize
        let origin: NSPoint
        if let preferredFrame, preferredFrame.width > 1, preferredFrame.height > 1 {
            // For screenshot pins, keep the pinned image exactly where the capture originally happened.
            windowSize = preferredFrame.size
            origin = preferredFrame.origin
        } else {
            // Fallback for clipboard/history pins: center on the requested screen and cap at 80% size.
            let maxW = screenFrame.width * 0.8
            let maxH = screenFrame.height * 0.8
            let scale = min(1.0, min(maxW / size.width, maxH / size.height))
            windowSize = NSSize(width: size.width * scale, height: size.height * scale)
            origin = NSPoint(
                x: screenFrame.midX - windowSize.width / 2,
                y: screenFrame.midY - windowSize.height / 2
            )
        }
        self.initialWindowSize = windowSize
        self.initialWindowOrigin = origin

        let panel = PinPanel(
            contentRect: NSRect(origin: origin, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Use PinView's custom drag handling so long pinned images can move beyond the screen edges consistently.
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = size
        // Allow scroll/magnify events to reach the view even when panel is not key
        panel.becomesKeyOnlyIfNeeded = true

        let view = PinView(image: image)
        view.frame = NSRect(origin: .zero, size: windowSize)
        view.autoresizingMask = [.width, .height]
        view.onClose = { [weak self] in
            self?.close()
        }
        view.onEdit = { [weak self] in
            self?.openInEditor()
        }
        view.onRotateLeft = { [weak self] in
            self?.rotatePinnedImage(counterClockwise: true)
        }
        view.onRotateRight = { [weak self] in
            self?.rotatePinnedImage(counterClockwise: false)
        }
        view.onZoom = { [weak self] factor, viewPoint in
            self?.zoom(by: factor, around: viewPoint)
        }
        view.onResetZoom = { [weak self] in
            self?.resetZoom()
        }

        panel.contentView = view
        self.window = panel
        self.pinView = view
    }

    private func zoom(by factor: CGFloat, around viewPoint: NSPoint) {
        guard let window = window else { return }
        let oldFrame = window.frame
        let oldSize = oldFrame.size

        // Compute new size, clamped
        let currentScale = oldSize.width / initialWindowSize.width
        let newScale = min(Self.maxScale, max(Self.minScale, currentScale * factor))
        if abs(newScale - currentScale) < 0.001 { return }

        let newSize = NSSize(
            width: round(initialWindowSize.width * newScale),
            height: round(initialWindowSize.height * newScale)
        )

        // Anchor: the screen point under the cursor stays fixed
        let cursorScreenPoint = NSPoint(
            x: oldFrame.origin.x + viewPoint.x,
            y: oldFrame.origin.y + viewPoint.y
        )
        let fractionX = viewPoint.x / oldSize.width
        let fractionY = viewPoint.y / oldSize.height
        let newOrigin = NSPoint(
            x: cursorScreenPoint.x - fractionX * newSize.width,
            y: cursorScreenPoint.y - fractionY * newSize.height
        )

        window.setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
        pinView?.zoomPercent = Int(round(newScale * 100))
    }

    private func resetZoom() {
        guard let window = window else { return }
        window.setFrame(NSRect(origin: initialWindowOrigin, size: initialWindowSize), display: true)
        pinView?.zoomPercent = 100
    }

    func show() {
        window?.orderFrontRegardless()
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        pinView = nil
        delegate?.pinWindowDidClose(self)
    }

    private func openInEditor() {
        // Keep the original pin visible so editing acts like opening a separate working copy rather than consuming the pinned image.
        DetachedEditorWindowController.open(
            image: image,
            windowLevel: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        )
    }

    /// Rotates the pinned image by 90 degrees and keeps the current zoom percentage stable.
    private func rotatePinnedImage(counterClockwise: Bool) {
        guard let rotatedImage = rotatedImage(from: image, counterClockwise: counterClockwise),
              let window else { return }

        let oldFrame = window.frame
        let oldBaseSize = initialWindowSize
        let scale = oldBaseSize.width > 0 ? oldFrame.width / oldBaseSize.width : 1.0
        let newBaseSize = NSSize(width: oldBaseSize.height, height: oldBaseSize.width)
        let newFrameSize = NSSize(width: newBaseSize.width * scale, height: newBaseSize.height * scale)
        // Keep the visual center stable so rotating a pin does not jump to another part of the screen.
        let newOrigin = NSPoint(
            x: oldFrame.midX - newFrameSize.width / 2,
            y: oldFrame.midY - newFrameSize.height / 2
        )

        image = rotatedImage
        initialWindowSize = newBaseSize
        initialWindowOrigin = newOrigin
        pinView?.image = rotatedImage
        window.contentAspectRatio = rotatedImage.size
        window.setFrame(NSRect(origin: newOrigin, size: newFrameSize), display: true)
        pinView?.zoomPercent = Int(round(scale * 100))
    }

    /// Creates a new image rotated 90 degrees from the current pinned image.
    private func rotatedImage(from image: NSImage, counterClockwise: Bool) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let sourceWidth = cgImage.width
        let sourceHeight = cgImage.height
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: sourceHeight,
            height: sourceWidth,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // Rotate in pixel space so the pin keeps crisp edges and the alpha channel intact.
        if counterClockwise {
            ctx.translateBy(x: 0, y: CGFloat(sourceWidth))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(sourceHeight), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        guard let rotatedCGImage = ctx.makeImage() else { return nil }
        return NSImage(
            cgImage: rotatedCGImage,
            size: NSSize(width: image.size.height, height: image.size.width)
        )
    }
}

// MARK: - Pin Panel (receives gesture events without activating the app)

private class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Relaxes AppKit's drag constraint so pinned images can move beyond screen edges while staying recoverable.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let screen = screen else { return frameRect }

        // Keep a small draggable strip visible so the user can always pull the pin back on screen.
        let minVisibleWidth = min(frameRect.width, 80)
        let minVisibleHeight = min(frameRect.height, 80)
        let visibleFrame = screen.visibleFrame

        // Allow the window to overflow every edge as long as the minimum visible strip remains accessible.
        let minX = visibleFrame.minX - frameRect.width + minVisibleWidth
        let maxX = visibleFrame.maxX - minVisibleWidth
        let minY = visibleFrame.minY - frameRect.height + minVisibleHeight
        let maxY = visibleFrame.maxY - minVisibleHeight

        let constrainedOrigin = NSPoint(
            x: min(max(frameRect.origin.x, minX), maxX),
            y: min(max(frameRect.origin.y, minY), maxY)
        )
        return NSRect(origin: constrainedOrigin, size: frameRect.size)
    }

    // Don't let Cmd+Q propagate to the app — just close the pin
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.keyCode == 12 {  // Q
            (contentView as? PinView)?.onClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Pin Content View

private class PinView: NSView {

    /// UserDefaults key for the optional double-click-to-close behavior on pinned screenshots.
    private static let doubleClickCloseDefaultsKey = "pinCloseOnDoubleClick"

    var onClose: (() -> Void)?
    var onEdit: (() -> Void)?
    var onRotateLeft: (() -> Void)?
    var onRotateRight: (() -> Void)?
    var onZoom: ((CGFloat, NSPoint) -> Void)?
    var onResetZoom: (() -> Void)?

    var image: NSImage {
        didSet { needsDisplay = true }
    }
    private var closeButton: NSButton?
    private var editButton: NSButton?
    private var rotateLeftButton: NSButton?
    private var rotateRightButton: NSButton?
    private var zoomLabel: NSTextField?
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var dragStartMouseScreenPoint: NSPoint?
    private var dragStartWindowOrigin: NSPoint?

    var zoomPercent: Int = 100 {
        didSet {
            zoomLabel?.stringValue = "\(zoomPercent)%"
            zoomLabel?.sizeToFit()
            needsLayout = true
        }
    }

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        setupButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeOverlayButton(symbol: String, action: Selector) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        btn.bezelStyle = .circular
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 12
        btn.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        btn.image = img
        btn.contentTintColor = .white
        btn.target = self
        btn.action = action
        btn.isHidden = true
        return btn
    }

    private func setupButtons() {
        let edit = makeOverlayButton(symbol: "pencil", action: #selector(editClicked))
        addSubview(edit)
        editButton = edit

        let rotateLeft = makeOverlayButton(symbol: "rotate.left", action: #selector(rotateLeftClicked))
        addSubview(rotateLeft)
        rotateLeftButton = rotateLeft

        let rotateRight = makeOverlayButton(symbol: "rotate.right", action: #selector(rotateRightClicked))
        addSubview(rotateRight)
        rotateRightButton = rotateRight

        let close = makeOverlayButton(symbol: "xmark", action: #selector(closeClicked))
        addSubview(close)
        closeButton = close

        let label = VerticallyCenteredTextField(labelWithString: "100%")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 12
        label.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        label.alignment = .center
        label.isHidden = true
        addSubview(label)
        zoomLabel = label
    }

    @objc private func closeClicked() {
        onClose?()
    }

    @objc private func editClicked() {
        onEdit?()
    }

    /// Forwards the left-rotation action to the owning pin controller.
    @objc private func rotateLeftClicked() {
        onRotateLeft?()
    }

    /// Forwards the right-rotation action to the owning pin controller.
    @objc private func rotateRightClicked() {
        onRotateRight?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        editButton?.isHidden = false
        rotateLeftButton?.isHidden = false
        rotateRightButton?.isHidden = false
        closeButton?.isHidden = false
        zoomLabel?.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        editButton?.isHidden = true
        rotateLeftButton?.isHidden = true
        rotateRightButton?.isHidden = true
        closeButton?.isHidden = true
        zoomLabel?.isHidden = true
    }

    override func layout() {
        super.layout()
        // Close button top-right, edit button to its left, zoom label to its left
        let btnSize: CGFloat = 24
        let btnY = bounds.maxY - 30
        closeButton?.frame = NSRect(x: bounds.maxX - 30, y: btnY, width: btnSize, height: btnSize)
        editButton?.frame  = NSRect(x: bounds.maxX - 58, y: btnY, width: btnSize, height: btnSize)
        rotateRightButton?.frame = NSRect(x: bounds.maxX - 86, y: btnY, width: btnSize, height: btnSize)
        rotateLeftButton?.frame = NSRect(x: bounds.maxX - 114, y: btnY, width: btnSize, height: btnSize)
        if let label = zoomLabel {
            let labelW = max(label.intrinsicContentSize.width + 14, 42)
            label.frame = NSRect(
                x: bounds.maxX - 114 - labelW - 6,
                y: btnY,
                width: labelW,
                height: btnSize
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        path.addClip()
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)

        // Subtle border
        NSColor.white.withAlphaComponent(0.3).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        border.lineWidth = 1
        border.stroke()
    }

    // Right-click context menu
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy to Clipboard", action: #selector(copyImage), keyEquivalent: "c")
        menu.addItem(withTitle: "Save As...", action: #selector(saveImage), keyEquivalent: "s")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Close", action: #selector(closeClicked), keyEquivalent: "")
        for item in menu.items {
            item.target = self
        }
        return menu
    }

    @objc private func copyImage() {
        ImageEncoder.copyToClipboard(image)
    }

    @objc private func saveImage() {
        guard let imageData = ImageEncoder.encode(image) else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [ImageEncoder.utType]
        savePanel.nameFieldStringValue = FilenameFormatter.defaultImageFilename()

        savePanel.directoryURL = SaveDirectoryAccess.directoryHint()

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                try? imageData.write(to: url)
                SaveDirectoryAccess.save(url: url.deletingLastPathComponent())
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if let label = zoomLabel, !label.isHidden, label.frame.contains(loc) {
            onResetZoom?()
            return
        }

        if shouldCloseOnDoubleClick(for: event) {
            onClose?()
            return
        }

        // Capture the initial drag anchor so pinned images can be repositioned even when AppKit's background dragging would clamp them.
        dragStartMouseScreenPoint = screenPoint(for: event)
        dragStartWindowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window,
              let dragStartMouseScreenPoint = dragStartMouseScreenPoint,
              let dragStartWindowOrigin = dragStartWindowOrigin else {
            return
        }

        let currentScreenPoint = screenPoint(for: event)
        // Move the entire pin window by the mouse delta so tall images can travel past the screen edges.
        let newOrigin = NSPoint(
            x: dragStartWindowOrigin.x + (currentScreenPoint.x - dragStartMouseScreenPoint.x),
            y: dragStartWindowOrigin.y + (currentScreenPoint.y - dragStartMouseScreenPoint.y)
        )
        window.setFrameOrigin(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        // Clear the drag anchors when the gesture ends so the next click starts a fresh drag session.
        dragStartMouseScreenPoint = nil
        dragStartWindowOrigin = nil
    }

    /// Converts the current mouse event into a screen-space point for custom pin dragging.
    private func screenPoint(for event: NSEvent) -> NSPoint {
        guard let window = window else { return .zero }
        let pointInWindow = event.locationInWindow
        return NSPoint(
            x: window.frame.origin.x + pointInWindow.x,
            y: window.frame.origin.y + pointInWindow.y
        )
    }

    /// Returns true when the current event should close the pin because the user enabled background double-click dismissal.
    private func shouldCloseOnDoubleClick(for event: NSEvent) -> Bool {
        // Ignore single clicks so normal dragging and focus behavior remain unchanged.
        guard event.clickCount >= 2 else { return false }

        // Respect the capture preference so the gesture is opt-in and defaults to disabled.
        let isEnabled = UserDefaults.standard.object(forKey: Self.doubleClickCloseDefaultsKey) as? Bool ?? false
        return isEnabled
    }

    // Scroll to zoom (mouse wheel and trackpad two-finger scroll)
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        // Trackpad sends fine-grained deltas; mouse wheel sends larger discrete steps
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.005 : 0.03
        let factor: CGFloat = 1.0 + delta * sensitivity
        let loc = convert(event.locationInWindow, from: nil)
        onZoom?(factor, loc)
    }

    // Pinch to zoom
    override func magnify(with event: NSEvent) {
        let factor = 1.0 + event.magnification
        let loc = convert(event.locationInWindow, from: nil)
        onZoom?(factor, loc)
    }

    // Keyboard: Escape to close
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Vertically centered NSTextField

private class VerticallyCenteredCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textSize = cellSize(forBounds: rect)
        let y = max(0, (rect.height - textSize.height) / 2)
        return NSRect(x: rect.origin.x, y: rect.origin.y + y, width: rect.width, height: textSize.height)
    }
}

private class VerticallyCenteredTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { VerticallyCenteredCell.self }
        set {}
    }
}
