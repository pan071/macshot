import Cocoa

/// Floating panel that shows a live preview of the scroll capture as it progresses.
/// Vertical capture prefers side placement; horizontal capture prefers top/bottom placement.
/// The preview scales down smoothly when approaching screen edges.
class ScrollCapturePreviewPanel: NSPanel {

    private let imageView = NSImageView()
    private let captureRect: NSRect
    private let targetScreen: NSScreen
    private let placement: Placement
    private var avoidFrame: NSRect?
    private static let previewWidth: CGFloat = 200
    private static let horizontalPreviewHeight: CGFloat = 160
    private static let margin: CGFloat = 12
    private static let minHeight: CGFloat = 100
    private static let minWidth: CGFloat = 160
    /// Half of the selection border stroke width (2.5pt during scroll capture).
    /// The stroke is centered on the rect edge, so the visible bottom sits this far below minY.
    private static let selectionBorderOutset: CGFloat = 1.25

    enum Placement { case left, right, above, below }

    init?(captureRect: NSRect, screen: NSScreen, overlayLevel: Int, axis: ScrollCaptureAxis = .vertical) {
        self.captureRect = captureRect
        self.targetScreen = screen

        // Pick a placement that matches the scroll direction and available screen space.
        let spaceLeft = captureRect.minX - screen.frame.minX
        let spaceRight = screen.frame.maxX - captureRect.maxX
        let spaceAbove = screen.visibleFrame.maxY - captureRect.maxY
        let spaceBelow = captureRect.minY - screen.visibleFrame.minY
        guard let placement = Self.choosePlacement(
            axis: axis,
            spaceLeft: spaceLeft,
            spaceRight: spaceRight,
            spaceAbove: spaceAbove,
            spaceBelow: spaceBelow,
            sideNeeded: Self.previewWidth + Self.margin * 2,
            verticalNeeded: Self.horizontalPreviewHeight + Self.margin * 2
        ) else {
            return nil
        }
        self.placement = placement

        // Build a small initial frame; updatePreview expands it after the first frame arrives.
        let frame = Self.initialFrame(
            captureRect: captureRect,
            screen: screen,
            placement: placement,
            previewWidth: Self.previewWidth,
            previewHeight: Self.horizontalPreviewHeight,
            minHeight: Self.minHeight,
            margin: Self.margin,
            selectionBorderOutset: Self.selectionBorderOutset
        )

        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: overlayLevel - 1)  // below overlay so HUD/stop button stays clickable
        ignoresMouseEvents = true
        isReleasedWhenClosed = false

