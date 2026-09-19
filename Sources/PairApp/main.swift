import AppKit
import Combine
import PairCore
import SwiftUI

/// Menu-bar application. No dock icon, no main window: the orb and the
/// target highlight are the UI; a debug panel and settings are one click away.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var orb: OrbPanel!
    private var highlight: HighlightWindow!
    private var debugWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.shared.minimumLevel = .debug

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Pair")
        statusItem.menu = buildMenu()

        orb = OrbPanel(model: model)
        highlight = HighlightWindow(model: model)

        model.$state.receive(on: RunLoop.main).sink { [weak self] s in self?.updateStatusIcon(s) }.store(in: &cancellables)
        model.$project.receive(on: RunLoop.main).sink { [weak self] _ in self?.statusItem.menu = self?.buildMenu() }.store(in: &cancellables)
        model.$running.receive(on: RunLoop.main).sink { [weak self] _ in self?.statusItem.menu = self?.buildMenu() }.store(in: &cancellables)

        if !model.permissions.allGranted {
            model.requestPermissions()
            showSettings()
        }
        model.start()
        if model.project == nil, model.explicitProjectPath == nil {
            model.notices.append("Select a project from the menu bar so edits and undo know where to work.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: model.running ? "Pair is on — hold ⌥ Space to talk" : "Pair is off", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let p = model.project {
            let item = NSMenuItem(title: "Project: \(p.name)\(p.isTrusted ? "" : " (unsure)")", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(withTitle: model.running ? "Turn Off" : "Turn On", action: #selector(toggleRunning), keyEquivalent: "")
        menu.addItem(withTitle: model.state == .muted ? "Unmute" : "Mute", action: #selector(toggleMute), keyEquivalent: "m")
        menu.addItem(.separator())

        let projectMenu = NSMenu()
        projectMenu.addItem(withTitle: "Choose Folder…", action: #selector(chooseProject), keyEquivalent: "o")
        if !model.projectDetector.recentPaths.isEmpty {
            projectMenu.addItem(.separator())
            for path in model.projectDetector.recentPaths {
                let item = NSMenuItem(title: (path as NSString).lastPathComponent, action: #selector(selectRecentProject(_:)), keyEquivalent: "")
                item.representedObject = path
                item.state = path == model.explicitProjectPath ? .on : .off
                item.toolTip = path
                projectMenu.addItem(item)
            }
            projectMenu.addItem(.separator())
            projectMenu.addItem(withTitle: "Detect Automatically", action: #selector(clearProject), keyEquivalent: "")
        }
        let projectItem = NSMenuItem(title: "Project", action: nil, keyEquivalent: "")
        projectItem.submenu = projectMenu
        menu.addItem(projectItem)

        menu.addItem(withTitle: "Show Panel", action: #selector(showDebug), keyEquivalent: "d")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Pair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != nil && item.target == nil { item.target = self }
        for item in projectMenu.items where item.action != nil { item.target = self }
        return menu
    }

    private func updateStatusIcon(_ s: AssistantState) {
        let name: String
        switch s {
        case .idle: name = "waveform.circle"
        case .muted: name = "mic.slash.circle"
        case .listening, .targeting: name = "waveform.circle.fill"
        case .thinking, .speaking: name = "bubble.left.circle.fill"
        case .executing: name = "hammer.circle.fill"
        case .success: name = "checkmark.circle.fill"
        case .error: name = "exclamationmark.circle.fill"
        }
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Pair: \(s.rawValue)")
        statusItem.menu = buildMenu()
    }

    // MARK: Actions

    @objc private func toggleRunning() {
        if model.running { model.stop() } else { model.start() }
    }

    @objc private func toggleMute() { model.toggleMute() }

    @objc private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Project"
        panel.message = "Choose the local code project the assistant should edit. It should be a git repository so changes can be undone."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            model.selectProject(path: url.path)
        }
    }

    @objc private func selectRecentProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        model.selectProject(path: path)
    }

    @objc private func clearProject() { model.selectProject(path: nil) }

    @objc private func showDebug() {
        if debugWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Pair"
            w.contentView = NSHostingView(rootView: DebugPanelView(model: model))
            w.isReleasedWhenClosed = false
            w.center()
            debugWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        debugWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Pair Settings"
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
