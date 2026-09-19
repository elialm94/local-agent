import AppKit
import ApplicationServices
import Foundation
import PairCore
import ScreenCaptureKit

/// Native perception: frontmost app/window, pointer, Accessibility element under
/// the pointer (with DOM attributes when the app is a browser), browser URL, and
/// on-demand ScreenCaptureKit crops. Everything stays local.
///
/// Coordinate convention: `WorldState` uses top-left-origin global points, the
/// same as the Accessibility and Quartz (CGEvent) APIs. AppKit is bottom-left;
/// `flipY` converts at the UI boundary.
///
/// Everything here runs on a background queue, so only thread-safe APIs are
/// used (AX, CoreGraphics, NSRunningApplication) — no NSWorkspace/NSScreen/NSEvent.
final class MacPerceptionProvider: PerceptionProvider, @unchecked Sendable {
    let name = "macos"

    private let lock = NSLock()
    private var world = WorldState()
    private let queue = DispatchQueue(label: "pair.perception", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let systemWide = AXUIElementCreateSystemWide()
    private var lastWindowKey = ""
    private var lastPointer = Point.zero
    private var lastElementProbeAt = Date.distantPast

    /// Poll interval while idle vs while the hotkey is held.
    var idleInterval: TimeInterval = 0.5
    var activeInterval: TimeInterval = 0.1
    var hotkeyHeld = false {
        didSet {
            lock.lock(); world.isHotkeyHeld = hotkeyHeld; lock.unlock()
            if hotkeyHeld != oldValue { reschedule() }
        }
    }

    // MARK: Permissions

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }
    static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    // MARK: PerceptionProvider

    func start() {
        reschedule()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func reschedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = hotkeyHeld ? activeInterval : idleInterval
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func snapshot() -> WorldState {
        lock.lock(); defer { lock.unlock() }
        return world
    }

    func target(at point: Point) -> AttentionTarget? {
        element(at: point).map { describe($0, source: .accessibilityHover) }
    }

    func capture(rect: Rect) async -> VisualCrop? {
        guard Self.screenRecordingGranted else { return nil }
        LatencyTracer.shared.begin(.screenCapture)
        defer { LatencyTracer.shared.end(.screenCapture) }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            // Pick the display that contains the rect's centre.
            let center = CGPoint(x: rect.center.x, y: rect.center.y)
            guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            let scale: CGFloat = {
                guard let mode = CGDisplayCopyDisplayMode(display.displayID), display.width > 0 else { return 2 }
                return CGFloat(mode.pixelWidth) / CGFloat(display.width)
            }()
            let local = CGRect(x: rect.x - display.frame.origin.x, y: rect.y - display.frame.origin.y, width: rect.width, height: rect.height)
                .intersection(CGRect(origin: .zero, size: display.frame.size))
            guard !local.isNull, local.width > 2, local.height > 2 else { return nil }
            cfg.sourceRect = local
            cfg.width = Int(local.width * scale)
            cfg.height = Int(local.height * scale)
            cfg.showsCursor = false
            cfg.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
            return VisualCrop(png: png, bounds: Rect(x: local.origin.x + display.frame.origin.x, y: local.origin.y + display.frame.origin.y, width: local.width, height: local.height))
        } catch {
            Log.warn("perception", "capture failed", ["error": error.localizedDescription])
            return nil
        }
    }

    // MARK: Temporal context (fed by the event tap)

    func noteClick(at point: Point) {
        queue.async {
            let t = self.element(at: point).map { self.describe($0, source: .accessibilityHover) }
            self.lock.lock()
            self.world.appendInteraction(InteractionEvent(kind: .click, position: point, target: t))
            self.lock.unlock()
        }
    }

    func setSelectedRegion(_ rect: Rect?) {
        lock.lock(); world.selectedRegion = rect; lock.unlock()
    }

    // MARK: Polling

    private func tick() {
        guard Self.accessibilityTrusted else { return }
        let pointer = Self.currentPointer()
        var appInfo: ApplicationInfo?
        var windowInfo: WindowInfo?
        var url: String?
        if let axApp = elementAttribute(systemWide, kAXFocusedApplicationAttribute) {
            var pid: pid_t = 0
            _ = AXUIElementGetPid(axApp, &pid)
            let running = NSRunningApplication(processIdentifier: pid)
            appInfo = ApplicationInfo(name: running?.localizedName ?? "?", bundleID: running?.bundleIdentifier, pid: pid)
            if let win = elementAttribute(axApp, kAXFocusedWindowAttribute) {
                windowInfo = WindowInfo(title: attribute(win, kAXTitleAttribute) as String?, bounds: bounds(of: win) ?? .zero)
                url = attribute(win, "AXDocument") as String?
            }
        }

        // Only re-probe the element under the pointer when it moved (or periodically while active).
        let moved = abs(pointer.x - lastPointer.x) > 1 || abs(pointer.y - lastPointer.y) > 1
        let stale = Date().timeIntervalSince(lastElementProbeAt) > (hotkeyHeld ? 0.25 : 1.0)
        var hovered: AttentionTarget?
        var probed = false
        if moved || stale {
            probed = true
            lastElementProbeAt = Date()
            if let el = element(at: pointer) {
                var t = describe(el, source: .accessibilityHover)
                t.application = appInfo?.name ?? t.application
                t.applicationBundleID = appInfo?.bundleID
                t.window = windowInfo?.title
                hovered = t
                if url == nil { url = webURL(from: el) }
            }
        }
        lastPointer = pointer

        let windowKey = "\(appInfo?.bundleID ?? "")|\(windowInfo?.title ?? "")"
        let windowChanged = windowKey != lastWindowKey
        lastWindowKey = windowKey

        lock.lock()
        world.updatedAt = Date()
        world.activeApplication = appInfo
        world.activeWindow = windowInfo
        world.cursorPosition = pointer
        if probed { world.hoveredElement = hovered }
        if let url { world.currentURL = url; world.currentLocalhostPort = ProjectDetection.localhostPort(in: url) }
        else if windowChanged { world.currentURL = nil; world.currentLocalhostPort = nil }
        if windowChanged {
            world.appendInteraction(InteractionEvent(kind: .windowChange, position: pointer, note: windowKey))
        }
        lock.unlock()
    }

