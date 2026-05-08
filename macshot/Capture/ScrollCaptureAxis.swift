import Foundation

/// Scroll capture primary axis.
///
/// Determines how the scroll capture engine interprets image translation,
/// appends newly revealed content, and sends synthetic scroll events.
enum ScrollCaptureAxis: String {
    /// Traditional top-to-bottom scrolling.
    case vertical
    /// Left-to-right or right-to-left scrolling within a horizontal canvas.
    case horizontal

    /// Direction marker used in menus and HUD text without requiring per-locale
    /// translation for newly-added axis labels.
    var localizedTitle: String {
        switch self {
        case .vertical:
            return "↕︎ \(L("Scroll Capture"))"
        case .horizontal:
            return "↔︎ \(L("Scroll Capture"))"
        }
    }

    /// Compact marker for the live HUD so the current scroll axis stays visible.
    var indicatorSymbol: String {
        switch self {
        case .vertical:
            return "↕︎"
        case .horizontal:
            return "↔︎"
        }
    }
}
