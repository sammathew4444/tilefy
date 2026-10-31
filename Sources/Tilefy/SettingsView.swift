import ServiceManagement
import SwiftUI
import TilefyCore

final class SettingsModel: ObservableObject {
    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            onChange(config)
        }
    }
    /// The command waiting for a new key press, if any.
    @Published private(set) var recording: String?
    @Published var recorderMessage: String?
    /// Shortcuts macOS refused, usually because another app already holds them.
    @Published var unavailableCombos: Set<String> = []

    let onChange: (Config) -> Void
    /// Shortcuts must be off while recording, otherwise pressing one would run it.
    let onRecordingChanged: (Bool) -> Void
    private var keyMonitor: Any?

    init(config: Config, onChange: @escaping (Config) -> Void, onRecordingChanged: @escaping (Bool) -> Void) {
        self.config = config
        self.onChange = onChange
        self.onRecordingChanged = onRecordingChanged
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func startRecording(_ command: String) {
        stopRecording()
        recording = command
        recorderMessage = "Press the new shortcut, or Esc to cancel."
        onRecordingChanged(true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if recording != nil { onRecordingChanged(false) }
        recording = nil
    }

    private func handle(_ event: NSEvent) {
        guard let command = recording else { return }
        if event.keyCode == 53 {  // Esc
            recorderMessage = nil
            stopRecording()
            return
        }
        let flags = event.modifierFlags
        guard let combo = Hotkey.combo(
            keyCode: Int(event.keyCode),
            ctrl: flags.contains(.control),
            alt: flags.contains(.option),
            shift: flags.contains(.shift),
            cmd: flags.contains(.command)
        ) else {
            recorderMessage = "That key can't be used. Try another."
            return
        }
        guard Hotkey.isAllowedAsGlobalShortcut(combo) else {
            recorderMessage = "A shortcut needs ⌃ or ⌘. macOS doesn't allow global shortcuts with only ⌥ or ⇧."
            return
        }
        let replaced = config.command(boundTo: combo).flatMap { $0 == command ? nil : $0 }
        config.rebind(command, to: combo)
        recorderMessage = replaced.map {
            "\(Hotkey.displayString(combo)) was used by \"\(ShortcutCatalog.label(for: $0) ?? $0)\", which now has no shortcut."
        }
        stopRecording()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var tab: String

    init(model: SettingsModel, initialTab: String = "general") {
        self.model = model
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab(model: model).tag("general").tabItem { Label("General", systemImage: "gearshape") }
            LayoutsTab(model: model).tag("layouts").tabItem { Label("Layouts", systemImage: "rectangle.split.2x2") }
            ShortcutsTab(model: model).tag("shortcuts").tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AppsTab(model: model).tag("apps").tabItem { Label("Apps", systemImage: "macwindow.on.rectangle") }
        }
        .padding(16)
        .frame(width: 580, height: 640)
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private let modifiers = [
        ("ctrl+alt", "⌃⌥  Control + Option"),
        ("ctrl+cmd", "⌃⌘  Control + Command"),
        ("cmd+alt", "⌘⌥  Command + Option"),
    ]

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                }
            if let loginError {
                Text(loginError).font(.caption).foregroundColor(.red)
            }

            Picker("Shortcut modifier", selection: $model.config.modifier) {
                ForEach(modifiers, id: \.0) { Text($0.1).tag($0.0) }
            }

            Toggle("Outline the focused window", isOn: $model.config.focusBorder)
            Toggle("Show workspace and layout when they change", isOn: $model.config.showHUD)
            Toggle("Animate windows moving", isOn: $model.config.animations)
            Toggle("Scroll with the modifier held to switch workspace or focus", isOn: $model.config.modifierScroll)
            Toggle("Swipe on the trackpad to move along the row or between workspaces", isOn: $model.config.trackpadSwipes)
            if model.config.trackpadSwipes {
                Picker("Swipe with", selection: $model.config.swipeFingers) {
                    Text("Three fingers").tag(3)
                    Text("Four fingers").tag(4)
                }
                if macOSUsesSwipe(fingers: model.config.swipeFingers) {
                    Text("macOS also uses this swipe to switch between Spaces. You can turn that off in System Settings › Trackpad › More Gestures.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Spacing") {
                Stepper(value: $model.config.innerGap, in: 0...64, step: 2) {
                    Text("Between windows: \(Int(model.config.innerGap)) pt")
                }
                Stepper(value: $model.config.outerGap, in: 0...64, step: 2) {
                    Text("Screen edge: \(Int(model.config.outerGap)) pt")
                }
            }

            Section("Keep this space clear") {
                Stepper(value: $model.config.reserved.top, in: 0...400, step: 4) {
                    Text("Top: \(Int(model.config.reserved.top)) pt")
                }
                Stepper(value: $model.config.reserved.bottom, in: 0...400, step: 4) {
                    Text("Bottom: \(Int(model.config.reserved.bottom)) pt")
                }
                Stepper(value: $model.config.reserved.left, in: 0...400, step: 4) {
                    Text("Left: \(Int(model.config.reserved.left)) pt")
                }
                Stepper(value: $model.config.reserved.right, in: 0...400, step: 4) {
                    Text("Right: \(Int(model.config.reserved.right)) pt")
                }
            }
        }
    }
}

/// Whether macOS's own "swipe between full-screen apps" gesture is set to this number of fingers.
private func macOSUsesSwipe(fingers: Int) -> Bool {
    let key = fingers == 3 ? "TrackpadThreeFingerHorizSwipeGesture" : "TrackpadFourFingerHorizSwipeGesture"
    return UserDefaults(suiteName: "com.apple.AppleMultitouchTrackpad")?.integer(forKey: key) == 2
}

private struct LayoutsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New workspaces start with the selected layout. Each workspace keeps its own, and you can change it at any time.")
                .font(.callout)
                .foregroundColor(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(LayoutKind.allCases, id: \.self) { kind in
                    Button {
                        model.config.defaultLayout = kind
                    } label: {
                        LayoutCard(kind: kind, isSelected: model.config.defaultLayout == kind)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct LayoutCard: View {
    let kind: LayoutKind
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LayoutPreview(kind: kind).frame(height: 62)
            Text(kind.title).font(.headline)
            Text(kind.summary)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
    }
}

/// A miniature drawn by the real layout engine, so that it can't disagree with what the layout does.
private struct LayoutPreview: View {
    let kind: LayoutKind

    var body: some View {
        GeometryReader { proxy in
            let frames = Self.frames(kind: kind, size: proxy.size)
            ZStack(alignment: .topLeading) {
                ForEach(frames.keys.sorted(), id: \.self) { id in
                    let frame = frames[id]!
                    RoundedRectangle(cornerRadius: 3)
                        .fill(id == 1 ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.35))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
    }

    private static func frames(kind: LayoutKind, size: CGSize) -> [WindowID: CGRect] {
        guard size.width > 0, size.height > 0 else { return [:] }
        let engine = TilingEngine(options: TilingOptions(innerGap: 3, outerGap: 0, defaultLayout: kind))
        let area = CGRect(origin: .zero, size: size)
        engine.setMonitors([Monitor(id: 1, frame: area, visibleFrame: area)])
        let count: WindowID = kind == .monocle ? 1 : (kind == .scrolling ? 3 : 4)
        for id in 1...count { engine.addWindow(id) }
        engine.focusChanged(to: 1)
        return engine.plan().frames
    }
}

private struct ShortcutsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(ShortcutCatalog.groups) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            ShortcutRow(item: item, model: model)
                        }
                    }
                }
            }
            if let message = model.recorderMessage {
                Text(message).font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Button("Restore All Defaults") {
                    model.stopRecording()
                    model.recorderMessage = nil
                    model.config.bindings = [:]
                }
                Spacer()
                Button("Open Config File") {
                    if !FileManager.default.fileExists(atPath: Config.fileURL.path) {
                        try? model.config.save()
                    }
                    NSWorkspace.shared.open(Config.fileURL)
                }
            }
        }
        .onDisappear { model.stopRecording() }
    }
}

