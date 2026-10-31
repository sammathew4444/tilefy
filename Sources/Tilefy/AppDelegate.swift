import AppKit
import ApplicationServices
import os
import SwiftUI
import TilefyCore

private let log = Logger(subsystem: "app.tilefy", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var manager: WindowCoordinator!
    private var system: AccessibilitySystem!
    private var scrollTap: ModifierScrollTap?
    private var swipeTap: TrackpadSwipeTap?
    private var settingsModel: SettingsModel?
    private let hotkeys = HotkeyCenter()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var permissionWindow: NSWindow?
    private var permissionTimer: Timer?
    private var signalSource: DispatchSourceSignal?
    private var failedShortcuts: [String] = []
    private var configError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            log.info("Tilefy is already running")
            NSApp.terminate(nil)
            return
        }

        let config: Config
        do {
            config = try Config.load()
        } catch {
            configError = "Using defaults: couldn't read config.json (\(error.localizedDescription))"
            log.error("Couldn't read config: \(error.localizedDescription, privacy: .public)")
            config = Config()
        }
        let onlyApp = CommandLine.arguments.first { $0.hasPrefix("--only-app=") }.map { String($0.dropFirst(11)) }
        system = AccessibilitySystem(onlyApp: onlyApp)
        manager = WindowCoordinator(config: config, system: system)
        system.coordinator = manager
        listenForCommands()
        manager.onStateChange = { [weak self] in self?.updateStatusItem() }

        setUpStatusItem()
        handleTerminationSignals()

        if AXIsProcessTrusted() {
            beginTiling()
        } else {
            requestPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.stop()
    }

    /// `kill` and logging out should also bring parked windows back, the same as quitting from the menu.
    private func handleTerminationSignals() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSource = source
    }

    private func listenForCommands() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: CommandLineInterface.dispatchName, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let command = note.object as? String else { return }
            if command == CommandLineInterface.togglePause {
                self.togglePause()
            } else if command == CommandLineInterface.reloadConfig {
                self.reloadConfig()
            } else if command.hasPrefix(CommandLineInterface.settingsPrefix) {
                self.showSettings(tab: String(command.dropFirst(CommandLineInterface.settingsPrefix.count + 1)))
            } else {
                self.manager.run(command)
            }
        }
        center.addObserver(
            forName: CommandLineInterface.statusRequestName, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let data = try? JSONEncoder().encode(self.manager.status()) else { return }
            center.postNotificationName(
                CommandLineInterface.statusReplyName,
                object: String(data: data, encoding: .utf8),
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }

    private func beginTiling() {
        permissionWindow?.close()
        permissionWindow = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
        registerHotkeys()
        manager.start()
        updateScrollTap()
        updateSwipeTap()
        updateStatusItem()
    }

    private func updateScrollTap() {
        scrollTap?.invalidate()
        scrollTap = nil
        guard manager.config.modifierScroll, manager.isStarted else { return }
        scrollTap = ModifierScrollTap(modifier: manager.config.modifier) { [weak self] dx, dy in
            self?.manager.scrolled(dx: dx, dy: dy)
        }
    }

    private func updateSwipeTap() {
        guard manager.config.trackpadSwipes, manager.isStarted else {
            swipeTap?.invalidate()
            swipeTap = nil
            return
        }
        guard swipeTap == nil else { return }
        swipeTap = TrackpadSwipeTap { [weak self] touches in
            self?.manager.trackpadTouches(touches)
        }
    }

    private func registerHotkeys() {
        let bindings: [(combo: String, action: () -> Void)] = manager.config.effectiveBindings.map { combo, command in
            (combo: combo, action: { [weak self] in self?.manager.run(command) })
        }
        failedShortcuts = hotkeys.register(bindings)
        if !failedShortcuts.isEmpty {
            log.error("Unavailable shortcuts: \(self.failedShortcuts.joined(separator: ", "), privacy: .public)")
        }
        settingsModel?.unavailableCombos = Set(failedShortcuts)
    }

    // MARK: - Permission

    private func requestPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        // Adds Tilefy to the list in System Settings and shows the system's prompt.
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)

        let view = PermissionView {
            let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        }
        let window = makeWindow(rootView: view, title: "Welcome to Tilefy", style: [.titled, .closable])
        permissionWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            if AXIsProcessTrusted() { self?.beginTiling() }
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol = manager.isPaused ? "pause.rectangle" : (manager.engine.activeWorkspace?.layout.symbolName ?? "rectangle.split.2x2")
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tilefy")
        button.imagePosition = .imageLeading
        button.title = manager.engine.activeWorkspace.map { " \($0.id)" } ?? ""
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let engine = manager.engine
        let current = engine.activeWorkspace

        if !manager.isStarted {
            menu.addItem(disabled("Waiting for Accessibility access…"))
        } else if let current {
            menu.addItem(disabled("Workspace \(current.id): \(current.layout.title)"))
        }
        if let configError { menu.addItem(disabled(configError)) }
        if !failedShortcuts.isEmpty {
            let list = failedShortcuts.sorted().map(Hotkey.displayString).joined(separator: "  ")
            menu.addItem(disabled("Taken by another app: \(list)"))
        }
        menu.addItem(.separator())

        let layouts = NSMenu()
        for kind in LayoutKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(runCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "layout-\(kind.rawValue)"
            item.state = current?.layout == kind ? .on : .off
            item.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)
            layouts.addItem(item)
        }
        menu.addItem(submenu("Layout", layouts))

        let workspaces = NSMenu()
        let occupied = Set(engine.occupiedWorkspaces)
        for id in 1...9 {
            let suffix = occupied.contains(id) ? "  ●" : ""
            let item = NSMenuItem(title: "Workspace \(id)\(suffix)", action: #selector(runCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "workspace-\(id)"
            item.state = current?.id == id ? .on : .off
            workspaces.addItem(item)
        }
        menu.addItem(submenu("Workspace", workspaces))

        menu.addItem(.separator())
        menu.addItem(action("Snap Windows Back", #selector(runCommand(_:)), object: "retile"))
        menu.addItem(action(manager.isPaused ? "Resume Tiling" : "Pause Tiling", #selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(action("Reload Config File", #selector(reloadConfig)))
        menu.addItem(action("Quit Tilefy", #selector(NSApplication.terminate(_:)), target: NSApp, key: "q"))

        if !manager.isStarted {
            for item in menu.items where item.action == #selector(runCommand(_:)) || item.action == #selector(togglePause) {
                item.isEnabled = false
            }
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        item.isEnabled = manager.isStarted
        return item
    }

    private func action(_ title: String, _ selector: Selector, object: Any? = nil, target: AnyObject? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target ?? self
        item.representedObject = object
        return item
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        manager.run(command)
    }

    @objc private func togglePause() {
        manager.setPaused(!manager.isPaused)
    }

    @objc private func reloadConfig() {
        do {
            let config = try Config.load()
            configError = nil
            applyConfig(config, save: false)
            settingsWindow?.close()
            settingsWindow = nil
            settingsModel = nil
        } catch {
            configError = "Kept current settings: couldn't read config.json (\(error.localizedDescription))"
            log.error("Couldn't read config: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyConfig(_ config: Config, save: Bool) {
        let shortcutsChanged = config.effectiveBindings != manager.config.effectiveBindings
        let scrollChanged = config.modifier != manager.config.modifier || config.modifierScroll != manager.config.modifierScroll
        if save {
            do {
                try config.save()
            } catch {
                configError = "Couldn't save settings: \(error.localizedDescription)"
                log.error("Couldn't save config: \(error.localizedDescription, privacy: .public)")
            }
        }
        manager.update(config: config)
        if shortcutsChanged, manager.isStarted, settingsModel?.recording == nil { registerHotkeys() }
        if scrollChanged { updateScrollTap() }
        updateSwipeTap()
    }

    @objc private func openSettings() {
        showSettings(tab: "general")
    }

    private func makeWindow<Content: View>(rootView: Content, title: String, style: NSWindow.StyleMask) -> NSWindow {
        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = style
        window.isReleasedWhenClosed = false
        // SwiftUI sizes the view later. Without this, center() works from a zero-sized window and
        // the real window ends up off-center, possibly past the edge of the screen.
        window.setContentSize(controller.view.fittingSize)
        window.center()
        return window
    }

    private func showSettings(tab: String) {
        if settingsWindow == nil || !tab.isEmpty {
            settingsWindow?.close()
            let model = SettingsModel(
                config: manager.config,
                onChange: { [weak self] config in self?.applyConfig(config, save: true) },
                onRecordingChanged: { [weak self] recording in
                    guard let self, self.manager.isStarted else { return }
                    if recording {
                        self.hotkeys.unregisterAll()
                    } else {
                        self.registerHotkeys()
                    }
                }
            )
            model.unavailableCombos = Set(failedShortcuts)
            settingsModel = model
            let root = SettingsView(model: model, initialTab: tab.isEmpty ? "general" : tab)
            settingsWindow = makeWindow(rootView: root, title: "Tilefy Settings", style: [.titled, .closable, .miniaturizable])
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
