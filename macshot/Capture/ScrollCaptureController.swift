import Cocoa
import ScreenCaptureKit
import Vision

// MARK: - ScrollCaptureController

/// Scroll capture engine:
///
/// - **`CGWindowListCreateImage`** for on-demand frame capture — each grab is a
///   complete, compositor-finished snapshot. No stream management, no stale frames.
/// - **TIFF byte-by-byte comparison** — two consecutive identical TIFF representations
///   = content has truly stopped rendering. Zero tolerance, no false positives.
/// - **Timer-driven `captureAndCompare`** on a dedicated serial queue — consistent
///   timing, no main-thread contention.
/// - **Incremental stitching** — new content is merged into `mergedImage` immediately
///   after each match, keeping memory bounded (no storing all raw strips).
/// - **Vision-only offset detection** — `VNTranslationalImageRegistrationRequest`
///   for pixel-precise scroll offset measurement.
/// - **`matchNotFoundCount`** tracking — surfaces errors to the user via callbacks
///   instead of silently failing.
/// - **Programmatic scrolling** via `CGEventCreateScrollWheelEvent2`.
/// - **Frozen header detection** — identifies sticky headers and excludes from stitching.
/// - **Scrollbar exclusion** — auto-detects scrollbar width, excludes from comparisons.
/// - **Max height: 30,000 pixels** (configurable via UserDefaults).
@MainActor
final class ScrollCaptureController {

    // MARK: - Public state

    private(set) var stripCount: Int = 0
    private(set) var stitchedImage: CGImage?
    private(set) var stitchedPixelSize: CGSize = .zero
    private(set) var isActive: Bool = false
    private(set) var frozenTopHeight: CGFloat = 0

    /// Current estimated total height of the final image (points).
    var estimatedTotalHeight: CGFloat {
        guard let merged = mergedImage else { return 0 }
        return CGFloat(merged.height) / backingScale
    }

    // MARK: - Callbacks

    var onStripAdded:  ((Int) -> Void)?
    var onSessionDone: ((NSImage?) -> Void)?
    var onAutoScrollStarted: (() -> Void)?
    var onPreviewUpdated: ((NSImage) -> Void)?

    // MARK: - Config

    var excludedWindowIDs: [CGWindowID] = []

    // MARK: - Settings

    private var autoScrollEnabled: Bool = false
    private var autoScrollSpeed: Int = 3
    private var maxScrollHeight: Int = 30000
    private var frozenDetectionEnabled: Bool = true

    // MARK: - Private

    private let captureRect: NSRect
    private let screen: NSScreen
    private let axis: ScrollCaptureAxis
    private let backingScale: CGFloat

    // Dedicated serial queue for capture-and-compare (off main thread)
    private let captureQueue = DispatchQueue(label: "macshot.scrollcapture", qos: .userInitiated)

    // Frame state
    private var shotA: CGImage?          // previous frame
    private var shotB: CGImage?          // current frame
    private var lastComparedTIFF: Data?  // TIFF of last settled frame for byte comparison
    private var mergedImage: CGImage?    // accumulated stitched result
    private var headerHeight: Int = 0    // frozen header height in pixels
    private var headerDetectionDone: Bool = false
    private var headerDetectionSamples: Int = 0
    private var frozenLeadingWidth: Int = 0
    private var frozenLeadingDetectionDone: Bool = false
    private var frozenLeadingDetectionSamples: Int = 0

    // Scrollbar exclusion
    private var rightMarginPx: Int = 0
    private var bottomMarginPx: Int = 0
    private var rightMarginDetected: Bool = false

    // Match tracking
    private var matchNotFoundCount: Int = 0
    private let maxMatchNotFound: Int = 8  // stop after 8 consecutive failures
    private var didReportFirstMatch: Bool = false
    private var hasScrolledOnce: Bool = false
    private var consecutiveZeroShifts: Int = 0
    private let maxZeroShiftsBeforeStop: Int = 6

    // Scroll monitors (for manual scroll)
    private var scrollMonitorGlobal: Any?
    private var scrollMonitorLocal:  Any?

    // Auto-scroll
    private(set) var autoScrollActive: Bool = false
    private var autoScrollTask: Task<Void, Never>?

    // Manual scroll throttle
    private let manualCaptureInterval: TimeInterval = 0.15
    private var lastCaptureTime: TimeInterval = 0
    private var pendingCaptureTask: Task<Void, Never>?
    private var settlementTimer: Timer?
    private let settlementInterval: TimeInterval = 0.25

    // Guard: only one capture at a time
    private var isCapturing: Bool = false

    // Target app for scroll events
    private var targetAppPID: pid_t = 0

    // CGWindowList capture config
    private var targetWindowID: CGWindowID = kCGNullWindowID
    private var captureRectCG: CGRect = .zero  // CG coordinates (top-left origin)

    // MARK: - Init