        // Just the image with rounded corners, no container chrome
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]
        contentView = container

        imageView.frame = container.bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = axis == .horizontal ? .alignCenter : .alignTop
        container.addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Sets a screen-space frame that the live preview should not cover.
    func setAvoidFrame(_ frame: NSRect?) {
        avoidFrame = frame?.insetBy(dx: -Self.margin, dy: -Self.margin)
        if let image = imageView.image {
            updatePreview(image: image)
        }
    }

    /// Chooses the preview placement based on scroll direction and free space around the capture rect.
    private static func choosePlacement(
        axis: ScrollCaptureAxis,
        spaceLeft: CGFloat,
        spaceRight: CGFloat,
        spaceAbove: CGFloat,
        spaceBelow: CGFloat,
        sideNeeded: CGFloat,
        verticalNeeded: CGFloat
    ) -> Placement? {
        // Horizontal screenshots usually consume most of the width, so prefer vertical gaps first.
        if axis == .horizontal {
            if spaceBelow >= verticalNeeded { return .below }
            if spaceAbove >= verticalNeeded { return .above }
            if spaceRight >= sideNeeded { return .right }
            if spaceLeft >= sideNeeded { return .left }
            return nil
        }

        // Vertical screenshots usually consume most of the height, so keep the existing side-first behavior.
        if spaceRight >= sideNeeded { return .right }
        if spaceLeft >= sideNeeded { return .left }
        if spaceBelow >= verticalNeeded { return .below }
        if spaceAbove >= verticalNeeded { return .above }
        return nil
    }

    /// Creates the first visible panel frame before the stitched preview has a final aspect ratio.
    private static func initialFrame(
        captureRect: NSRect,
        screen: NSScreen,
        placement: Placement,
        previewWidth: CGFloat,
        previewHeight: CGFloat,
        minHeight: CGFloat,
        margin: CGFloat,
        selectionBorderOutset: CGFloat
    ) -> NSRect {
        // Use a compact frame so the panel appears immediately when scroll capture starts.
        switch placement {
        case .right:
            return NSRect(
                x: captureRect.maxX + margin,
                y: captureRect.minY - selectionBorderOutset,
                width: previewWidth,
                height: minHeight
            )
        case .left:
            return NSRect(
                x: captureRect.minX - margin - previewWidth,
                y: captureRect.minY - selectionBorderOutset,
                width: previewWidth,
                height: minHeight
            )
        case .above:
            let width = min(max(previewWidth, captureRect.width), screen.visibleFrame.width - margin * 2)
            let x = max(
                screen.visibleFrame.minX + margin,
                min(captureRect.midX - width / 2, screen.visibleFrame.maxX - width - margin)
            )
            return NSRect(x: x, y: captureRect.maxY + margin, width: width, height: previewHeight)
        case .below:
            let width = min(max(previewWidth, captureRect.width), screen.visibleFrame.width - margin * 2)
            let x = max(
                screen.visibleFrame.minX + margin,
                min(captureRect.midX - width / 2, screen.visibleFrame.maxX - width - margin)
            )
            return NSRect(x: x, y: captureRect.minY - margin - previewHeight, width: width, height: previewHeight)
        }
    }

    /// Update the preview with the latest stitched image.
    func updatePreview(image: NSImage) {
        imageView.image = image
        switch placement {
        case .left, .right:
            updateSidePreview(image: image)
        case .above, .below:
            updateHorizontalPreview(image: image)
        }
    }

    /// Updates a side preview used primarily by vertical scroll capture.
    private func updateSidePreview(image: NSImage) {
        // Keep the original vertical behavior so existing scroll capture remains familiar.

        let screenFrame = targetScreen.visibleFrame
        let x: CGFloat
        switch placement {
        case .right: x = captureRect.maxX + Self.margin
        case .left: x = captureRect.minX - Self.margin - Self.previewWidth
        case .above, .below: x = captureRect.maxX + Self.margin
        }

        // Anchor the bottom of the preview at the bottom of the capture rect,
        // and grow upward. Clamp so it doesn't exceed the screen top.
        let anchorBottom = captureRect.minY - Self.selectionBorderOutset  // align with visible border bottom
        let ceilingY = screenFrame.maxY - 20  // small margin from screen top
        let availableHeight = max(Self.minHeight, ceilingY - anchorBottom)

        // Desired height based on image aspect ratio
        let imageAspect = image.size.height / max(1, image.size.width)
        let contentWidth = Self.previewWidth - 8
        let desiredHeight = contentWidth * imageAspect + 8

        // Clamp to available space — image scales down proportionally inside the view
        let panelHeight = min(desiredHeight, availableHeight)

        // Anchor bottom at capture rect bottom, grow upward
        let panelBottom = anchorBottom + panelHeight <= ceilingY
            ? anchorBottom
            : ceilingY - panelHeight

        let preferredFrame = NSRect(x: x, y: panelBottom, width: Self.previewWidth, height: panelHeight)
        let newFrame = avoidOverlap(for: preferredFrame)
        setFrame(newFrame, display: true, animate: false)
    }

    /// Updates a top/bottom preview used primarily by horizontal scroll capture.
    private func updateHorizontalPreview(image: NSImage) {
        // Give horizontal captures a wide preview so newly stitched columns are visible.
        let screenFrame = targetScreen.visibleFrame
        let availableWidth = max(Self.minWidth, screenFrame.width - Self.margin * 2)
        let contentHeight = Self.horizontalPreviewHeight - 8
        let imageAspect = image.size.width / max(1, image.size.height)
        let desiredWidth = contentHeight * imageAspect + 8
        let panelWidth = min(max(Self.minWidth, desiredWidth), availableWidth)

        // Center the preview around the selected region while keeping it on-screen.
        let panelX = max(
            screenFrame.minX + Self.margin,
            min(captureRect.midX - panelWidth / 2, screenFrame.maxX - panelWidth - Self.margin)
        )

        // Place the preview in the chosen vertical gap and clamp it to the visible screen.
        let rawY: CGFloat
        switch placement {
        case .above:
            rawY = captureRect.maxY + Self.margin
        case .below:
            rawY = captureRect.minY - Self.margin - Self.horizontalPreviewHeight
        case .left, .right:
            rawY = captureRect.minY - Self.selectionBorderOutset
        }
        let panelY = max(
            screenFrame.minY + Self.margin,
            min(rawY, screenFrame.maxY - Self.horizontalPreviewHeight - Self.margin)
        )

        let preferredFrame = NSRect(
            x: panelX,
            y: panelY,
            width: panelWidth,
            height: Self.horizontalPreviewHeight
        )
        let newFrame = avoidOverlap(for: preferredFrame)
        setFrame(newFrame, display: true, animate: false)
    }

    /// Moves the preview away from the HUD/toolbar frame when the two would overlap.
    private func avoidOverlap(for frame: NSRect) -> NSRect {
        guard let avoidFrame, frame.intersects(avoidFrame) else { return frame }

        let screenFrame = targetScreen.visibleFrame
        let candidates: [NSRect]
        switch placement {
        case .left, .right:
            candidates = horizontalAvoidanceCandidates(for: frame, avoidFrame: avoidFrame, screenFrame: screenFrame)
        case .above, .below:
            candidates = verticalAvoidanceCandidates(for: frame, avoidFrame: avoidFrame, screenFrame: screenFrame)
        }

        return candidates.first { screenFrame.contains($0) && !$0.intersects(avoidFrame) } ?? frame
    }

    /// Builds side-preview alternatives that dodge the HUD without changing preview size.
    private func horizontalAvoidanceCandidates(
        for frame: NSRect,
        avoidFrame: NSRect,
        screenFrame: NSRect
    ) -> [NSRect] {
        // Try the opposite side first, then vertical nudges on the current side.
        let oppositeX: CGFloat
        switch placement {
        case .right:
            oppositeX = captureRect.minX - Self.margin - frame.width
        case .left:
            oppositeX = captureRect.maxX + Self.margin
        case .above, .below:
            oppositeX = frame.minX
        }

        let belowY = avoidFrame.minY - frame.height - Self.margin
        let aboveY = avoidFrame.maxY + Self.margin
        let clampedBelowY = max(screenFrame.minY + Self.margin, belowY)
        let clampedAboveY = min(screenFrame.maxY - frame.height - Self.margin, aboveY)

        return [
            NSRect(x: oppositeX, y: frame.minY, width: frame.width, height: frame.height),
            NSRect(x: frame.minX, y: clampedBelowY, width: frame.width, height: frame.height),
            NSRect(x: frame.minX, y: clampedAboveY, width: frame.width, height: frame.height)
        ]
    }

    /// Builds top/bottom-preview alternatives that dodge the HUD without changing preview size.
    private func verticalAvoidanceCandidates(
        for frame: NSRect,
        avoidFrame: NSRect,
        screenFrame: NSRect
    ) -> [NSRect] {
        // Try the opposite vertical gap first, then horizontal nudges.
        let oppositeY: CGFloat
        switch placement {
        case .above:
            oppositeY = captureRect.minY - Self.margin - frame.height
        case .below:
            oppositeY = captureRect.maxY + Self.margin
        case .left, .right:
            oppositeY = frame.minY
        }

        let leftX = avoidFrame.minX - frame.width - Self.margin
        let rightX = avoidFrame.maxX + Self.margin
        let clampedLeftX = max(screenFrame.minX + Self.margin, leftX)
        let clampedRightX = min(screenFrame.maxX - frame.width - Self.margin, rightX)

        return [
            NSRect(x: frame.minX, y: oppositeY, width: frame.width, height: frame.height),
            NSRect(x: clampedLeftX, y: frame.minY, width: frame.width, height: frame.height),
            NSRect(x: clampedRightX, y: frame.minY, width: frame.width, height: frame.height)
        ]
    }
}
