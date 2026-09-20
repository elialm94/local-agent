import Foundation

/// A scriptable perception source for tests and the CLI harness. Holds a
/// `WorldState` that callers mutate directly.
public final class SyntheticPerceptionProvider: PerceptionProvider, @unchecked Sendable {
    public let name = "synthetic"
    private let lock = NSLock()
    private var world: WorldState
    public var captureHandler: (@Sendable (Rect) -> VisualCrop?)?

    public init(world: WorldState = WorldState()) {
        self.world = world
    }

    public func start() {}
    public func stop() {}

    public func snapshot() -> WorldState {
        lock.lock(); defer { lock.unlock() }
        return world
    }

    public func update(_ mutate: (inout WorldState) -> Void) {
        lock.lock(); defer { lock.unlock() }
        mutate(&world)
        world.updatedAt = Date()
    }

    public func target(at point: Point) -> AttentionTarget? {
        lock.lock(); defer { lock.unlock() }
        if let h = world.hoveredElement, h.bounds.contains(point) { return h }
        if let s = world.selectedElement, s.bounds.contains(point) { return s }
        return world.hoveredElement
    }

    public func capture(rect: Rect) async -> VisualCrop? {
        captureHandler?(rect)
    }

    /// Convenience: a button-like target for demos.
    public static func demoTarget(label: String = "Send Offer", role: String = "AXButton", app: String = "Google Chrome", bounds: Rect = Rect(x: 640, y: 420, width: 160, height: 44), source: TargetSource = .synthetic, domID: String? = nil, classes: [String] = []) -> AttentionTarget {
        AttentionTarget(
            role: role,
            label: label,
            bounds: bounds,
            application: app,
            applicationBundleID: "com.google.Chrome",
            window: "localhost:5173 — \(label)",
            confidence: 0.8,
            source: source,
            accessibility: AccessibilityData(role: role, title: label, domIdentifier: domID, domClassList: classes, ancestorPath: ["AXGroup form", "AXWebArea", "AXWindow"])
        )
    }
}
