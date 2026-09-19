import AppKit
import Carbon.HIToolbox
import Foundation
import PairCore

/// Global interaction via a CGEvent tap:
///
///   hold Option+Space          → talk (hotkeyDown / hotkeyUp)
///   Option+Space + click       → explicit element reference
///   Option+Space + drag        → explicit region reference
///   Escape (while active)      → cancel
///
/// Space key events are swallowed while Option is held so the focused app does
/// not receive them. Ordinary clicks (hotkey not held) are observed only, to
/// feed temporal context. Requires the Accessibility permission.
final class GlobalHotkey {
    struct Config {
        var keyCode: Int64 = Int64(kVK_Space)
        var modifiers: CGEventFlags = .maskAlternate
        /// Minimum drag distance (points) before a press+move counts as a region.
        var dragThreshold: Double = 6
    }

    var config = Config()
    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?
    var onExplicitClick: ((Point) -> Void)?
    var onExplicitRegion: ((Rect) -> Void)?
    var onRegionPreview: ((Rect?) -> Void)?
    var onCancel: (() -> Void)?
    var onObservedClick: ((Point) -> Void)?

    private(set) var isHeld = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dragOrigin: Point?
    private var dragging = false

    var isInstalled: Bool { tap != nil }

    func install() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userInfo).takeUnretainedValue()
            return hotkey.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.error("hotkey", "event tap creation failed (Accessibility permission missing?)")
            return false
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Log.info("hotkey", "event tap installed")
        return true
    }

    func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .keyDown, .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let hasModifier = event.flags.contains(config.modifiers)
            if keyCode == config.keyCode && (hasModifier || isHeld) {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if type == .keyDown, !isHeld, !isRepeat {
                    isHeld = true
                    DispatchQueue.main.async { self.onHotkeyDown?() }
                } else if type == .keyUp, isHeld {
                    release()
                }
                return nil // swallow
            }
            if keyCode == Int64(kVK_Escape), type == .keyDown, isHeld || onCancelIsRelevant {
                let swallow = isHeld
                isHeld = false; dragOrigin = nil; dragging = false
                DispatchQueue.main.async { self.onRegionPreview?(nil); self.onCancel?() }
                return swallow ? nil : Unmanaged.passUnretained(event)
            }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            // Releasing Option while Space is still down ends the turn too.
            if isHeld, !event.flags.contains(config.modifiers) {
                release()
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown:
            let p = point(of: event)
            if isHeld {
                dragOrigin = p
                dragging = false
                return nil
            }
            DispatchQueue.main.async { self.onObservedClick?(p) }
            return Unmanaged.passUnretained(event)

        case .leftMouseDragged:
            guard isHeld, let origin = dragOrigin else { return Unmanaged.passUnretained(event) }
            let p = point(of: event)
            if !dragging, hypot(p.x - origin.x, p.y - origin.y) >= config.dragThreshold { dragging = true }
            if dragging {
                let r = Self.rect(origin, p)
                DispatchQueue.main.async { self.onRegionPreview?(r) }
            }
            return nil

        case .leftMouseUp:
            guard isHeld, let origin = dragOrigin else { return Unmanaged.passUnretained(event) }
            let p = point(of: event)
            dragOrigin = nil
            if dragging {
                dragging = false
                let r = Self.rect(origin, p)
                DispatchQueue.main.async { self.onRegionPreview?(nil); self.onExplicitRegion?(r) }
            } else {
                DispatchQueue.main.async { self.onExplicitClick?(p) }
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Escape is only intercepted while the assistant is doing something.
    var onCancelIsRelevant: Bool { cancelRelevance?() ?? false }
    var cancelRelevance: (() -> Bool)?

    private func release() {
        isHeld = false
        dragOrigin = nil
        if dragging { dragging = false; DispatchQueue.main.async { self.onRegionPreview?(nil) } }
        DispatchQueue.main.async { self.onHotkeyUp?() }
    }

    /// CGEvent locations are already top-left global coordinates.
    private func point(of event: CGEvent) -> Point {
        Point(x: event.location.x, y: event.location.y)
    }

    private static func rect(_ a: Point, _ b: Point) -> Rect {
        Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
