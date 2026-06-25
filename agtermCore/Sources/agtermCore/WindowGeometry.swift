import Foundation

/// Pure geometry clamps for the `window.resize`/`window.move` control commands. Host-free —
/// `WindowRegistry` (the only place with the live `NSWindow` and its `NSScreen`) supplies the
/// actual display bounds and window min/size, this just does the arithmetic so it can be unit-tested.
///
/// Uses plain `Double`-backed `Size`/`Point`/`Rect` rather than `CGSize`/`CGPoint`/`CGRect` on purpose:
/// `agtermCore` is Foundation-only, and a CoreGraphics member reference (e.g. `CGSize.width`) in a
/// Foundation-only module serializes as an unresolvable cross-reference that crashes the release
/// whole-module-optimizer's SIL deserializer (Xcode 26.5). The app target converts to/from CG at the
/// `WindowRegistry` call site, where CoreGraphics is in scope.
public enum WindowGeometry {
    /// A width/height pair in points.
    public struct Size: Equatable, Sendable {
        public var width: Double
        public var height: Double
        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// An x/y point in points.
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// An origin + size rectangle in points.
    public struct Rect: Equatable, Sendable {
        public var origin: Point
        public var size: Size
        public init(origin: Point, size: Size) {
            self.origin = origin
            self.size = size
        }
    }

    /// Minimum visible strip (points) kept on the target display when clamping an origin, so a window
    /// pushed off-screen still exposes enough of itself to grab and drag back.
    public static let visibleMargin: Double = 80

    /// Clamps each dimension of `requested` into `[min, max]`: an oversized request shrinks to `max`,
    /// an undersized one grows to `min`, an in-range one is returned unchanged.
    public static func clampSize(_ requested: Size, min: Size, max: Size) -> Size {
        Size(width: clamp(requested.width, min.width, max.width),
             height: clamp(requested.height, min.height, max.height))
    }

    /// Clamps a window's origin so the window rect (`[origin, origin + windowSize]`) stays at least
    /// `visibleMargin` points overlapping `displayFrame` in each axis — a window dragged off-screen
    /// keeps a grabbable strip visible. Coordinate-system agnostic: `requested`, `windowSize`, and
    /// `displayFrame` must share one space (the caller works in AppKit y-up screen coords).
    ///
    /// The rule per axis (x shown; y identical): origin.x is clamped to
    /// `[displayFrame.minX + visibleMargin - windowSize.width, displayFrame.maxX - visibleMargin]`,
    /// so the window's right edge can't fall left of `minX + margin` and its left edge can't fall
    /// right of `maxX - margin`. An already-on-screen origin is returned unchanged.
    public static func clampOrigin(_ requested: Point, windowSize: Size, displayFrame: Rect) -> Point {
        let displayMinX = displayFrame.origin.x
        let displayMaxX = displayFrame.origin.x + displayFrame.size.width
        let displayMinY = displayFrame.origin.y
        let displayMaxY = displayFrame.origin.y + displayFrame.size.height
        let minX = displayMinX + visibleMargin - windowSize.width
        let maxX = displayMaxX - visibleMargin
        let minY = displayMinY + visibleMargin - windowSize.height
        let maxY = displayMaxY - visibleMargin
        return Point(x: clamp(requested.x, minX, maxX), y: clamp(requested.y, minY, maxY))
    }

    /// Clamps `value` into `[lo, hi]`. If `lo > hi` (a degenerate range) the upper bound wins.
    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        Swift.min(Swift.max(value, lo), hi)
    }
}
