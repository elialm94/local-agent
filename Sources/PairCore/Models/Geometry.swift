import Foundation

/// Platform-independent point in global screen coordinates (top-left origin,
/// matching the macOS Accessibility and Quartz coordinate systems).
public struct Point: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)

    public func distance(to other: Point) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Platform-independent rectangle in global screen coordinates (top-left origin).
public struct Rect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var area: Double { max(0, width) * max(0, height) }
    public var center: Point { Point(x: x + width / 2, y: y + height / 2) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func contains(_ p: Point) -> Bool {
        p.x >= x && p.x <= x + width && p.y >= y && p.y <= y + height
    }

    public func intersection(_ other: Rect) -> Rect {
        let nx = max(x, other.x)
        let ny = max(y, other.y)
        let nr = min(x + width, other.x + other.width)
        let nb = min(y + height, other.y + other.height)
        if nr <= nx || nb <= ny { return .zero }
        return Rect(x: nx, y: ny, width: nr - nx, height: nb - ny)
    }

    /// Fraction (0...1) of `self` covered by `other`.
    public func overlapFraction(with other: Rect) -> Double {
        guard area > 0 else { return 0 }
        return intersection(other).area / area
    }

    public func insetBy(_ d: Double) -> Rect {
        Rect(x: x + d, y: y + d, width: width - 2 * d, height: height - 2 * d)
    }
}