    init(captureRect: NSRect, screen: NSScreen, axis: ScrollCaptureAxis = .vertical) {
        self.captureRect = captureRect
        self.screen      = screen
        self.axis = axis
        self.backingScale = screen.backingScaleFactor
    }

    // MARK: - Session

    func startSession() async {
        guard !isActive else { return }

        let ud = UserDefaults.standard
        autoScrollEnabled = ud.object(forKey: "scrollAutoScrollEnabled") as? Bool ?? false
        autoScrollSpeed = ud.object(forKey: "scrollAutoScrollSpeed") as? Int ?? 3
        maxScrollHeight = ud.object(forKey: "scrollMaxHeight") as? Int ?? 30000
        frozenDetectionEnabled = ud.object(forKey: "scrollFrozenDetection") as? Bool ?? true

        // Convert AppKit coords to CG coords (top-left origin) for CGWindowListCreateImage
        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        captureRectCG = CGRect(
            x: captureRect.origin.x,
            y: primaryScreenH - captureRect.maxY,
            width: captureRect.width,
            height: captureRect.height
        )

        // Find the target window under the capture region
        resolveTargetWindow()
        resolveTargetApp()

        // Capture first settled frame
        guard let firstFrame = await captureSettledFrame() else {
            onSessionDone?(nil)
            return
        }

        isActive = true
        shotA = nil
        shotB = nil
        lastComparedTIFF = nil
        mergedImage = firstFrame
        headerHeight = 0
        headerDetectionDone = false
        headerDetectionSamples = 0
        frozenLeadingWidth = 0
        frozenLeadingDetectionDone = false
        frozenLeadingDetectionSamples = 0
        rightMarginPx = 0
        bottomMarginPx = 0
        rightMarginDetected = false
        matchNotFoundCount = 0
        didReportFirstMatch = false
        hasScrolledOnce = false
        consecutiveZeroShifts = 0
        frozenTopHeight = 0
        stripCount = 1

        stitchedImage = firstFrame
        stitchedPixelSize = CGSize(width: CGFloat(firstFrame.width), height: CGFloat(firstFrame.height))
        emitPreview()
        onStripAdded?(stripCount)

        if autoScrollEnabled {
            startAutoScroll()
        } else {
            startManualScrollMonitors()
        }
    }

    func stopSession() {
        guard isActive else { return }
        isActive = false

        autoScrollTask?.cancel(); autoScrollTask = nil
        settlementTimer?.invalidate(); settlementTimer = nil
        pendingCaptureTask?.cancel(); pendingCaptureTask = nil
        if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
        if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
        autoScrollActive = false

        // Deliver final image
        let finalImage: NSImage?
        if let cg = mergedImage {
            let ptSize = CGSize(width: CGFloat(cg.width) / backingScale,
                                height: CGFloat(cg.height) / backingScale)
            finalImage = NSImage(cgImage: cg, size: ptSize)
        } else {
            finalImage = nil
        }
        onSessionDone?(finalImage)
    }

    func cancelSession() {
        guard isActive else { return }
        isActive = false

        autoScrollTask?.cancel(); autoScrollTask = nil
        settlementTimer?.invalidate(); settlementTimer = nil
        pendingCaptureTask?.cancel(); pendingCaptureTask = nil
        if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
        if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
        autoScrollActive = false
    }

    // MARK: - Target window/app management

