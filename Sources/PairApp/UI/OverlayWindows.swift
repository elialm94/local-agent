import AppKit
import Combine
import PairCore
import SwiftUI

/// Non-activating floating panel that hosts the orb near the bottom-right of
/// the main screen. Visible only while the assistant is active.
@MainActor
final class OrbPanel: NSPanel {
    private var cancellables = Set<AnyCancellable>()
    private var hideWork: DispatchWorkItem?

    init(model: AppModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel, .hudWindow], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        let host = NSHostingView(rootView: OrbView(model: model).frame(maxWidth: 320, alignment: .trailing).padding(6))
        host.translatesAutoresizingMaskIntoConstraints = false
        contentView = host
        reposition()

        model.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] s in self?.stateChanged(s) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)
    }

    private func stateChanged(_ s: AssistantState) {
        hideWork?.cancel()
        switch s {
        case .idle:
            let w = DispatchWorkItem { [weak self] in self?.fadeOut() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
        case .success, .error:
            show()
            let w = DispatchWorkItem { [weak self] in self?.fadeOut() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
        case .muted:
            show()
            let w = DispatchWorkItem { [weak self] in self?.fadeOut() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
        default:
            show()
        }
    }

    func show() {
        reposition()
        alphaValue = 1
        if !isVisible { orderFrontRegardless() }
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.orderOut(nil)
        })
    }

    func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        let size = contentView?.fittingSize ?? NSSize(width: 320, height: 60)
        setContentSize(size)
        setFrameOrigin(NSPoint(x: f.maxX - size.width - 16, y: f.minY + 16))
    }
}

/// Transparent full-screen window that outlines the current target (or the
/// region being dragged) so the user can verify what the assistant means.
@MainActor
final class HighlightWindow: NSWindow {
    private var cancellables = Set<AnyCancellable>()
    private let shape = CAShapeLayer()
    private let label = CATextLayer()
    private var fadeWork: DispatchWorkItem?

    init(model: AppModel) {
        let frame = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = NSView(frame: frame)
        v.wantsLayer = true
        contentView = v
        shape.fillColor = NSColor.systemBlue.withAlphaComponent(0.08).cgColor
        shape.strokeColor = NSColor.systemBlue.cgColor
        shape.lineWidth = 2
        shape.lineDashPattern = nil
        v.layer?.addSublayer(shape)
        label.fontSize = 11
        label.foregroundColor = NSColor.white.cgColor
        label.backgroundColor = NSColor.systemBlue.cgColor
        label.cornerRadius = 4
        label.alignmentMode = .center
        label.contentsScale = NSScreen.screens.first?.backingScaleFactor ?? 2
        v.layer?.addSublayer(label)
        alphaValue = 0

        model.$target.combineLatest(model.$targetIsExplicit, model.$state, model.$regionPreview)
            .receive(on: RunLoop.main)
            .sink { [weak self] target, explicit, state, preview in
                self?.update(target: target, explicit: explicit, state: state, preview: preview)
            }
            .store(in: &cancellables)
    }

    private func update(target: AttentionTarget?, explicit: Bool, state: AssistantState, preview: Rect?) {
        fadeWork?.cancel()
        if let r = preview {
            draw(rect: r, text: "region", color: .systemCyan, dashed: true)
            alphaValue = 1
            orderFrontRegardless()
            return
        }
        let active = state == .listening || state == .targeting || state == .thinking || state == .speaking
        guard let t = target, !t.bounds.isEmpty, active else {
            scheduleFade(after: 0.3)
            return
        }
        let text = (t.label.isEmpty ? t.role : t.label) + (explicit ? "" : "  \(Int((t.confidence * 100).rounded()))%")
        draw(rect: t.bounds, text: text, color: explicit ? .systemBlue : .systemTeal, dashed: !explicit)
        alphaValue = 1
        orderFrontRegardless()
        // Hover targets fade quickly so the screen never feels cluttered; explicit ones linger.
        scheduleFade(after: explicit ? 3.0 : 1.4)
    }

    private func draw(rect r: Rect, text: String, color: NSColor, dashed: Bool) {
        // Rect is top-left global; the window's view is bottom-left within the primary screen.
        let screenH = NSScreen.screens.first?.frame.height ?? frame.height
        let cg = CGRect(x: r.x - frame.minX, y: screenH - r.y - r.height - frame.minY, width: r.width, height: r.height).insetBy(dx: -3, dy: -3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = CGPath(roundedRect: cg, cornerWidth: 6, cornerHeight: 6, transform: nil)
        shape.strokeColor = color.cgColor
        shape.fillColor = color.withAlphaComponent(0.08).cgColor
        shape.lineDashPattern = dashed ? [6, 4] : nil
        label.string = " \(text) "
        label.backgroundColor = color.cgColor
        let w = min(320, CGFloat(text.count) * 7 + 12)
        label.frame = CGRect(x: cg.minX, y: cg.maxY + 4, width: w, height: 16)
        CATransaction.commit()
    }

    private func scheduleFade(after: TimeInterval) {
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.alphaValue == 0 { self?.orderOut(nil) }
            })
        }
        fadeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }
}