private struct ShortcutRow: View {
    let item: ShortcutCatalog.Item
    @ObservedObject var model: SettingsModel

    private var combo: String? { model.config.combo(for: item.command) }
    private var isRecording: Bool { model.recording == item.command }
    private var isUnavailable: Bool { combo.map(model.unavailableCombos.contains) ?? false }

    var body: some View {
        HStack {
            Text(item.label)
            Spacer()
            if isUnavailable {
                Text("Taken by another app").font(.caption).foregroundColor(.orange)
            }
            Button(isRecording ? "Press keys…" : (combo.map(Hotkey.displayString) ?? "Set…")) {
                if isRecording {
                    model.stopRecording()
                } else {
                    model.startRecording(item.command)
                }
            }
            .font(.system(.body, design: .monospaced))
            .contextMenu {
                Button("Reset to Default") { model.config.resetBinding(item.command) }
                Button("Remove Shortcut") { model.config.unbind(item.command) }
            }
        }
    }
}

private struct AppsTab: View {
    @ObservedObject var model: SettingsModel
    @State private var selection: String?

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .filter { !model.config.floatApps.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Windows from these apps always float instead of being tiled. It applies to windows opened from now on.")
                .font(.callout)
                .foregroundColor(.secondary)

            List(model.config.floatApps, id: \.self, selection: $selection) { bundleID in
                Text(bundleID)
            }

            HStack {
                Menu("Add Running App") {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier!) {
                            model.config.floatApps.append(app.bundleIdentifier!)
                        }
                    }
                }
                .fixedSize()
                Button("Remove") {
                    model.config.floatApps.removeAll { $0 == selection }
                    selection = nil
                }
                .disabled(selection == nil)
            }
        }
    }
}

struct PermissionView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Tilefy needs Accessibility access", systemImage: "hand.raised.fill")
                .font(.title2.weight(.semibold))
            Text("Accessibility is how an app moves and resizes other apps' windows. Tilefy doesn't read window contents or record what you type.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Open Accessibility settings.")
                Text("2. Turn on Tilefy.")
                Text("3. Come back. Tilefy starts tiling by itself.")
            }
            .foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Open Accessibility Settings", action: onOpenSettings)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
