import AppKit
import Carbon.HIToolbox
import Foundation
import PairCore

/// Global interaction via a CGEvent tap:
///
///   Option+Space               → toggle a hands-free voice session
///   Escape (while the session or a reply is active) → leave the session
///
/// The shortcut press is swallowed so the focused app does not receive that
/// Space. Mouse events are never swallowed: while the session is open the user
/// navigates normally, and the element under the pointer is read by perception.
/// Requires the Accessibility permission.
final class GlobalHotkey {
    struct Config {
        var keyCode: Int64 = Int64(kVK_Space)
        var modifiers: CGEventFlags = .maskAlternate
        /// Minimum drag distance (points) before a press+move counts as a region.
        var dragThreshold: Double = 6
    }

    var config = Config()
    /// `true` when the voice session should open, `false` when it should close.
    var onVoiceSession: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onObservedClick: ((Point) -> Void)?

    /// Voice session latched on. Read from the event-tap thread.
    private(set) var sessionOpen = false
    /// Swallow the Space key-up that belongs to the shortcut press.
    private var swallowSpaceUp = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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
            if keyCode == config.keyCode && type == .keyUp && swallowSpaceUp {
                swallowSpaceUp = false
                return nil
            }
            if keyCode == config.keyCode && hasModifier && type == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat {
                    sessionOpen.toggle()
                    swallowSpaceUp = true
                    let open = sessionOpen
                    DispatchQueue.main.async { self.onVoiceSession?(open) }
                }
                return nil
            }
            if keyCode == Int64(kVK_Escape), type == .keyDown, sessionOpen || onCancelIsRelevant {
                let swallow = sessionOpen
                sessionOpen = false
                DispatchQueue.main.async { self.onCancel?() }
                return swallow ? nil : Unmanaged.passUnretained(event)
            }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            return Unmanaged.passUnretained(event)

        case .leftMouseDown:
            let p = point(of: event)
            DispatchQueue.main.async { self.onObservedClick?(p) }
            return Unmanaged.passUnretained(event)

        case .leftMouseDragged, .leftMouseUp:
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Escape is only intercepted while the assistant is doing something.
    var onCancelIsRelevant: Bool { cancelRelevance?() ?? false }
    var cancelRelevance: (() -> Bool)?

    /// CGEvent locations are already top-left global coordinates.
    private func point(of event: CGEvent) -> Point {
        Point(x: event.location.x, y: event.location.y)
    }
}