    /// Finds the window ID under the capture region center for targeted capture.
    private func resolveTargetWindow() {
        let centerX = captureRectCG.midX
        let centerY = captureRectCG.midY

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let excluded = Set(excludedWindowIDs)
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winID = info[kCGWindowNumber as String] as? Int,
                  !excluded.contains(CGWindowID(winID))
            else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            let cgRect = CGRect(x: x, y: y, width: w, height: h)

            if cgRect.contains(CGPoint(x: centerX, y: centerY)) {
                targetWindowID = CGWindowID(winID)
                return
            }
        }
    }

    private func resolveTargetApp() {
        let centerX = captureRectCG.midX
        let centerY = captureRectCG.midY

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let excluded = Set(excludedWindowIDs)
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winID = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  !excluded.contains(CGWindowID(winID))
            else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            let cgRect = CGRect(x: x, y: y, width: w, height: h)

            if cgRect.contains(CGPoint(x: centerX, y: centerY)) {
                targetAppPID = pid
                return
            }
        }
    }

    private func activateTargetApp() {
        guard targetAppPID != 0 else { return }
        NSRunningApplication(processIdentifier: targetAppPID)?.activate(options: [])
    }

    // MARK: - Frame capture via CGWindowListCreateImage

    /// Captures the screen region using CGWindowListCreateImage.
    /// Returns a complete, compositor-finished snapshot — no stream management needed.
    private func captureFrame() -> CGImage? {
        let excludeSet = Set(excludedWindowIDs)
        let listOption: CGWindowListOption = [.optionOnScreenBelowWindow]
        let windowID = excludeSet.isEmpty ? kCGNullWindowID : (excludeSet.first ?? kCGNullWindowID)

        let imageOption: CGWindowImageOption = [.boundsIgnoreFraming]

        guard let image = CGWindowListCreateImage(
            captureRectCG, listOption, windowID, imageOption
        ) else { return nil }

        return image
    }

    /// Captures a settled frame: grabs frames until two consecutive TIFF representations
    /// match byte-for-byte. Used for initial capture and manual scroll mode.
    private func captureSettledFrame() async -> CGImage? {
        var previousTIFF: Data? = nil
        var previousCG: CGImage? = nil
        var waitNs: UInt64 = 10_000_000  // 10ms

        for _ in 0..<30 {
            guard let cg = captureFrame() else {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }

            let tiffData: Data? = await withCheckedContinuation { cont in
                captureQueue.async {
                    let bitmapRep = NSBitmapImageRep(cgImage: cg)
                    cont.resume(returning: bitmapRep.tiffRepresentation)
                }
            }
            guard let currentTIFF = tiffData else {
                try? await Task.sleep(nanoseconds: waitNs)
                waitNs = min(waitNs * 3 / 2, 80_000_000)
                continue
            }

            if let prevTIFF = previousTIFF, currentTIFF == prevTIFF {
                lastComparedTIFF = currentTIFF
                return cg
            }

            previousTIFF = currentTIFF
            previousCG = cg
            try? await Task.sleep(nanoseconds: waitNs)
            waitNs = min(waitNs * 3 / 2, 80_000_000)
        }

        return previousCG
    }

    // MARK: - Auto-scroll

    private func startAutoScroll() {
        autoScrollActive = true
        onAutoScrollStarted?()

        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cursorX = captureRect.midX
        let cursorY = primaryScreenH - captureRect.midY
        CGWarpMouseCursorPosition(CGPoint(x: cursorX, y: cursorY))

        activateTargetApp()

        let linesPerTick: Int32
        switch autoScrollSpeed {
        case 1: linesPerTick = 1
        case 2: linesPerTick = 1
        case 4: linesPerTick = 2
        default: linesPerTick = 1
        }

        let burstCount: Int
        switch autoScrollSpeed {
        case 1: burstCount = 1
        case 2: burstCount = 2
        case 4: burstCount = 4
        default: burstCount = 3
        }

        autoScrollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self = self, self.isActive, self.autoScrollActive else { return }
            await self.autoScrollLoop(linesPerTick: linesPerTick, burstCount: burstCount)
        }
    }

    /// Core auto-scroll loop: scroll → captureAndCompare → repeat.
    private func autoScrollLoop(linesPerTick: Int32, burstCount: Int) async {
        while isActive && autoScrollActive {
            postScrollEvents(linesPerTick: linesPerTick, burstCount: burstCount, useShiftFallback: false)

            // captureAndCompare: settle, capture, compare, stitch
            var success = await captureAndCompare()

            // Some apps ignore native horizontal wheel events but accept Shift + vertical wheel.
            if !success && axis == .horizontal && isActive && autoScrollActive {
                postScrollEvents(linesPerTick: linesPerTick, burstCount: burstCount, useShiftFallback: true)
                success = await captureAndCompare()
            }

            if !success {
                matchNotFoundCount += 1
                if matchNotFoundCount >= maxMatchNotFound {
                    stopSession()
                    return
                }
            } else {
                matchNotFoundCount = 0
            }

            // Check max height
            if let merged = mergedImage, maxScrollHeight > 0 {
                let primaryLength = axis == .vertical ? merged.height : merged.width
                if primaryLength >= maxScrollHeight {
                    stopSession()
                    return
                }
            }

            // Small breathing room
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Posts synthetic scroll wheel events for the current capture axis.
    private func postScrollEvents(linesPerTick: Int32, burstCount: Int, useShiftFallback: Bool) {
        // Send a small burst so the target app performs an observable scroll step.
        for _ in 0..<burstCount {
            guard let event = makeScrollEvent(linesPerTick: linesPerTick, useShiftFallback: useShiftFallback) else { continue }
            event.post(tap: .cghidEventTap)
        }
    }

    /// Builds a scroll wheel event that matches the active axis and optional horizontal fallback style.
    private func makeScrollEvent(linesPerTick: Int32, useShiftFallback: Bool) -> CGEvent? {
        // Shift fallback maps horizontal intent onto the common "Shift + vertical wheel" convention.
        if axis == .horizontal && useShiftFallback {
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: -linesPerTick,
                wheel2: 0,
                wheel3: 0
            ) else { return nil }
            event.flags = .maskShift
            return event
        }

        // Native events use wheel1 for vertical movement and wheel2 for horizontal movement.
        let wheel1: Int32 = axis == .vertical ? -linesPerTick : 0
        let wheel2: Int32 = axis == .horizontal ? -linesPerTick : 0
        return CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: wheel1,
            wheel2: wheel2,
            wheel3: 0
        )
    }

    /// The core capture-and-compare cycle.
    /// Waits for pixel-perfect settlement via TIFF comparison, then computes the scroll
    /// offset via Vision and merges new content into the accumulated image.
    /// Returns true if a match was found, false if no shift detected.
    private func captureAndCompare() async -> Bool {
        // Initial delay for scroll animation to begin
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // Wait for settlement: poll frames until two consecutive TIFFs match
        var previousTIFF: Data? = nil
        var settledCG: CGImage? = nil
        var waitNs: UInt64 = 12_000_000

        for _ in 0..<30 {
            guard isActive else { return false }

            guard let cg = captureFrame() else {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }

            let tiffData: Data? = await withCheckedContinuation { cont in
                captureQueue.async {
                    let bitmapRep = NSBitmapImageRep(cgImage: cg)
                    cont.resume(returning: bitmapRep.tiffRepresentation)
                }
            }
            guard let currentTIFF = tiffData else {
                try? await Task.sleep(nanoseconds: waitNs)
                waitNs = min(waitNs * 3 / 2, 80_000_000)
                continue
            }

            if let prevTIFF = previousTIFF, currentTIFF == prevTIFF {
                settledCG = cg
                lastComparedTIFF = currentTIFF
                break
            }

            previousTIFF = currentTIFF
            try? await Task.sleep(nanoseconds: waitNs)
            waitNs = min(waitNs * 3 / 2, 80_000_000)
        }

        guard let currentFrame = settledCG else { return false }
        guard let previousFrame = shotA ?? mergedImage?.cropping(to: CGRect(
            x: 0, y: 0, width: currentFrame.width, height: currentFrame.height
        )) else {
            shotA = currentFrame
            return false
        }

        // Scrollbar detection (once)
        if !rightMarginDetected {
            detectRightMargin(current: currentFrame, previous: previousFrame)
        }

        if axis == .horizontal && frozenDetectionEnabled && !frozenLeadingDetectionDone {
            // Detect fixed leading columns before offset calculation so Excel row headers do not pollute matching.
            detectLeadingFrozenColumn(current: currentFrame, previous: previousFrame, shiftPx: 6)
        }

        // Compute offset via Vision
        guard let offset = visionShift(current: currentFrame, previous: previousFrame) else {
            shotA = currentFrame
            consecutiveZeroShifts += 1
            if hasScrolledOnce && consecutiveZeroShifts >= maxZeroShiftsBeforeStop {
                stopSession()
            }
            return false
        }

        let offsetPx = refinedOffset(
            current: currentFrame,
            previous: previousFrame,
            estimatedOffset: Int(round(offset))
        )
        guard offsetPx > 0 else {
            shotA = currentFrame
            return false
        }

        // Need minimum shift to avoid noise
        let minShift = primaryDimension(of: currentFrame) / 10
        if offsetPx < minShift {
            // Don't update shotA — let shifts accumulate
            return false
        }

        consecutiveZeroShifts = 0
        hasScrolledOnce = true

        // Header detection (first few frames)
        if frozenDetectionEnabled && !headerDetectionDone {
            detectFrozenRegion(current: currentFrame, previous: previousFrame, shiftPx: offsetPx)
        }

        // Vertical still draws the full current frame, so keep a 1px overlap to hide seams.
        // Horizontal appends only the trailing new strip, so use the full measured offset.
        let safeOffset = stitchOffset(from: offsetPx)

        // Incremental stitch: merge new content into mergedImage
        mergeNewContent(currentFrame: currentFrame, offsetPx: safeOffset)

        shotA = currentFrame
        stripCount += 1
        didReportFirstMatch = true

        emitPreview()
        onStripAdded?(stripCount)

        return true
    }

    /// Merges the newly-scrolled content from `currentFrame` into `mergedImage`.
    /// Only the new rows (below the overlap region) are appended.
    private func mergeNewContent(currentFrame: CGImage, offsetPx: Int) {
        guard let existing = mergedImage else {
            mergedImage = currentFrame
            return
        }

        let cs = existing.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        switch axis {
        case .vertical:
            let w = currentFrame.width
            let existingH = existing.height
            let newRows = offsetPx  // pixels of new content
            guard newRows > 0, newRows <= currentFrame.height else { return }

            let totalH = existingH + newRows
            guard let ctx = CGContext(data: nil, width: w, height: totalH,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: cs, bitmapInfo: bitmapInfo) else { return }

            // Draw existing image at the top (CGContext: bottom-left origin, so top = highest y)
            ctx.draw(existing, in: CGRect(x: 0, y: newRows, width: w, height: existingH))

            if headerDetectionDone && headerHeight > 0 {
                // Sticky header detected: only append the bottom newRows pixels.
                let stripY = currentFrame.height - newRows
                if let strip = currentFrame.cropping(to: CGRect(
                    x: 0, y: stripY, width: w, height: newRows)) {
                    ctx.draw(strip, in: CGRect(x: 0, y: 0, width: w, height: newRows))
                }
            } else {
                // No header: draw full current frame with natural overlap.
                ctx.draw(currentFrame, in: CGRect(x: 0, y: 0, width: w, height: currentFrame.height))
            }

            guard let merged = ctx.makeImage() else { return }
            mergedImage = merged
            stitchedImage = merged
            stitchedPixelSize = CGSize(width: CGFloat(w), height: CGFloat(totalH))
        case .horizontal:
            let h = currentFrame.height
            let existingW = existing.width
            let newCols = offsetPx  // pixels of new content
            guard newCols > 0, newCols <= currentFrame.width else { return }

            let totalW = existingW + newCols
            guard let ctx = CGContext(data: nil, width: totalW, height: h,
                                      bitsPerComponent: 8, bytesPerRow: totalW * 4,
                                      space: cs, bitmapInfo: bitmapInfo) else { return }

            // Draw the accumulated image first, then append the current frame on the right.
            // This mirrors the vertical path's "natural overlap" behavior so seam handling
            // stays consistent across both directions.
            ctx.draw(existing, in: CGRect(x: 0, y: 0, width: existingW, height: h))

            // Horizontal capture must append only the newly revealed trailing columns.
            // Drawing the full current frame would duplicate fixed left-side row headers
            // into the middle of Excel-style stitched images.
            let stripX = currentFrame.width - newCols
            if let strip = currentFrame.cropping(to: CGRect(
                x: stripX, y: 0, width: newCols, height: h)) {
                ctx.draw(strip, in: CGRect(x: existingW, y: 0, width: newCols, height: h))
            }

            guard let merged = ctx.makeImage() else { return }
            mergedImage = merged
            stitchedImage = merged
            stitchedPixelSize = CGSize(width: CGFloat(totalW), height: CGFloat(h))
        }
    }

    private func stopAutoScroll() {
        autoScrollActive = false
        autoScrollTask?.cancel(); autoScrollTask = nil
    }

    func toggleAutoScroll() {
        if autoScrollActive {
            stopAutoScroll()
            startManualScrollMonitors()
        } else {
            if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
            if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
            settlementTimer?.invalidate(); settlementTimer = nil
            startAutoScroll()
        }
    }

    // MARK: - Manual scroll

    private func startManualScrollMonitors() {
        scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.onManualScrollEvent()
        }
        scrollMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.onManualScrollEvent()
            return event
        }
    }

    private func onManualScrollEvent() {
        guard isActive else { return }

        // After scrolling stops, do a final settled capture (TIFF comparison)
        settlementTimer?.invalidate()
        settlementTimer = Timer.scheduledTimer(withTimeInterval: settlementInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in await self.settledCapture() }
        }

        // During scrolling, grab and process frames immediately at a fixed interval —
        // no TIFF settlement. This ensures we capture content continuously even with
        // small selection areas where a single scroll gesture can move past the entire
        // viewport.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCaptureTime >= manualCaptureInterval else { return }
        lastCaptureTime = now

        grabAndProcess()
    }

    /// Immediate frame grab + process during active scrolling. No TIFF settlement —
    /// just captures whatever is on screen right now and tries to stitch it.
    private func grabAndProcess() {
        guard isActive, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        guard let currentFrame = captureFrame() else { return }
        guard let previousFrame = shotA else {
            shotA = currentFrame
            return
        }

        if !rightMarginDetected {
            detectRightMargin(current: currentFrame, previous: previousFrame)
        }

        if axis == .horizontal && frozenDetectionEnabled && !frozenLeadingDetectionDone {
            // Detect fixed leading columns before offset calculation so manual scroll uses the moving grid only.
            detectLeadingFrozenColumn(current: currentFrame, previous: previousFrame, shiftPx: 6)
        }

        guard let offset = visionShift(current: currentFrame, previous: previousFrame) else {
            shotA = currentFrame
            return
        }

        let offsetPx = refinedOffset(
            current: currentFrame,
            previous: previousFrame,
            estimatedOffset: Int(round(offset))
        )
        guard offsetPx > 0 else {
            shotA = currentFrame
            return
        }

        let minShift = primaryDimension(of: currentFrame) / 10
        if offsetPx < minShift { return }

        hasScrolledOnce = true
        consecutiveZeroShifts = 0

        if frozenDetectionEnabled && !headerDetectionDone {
            detectFrozenRegion(current: currentFrame, previous: previousFrame, shiftPx: offsetPx)
        }

        let safeOffset = stitchOffset(from: offsetPx)
        mergeNewContent(currentFrame: currentFrame, offsetPx: safeOffset)

        shotA = currentFrame
        stripCount += 1
        didReportFirstMatch = true

        emitPreview()
        onStripAdded?(stripCount)
    }

    /// Converts a measured offset into the amount of content appended to the stitched image.
    private func stitchOffset(from offsetPx: Int) -> Int {
        switch axis {
        case .vertical:
            return max(1, offsetPx - 1)
        case .horizontal:
            return offsetPx
        }
    }

    /// Final settled capture after scrolling stops — uses full TIFF settlement.
    private func settledCapture() async {
        guard isActive, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        let _ = await captureAndCompare()
    }

    // MARK: - Vision shift detection

    /// Vision framework translational image registration.
    /// Crops out frozen header and/or scrollbar for more accurate results.
    private func visionShift(current: CGImage, previous: CGImage) -> CGFloat? {
        var curImg = current
        var prevImg = previous
        let maxCropY = current.height / 5
        let maxCropX = current.width / 3
        let cropY = axis == .vertical && headerDetectionDone ? min(headerHeight, maxCropY) : 0
        let cropX = axis == .horizontal ? min(horizontalMatchingLeftInset(width: current.width), maxCropX) : 0
        let cropW = current.width - cropX - rightMarginPx
        let cropH = current.height - cropY - bottomMarginPx
        if cropX > 0 || cropY > 0 || rightMarginPx > 0 || bottomMarginPx > 0 {
            guard cropH > 20 && cropW > 20 else { return nil }
            let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
            guard let cc = current.cropping(to: cropRect),
                  let pc = previous.cropping(to: cropRect) else { return nil }
            curImg = cc
            prevImg = pc
        }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: prevImg)
        let handler = VNImageRequestHandler(cgImage: curImg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        switch axis {
        case .vertical:
            return obs.alignmentTransform.ty
        case .horizontal:
            return -obs.alignmentTransform.tx
        }
    }

    /// Refines Vision's estimated scroll offset with sampled pixel matching.
    private func refinedOffset(current: CGImage, previous: CGImage, estimatedOffset: Int) -> Int {
        switch axis {
        case .vertical:
            return estimatedOffset
        case .horizontal:
            return refinedHorizontalOffset(
                current: current,
                previous: previous,
                estimatedOffset: estimatedOffset
            )
        }
    }

    /// Searches around the horizontal offset estimate and chooses the lowest-SAD overlap.
    private func refinedHorizontalOffset(current: CGImage, previous: CGImage, estimatedOffset: Int) -> Int {
        guard estimatedOffset > 0 else { return estimatedOffset }
        guard current.width == previous.width, current.height == previous.height else { return estimatedOffset }
        guard let curData = pixelData(for: current),
              let prevData = pixelData(for: previous) else { return estimatedOffset }

        let w = current.width
        let h = current.height
        let bytesPerRow = w * 4
        let searchRadius = max(24, min(120, estimatedOffset / 3))
        let maxOffset = min(w - 8, estimatedOffset + searchRadius)
        let minOffset = max(1, estimatedOffset - searchRadius)
        guard minOffset < maxOffset else { return estimatedOffset }

        var bestOffset = estimatedOffset
        var bestScore = UInt64.max
        let searchStep = 1

        for candidate in stride(from: minOffset, through: maxOffset, by: searchStep) {
            let score = horizontalOverlapScore(
                candidate: candidate,
                width: w,
                height: h,
                bytesPerRow: bytesPerRow,
                currentData: curData,
                previousData: prevData
            )
            if score < bestScore {
                bestScore = score
                bestOffset = candidate
            }
        }

        return bestOffset
    }

    /// Computes normalized SAD for the horizontal overlap implied by a candidate offset.
    private func horizontalOverlapScore(
        candidate: Int,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        currentData: UnsafePointer<UInt8>,
        previousData: UnsafePointer<UInt8>
    ) -> UInt64 {
        let cropLeft = horizontalMatchingLeftInset(width: width)
        let usableWidth = width - candidate - rightMarginPx - cropLeft
        let usableHeight = height - bottomMarginPx
        guard usableWidth > 20, usableHeight > 20 else { return UInt64.max }

        let colStep = max(1, usableWidth / 96)
        let rowStep = max(1, usableHeight / 48)
        var sad: UInt64 = 0
        var samples: UInt64 = 0

        for row in stride(from: 0, to: usableHeight, by: rowStep) {
            let rowOffset = row * bytesPerRow
            for col in stride(from: cropLeft, to: cropLeft + usableWidth, by: colStep) {
                let prevIndex = rowOffset + (col + candidate) * 4
                let curIndex = rowOffset + col * 4
                sad += UInt64(abs(Int(previousData[prevIndex]) - Int(currentData[curIndex]))
                            + abs(Int(previousData[prevIndex + 1]) - Int(currentData[curIndex + 1]))
                            + abs(Int(previousData[prevIndex + 2]) - Int(currentData[curIndex + 2])))
                samples += 1
            }
        }

        guard samples > 0 else { return UInt64.max }
        return sad / samples
    }

    /// Returns the left inset ignored during horizontal matching to avoid fixed row headers.
    private func horizontalMatchingLeftInset(width: Int) -> Int {
        guard axis == .horizontal else { return 0 }

        let defaultInset = min(180, max(80, width / 6))
        let detectedInset = frozenLeadingDetectionDone && frozenLeadingWidth > 0
            ? min(frozenLeadingWidth, width / 3)
            : 0

        // Excel and similar grids often keep row-number/header areas fixed on the left.
        return max(defaultInset, detectedInset)
    }

    /// Extract raw BGRA pixel data from a CGImage.
    private func pixelData(for image: CGImage) -> UnsafePointer<UInt8>? {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data else { return nil }
        return CFDataGetBytePtr(data)
    }

    // MARK: - Scrollbar detection

    private func detectRightMargin(current: CGImage, previous: CGImage) {
        rightMarginDetected = true

        guard current.width == previous.width, current.height == previous.height else { return }
        guard let curData = pixelData(for: current),
              let prevData = pixelData(for: previous) else { return }

        let w = current.width
        let h = current.height
        let bytesPerRow = w * 4

        let rowStart = h * 2 / 10
        let rowEnd = h * 8 / 10
        let rowStep = max(1, (rowEnd - rowStart) / 40)

        var scrollbarWidth = 0
        let maxScanCols = min(50, w / 8)

        for colOffset in 0..<maxScanCols {
            let col = w - 1 - colOffset
            var sad: UInt64 = 0
            var samples: Int = 0

            for row in stride(from: rowStart, to: rowEnd, by: rowStep) {
                let idx = row * bytesPerRow + col * 4
                guard idx + 2 < h * bytesPerRow else { continue }
                sad += UInt64(abs(Int(curData[idx]) - Int(prevData[idx]))
                            + abs(Int(curData[idx + 1]) - Int(prevData[idx + 1]))
                            + abs(Int(curData[idx + 2]) - Int(prevData[idx + 2])))
                samples += 1
            }
            guard samples > 0 else { continue }
            let avgSAD = sad / UInt64(samples)

            if avgSAD > 8 {
                scrollbarWidth = colOffset + 1
            } else if scrollbarWidth > 0 {
                break
            }
        }

        if scrollbarWidth >= 3 && scrollbarWidth <= 40 {
            rightMarginPx = scrollbarWidth + 4
        }

        if axis == .horizontal {
            detectBottomMargin(current: current, previous: previous)
        }
    }

    // MARK: - Frozen region detection

    /// Detects a frozen region on the non-scrolling edge so duplicated sticky UI does not get stitched.
    private func detectFrozenRegion(current: CGImage, previous: CGImage, shiftPx: Int) {
        switch axis {
        case .vertical:
            detectHeader(current: current, previous: previous, shiftPx: shiftPx)
        case .horizontal:
            detectLeadingFrozenColumn(current: current, previous: previous, shiftPx: shiftPx)
        }
    }

    /// Detects a sticky header for vertical scroll capture.
    private func detectHeader(current: CGImage, previous: CGImage, shiftPx: Int) {
        guard current.width == previous.width, current.height == previous.height else { return }
        guard shiftPx > 5 else { return }

        let w = current.width
        let h = current.height

        guard let curData = pixelData(for: current),
              let prevData = pixelData(for: previous) else { return }

        let bytesPerRow = w * 4
        let compareBytes = max(4, (w - rightMarginPx)) * 4
        let colStep = 4

        var frozenRows = 0
        for row in 0..<h {
            var rowSAD: UInt64 = 0
            var samples: Int = 0
            let offset = row * bytesPerRow
            for col in stride(from: 0, to: compareBytes, by: colStep * 4) {
                let cR = Int(curData[offset + col])
                let cG = Int(curData[offset + col + 1])
                let cB = Int(curData[offset + col + 2])
                let pR = Int(prevData[offset + col])
                let pG = Int(prevData[offset + col + 1])
                let pB = Int(prevData[offset + col + 2])
                rowSAD += UInt64(abs(cR - pR) + abs(cG - pG) + abs(cB - pB))
                samples += 1
            }
            let avg = samples > 0 ? rowSAD / UInt64(samples) : 999
            if avg > 8 {
                frozenRows = row
                break
            }
            if row == h - 1 { return }
        }

        if frozenRows >= 10 && frozenRows < (h * 6 / 10) {
            headerDetectionSamples += 1

            if headerDetectionSamples == 1 {
                headerHeight = frozenRows
                frozenTopHeight = CGFloat(headerHeight) / backingScale
                headerDetectionDone = true
            } else {
                if abs(frozenRows - headerHeight) <= 5 {
                    headerHeight = min(headerHeight, frozenRows)
                    frozenTopHeight = CGFloat(headerHeight) / backingScale
                } else {
                    headerHeight = 0
                    frozenTopHeight = 0
                }
                headerDetectionDone = true
            }
        } else if frozenRows < 10 {
            headerDetectionDone = true
        }
    }

    /// Detects a frozen leading column for horizontal scroll capture so fixed sidebars are excluded from stitching.
    private func detectLeadingFrozenColumn(current: CGImage, previous: CGImage, shiftPx: Int) {
        guard current.width == previous.width, current.height == previous.height else { return }
        guard shiftPx > 5 else { return }

        let w = current.width
        let h = current.height

        guard let curData = pixelData(for: current),
              let prevData = pixelData(for: previous) else { return }

        let bytesPerRow = w * 4
        let compareHeight = max(4, h - bottomMarginPx)
        let rowStep = 4

        var frozenCols = 0
        var stableCols = 0
        var movingRun = 0
        for col in 0..<w {
            var colSAD: UInt64 = 0
            var samples: Int = 0
            for row in stride(from: 0, to: compareHeight, by: rowStep) {
                let offset = row * bytesPerRow + col * 4
                let cR = Int(curData[offset])
                let cG = Int(curData[offset + 1])
                let cB = Int(curData[offset + 2])
                let pR = Int(prevData[offset])
                let pG = Int(prevData[offset + 1])
                let pB = Int(prevData[offset + 2])
                colSAD += UInt64(abs(cR - pR) + abs(cG - pG) + abs(cB - pB))
                samples += 1
            }
            let avg = samples > 0 ? colSAD / UInt64(samples) : 999

            // Excel's screen-left edge can contain noisy borders. Treat the
            // fixed region as ending only after several consecutive moving columns.
            if avg <= 8 {
                stableCols += 1
                movingRun = 0
            } else {
                movingRun += 1
            }

            if movingRun >= 4 {
                frozenCols = max(0, col - movingRun + 1)
                break
            }
            if col == w - 1 { return }
        }

        if stableCols >= 4 && frozenCols >= 4 && frozenCols < (w * 6 / 10) {
            frozenLeadingDetectionSamples += 1

            if frozenLeadingDetectionSamples == 1 {
                frozenLeadingWidth = frozenCols
                frozenLeadingDetectionDone = true
            } else {
                if abs(frozenCols - frozenLeadingWidth) <= 5 {
                    frozenLeadingWidth = max(frozenLeadingWidth, frozenCols)
                } else {
                    frozenLeadingWidth = 0
                }
                frozenLeadingDetectionDone = true
            }
        } else if frozenCols < 4 {
            frozenLeadingDetectionDone = true
        }
    }

    /// Detects a horizontal scrollbar on the bottom edge for horizontal scroll capture.
    private func detectBottomMargin(current: CGImage, previous: CGImage) {
        guard current.width == previous.width, current.height == previous.height else { return }
        guard let curData = pixelData(for: current),
              let prevData = pixelData(for: previous) else { return }

        let w = current.width
        let h = current.height
        let bytesPerRow = w * 4

        let colStart = w * 2 / 10
        let colEnd = w * 8 / 10
        let colStep = max(1, (colEnd - colStart) / 40)
        let maxScanRows = min(50, h / 8)

        var scrollbarHeight = 0
        for rowOffset in 0..<maxScanRows {
            let row = h - 1 - rowOffset
            var sad: UInt64 = 0
            var samples: Int = 0

            for col in stride(from: colStart, to: colEnd, by: colStep) {
                let idx = row * bytesPerRow + col * 4
                guard idx + 2 < h * bytesPerRow else { continue }
                sad += UInt64(abs(Int(curData[idx]) - Int(prevData[idx]))
                            + abs(Int(curData[idx + 1]) - Int(prevData[idx + 1]))
                            + abs(Int(curData[idx + 2]) - Int(prevData[idx + 2])))
                samples += 1
            }
            guard samples > 0 else { continue }
            let avgSAD = sad / UInt64(samples)

            if avgSAD > 8 {
                scrollbarHeight = rowOffset + 1
            } else if scrollbarHeight > 0 {
                break
            }
        }

        if scrollbarHeight >= 3 && scrollbarHeight <= 40 {
            bottomMarginPx = scrollbarHeight + 4
        }
    }

    /// Returns the current frame's size on the active scrolling axis.
    private func primaryDimension(of image: CGImage) -> Int {
        switch axis {
        case .vertical:
            return image.height
        case .horizontal:
            return image.width
        }
    }

    // MARK: - Preview

    private func emitPreview() {
        guard let cg = mergedImage, let callback = onPreviewUpdated else { return }
        let ptSize = CGSize(width: CGFloat(cg.width) / backingScale,
                            height: CGFloat(cg.height) / backingScale)
        callback(NSImage(cgImage: cg, size: ptSize))
    }
}