    // MARK: Accessibility helpers

    /// Quartz event location is already top-left global, no conversion needed.
    static func currentPointer() -> Point {
        let loc = CGEvent(source: nil)?.location ?? .zero
        return Point(x: loc.x, y: loc.y)
    }

    /// Convert between AppKit (bottom-left) and Accessibility/Quartz (top-left)
    /// global coordinates using the main display's height (thread-safe).
    static var mainDisplayHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    static func flipY(_ p: CGPoint) -> Point {
        Point(x: p.x, y: mainDisplayHeight - p.y)
    }

    static func flipY(_ p: Point) -> CGPoint {
        CGPoint(x: p.x, y: mainDisplayHeight - p.y)
    }

    private func element(at point: Point) -> AXUIElement? {
        var el: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &el)
        return err == .success ? el : nil
    }

    private func rawAttribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// Bridged attribute read (CFString -> String, CFBoolean/CFNumber -> NSNumber, CFArray -> [String], CFURL -> URL).
    private func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        rawAttribute(el, name) as? T
    }

    /// AXUIElement is an unbridged CF type; `as?` cannot check it, so verify the type ID by hand.
    private func elementAttribute(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = rawAttribute(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXUIElement.self)
    }

    private func axValue(_ el: AXUIElement, _ name: String) -> AXValue? {
        guard let v = rawAttribute(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXValue.self)
    }

    private func bounds(of el: AXUIElement) -> Rect? {
        guard let p = axValue(el, kAXPositionAttribute), let s = axValue(el, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return Rect(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    private func describe(_ el: AXUIElement, source: TargetSource) -> AttentionTarget {
        let role: String = attribute(el, kAXRoleAttribute) ?? "AXUnknown"
        let subrole: String? = attribute(el, kAXSubroleAttribute)
        let title: String? = attribute(el, kAXTitleAttribute)
        let desc: String? = attribute(el, kAXDescriptionAttribute)
        let valueAny: CFTypeRef? = attribute(el, kAXValueAttribute)
        let value: String? = (valueAny as? String) ?? (valueAny as? NSNumber).map { $0.stringValue }
        let identifier: String? = attribute(el, kAXIdentifierAttribute)
        let domID: String? = attribute(el, "AXDOMIdentifier")
        let domClasses: [String] = (attribute(el, "AXDOMClassList") as [String]?) ?? []
        let enabled: Bool? = (attribute(el, kAXEnabledAttribute) as NSNumber?)?.boolValue
        let focused: Bool? = (attribute(el, kAXFocusedAttribute) as NSNumber?)?.boolValue

        // Short ancestor path for context ("AXGroup form > AXWebArea > AXWindow").
        var path: [String] = []
        var cursor: AXUIElement? = elementAttribute(el, kAXParentAttribute)
        var depth = 0
        while let c = cursor, depth < 6 {
            let r: String = attribute(c, kAXRoleAttribute) ?? "?"
            let t: String? = attribute(c, kAXTitleAttribute)
            let d: String? = attribute(c, kAXDescriptionAttribute)
            let label = [t, d].compactMap { $0 }.first { !$0.isEmpty }
            path.append(label.map { "\(r) \($0.prefix(30))" } ?? r)
            if r == "AXWindow" { break }
            cursor = elementAttribute(c, kAXParentAttribute)
            depth += 1
        }

        let label = [title, desc, value].compactMap { $0 }.first { !$0.isEmpty && $0.count <= 80 } ?? (domID ?? "")
        let ax = AccessibilityData(role: role, subrole: subrole, title: title, descriptionText: desc, value: value.map { String($0.prefix(120)) },
                                   identifier: identifier, domIdentifier: domID, domClassList: domClasses, ancestorPath: path,
                                   isEnabled: enabled, isFocused: focused)
        var target = AttentionTarget(role: role, label: label, bounds: bounds(of: el) ?? .zero, application: "", confidence: 0.6,
                                     source: source, accessibility: ax)
        // The optional browser dev runtime mirrors file:line onto the hovered element's class list.
        target.sourceReference = DevBridgeSourceResolver.decode(classList: domClasses)
        return target
    }

    /// Walk up to the web area and read its URL (Chrome/Safari/Arc expose AXURL there).
    private func webURL(from el: AXUIElement) -> String? {
        var cursor: AXUIElement? = el
        var depth = 0
        while let c = cursor, depth < 40 {
            let role: String = attribute(c, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" {
                if let u = attribute(c, "AXURL") as URL? { return u.absoluteString }
                if let s = attribute(c, "AXURL") as String? { return s }
                return nil
            }
            cursor = elementAttribute(c, kAXParentAttribute)
            depth += 1
        }
        return nil
    }
}
