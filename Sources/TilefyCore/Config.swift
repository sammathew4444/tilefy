import Foundation

/// User settings, stored as JSON at ~/.config/tilefy/config.json. The Settings window edits this
/// same file, so either can be used.
public struct Config: Codable, Equatable {
    /// The held-down modifier that stands in for Omarchy's Super key.
    public var modifier: String = "ctrl+alt"
    public var defaultLayout: LayoutKind = .dwindle
    public var innerGap: Double = 8
    public var outerGap: Double = 8
    /// Space kept clear at each screen edge, for widget bars and the like.
    public var reserved: Insets = Insets()
    /// Starting width of a scrolling column, as a fraction of the screen.
    public var scrollingDefaultWidth: Double = 0.5
    public var focusBorder: Bool = true
    public var focusBorderWidth: Double = 2
    /// Fixed corner radius for the outline. Normally unset, so that it matches each window's own.
    public var focusBorderRadius: Double?
    /// Bundle IDs of apps whose windows always float.
    public var floatApps: [String] = ["com.apple.systempreferences", "com.apple.calculator"]
    /// Overrides on top of the default bindings, e.g. {"mod+y": "layout-grid", "mod+w": "none"}.
    public var bindings: [String: String] = [:]
    /// Bundle IDs of apps whose new windows open on a given workspace.
    public var appWorkspaces: [String: Int] = [:]
    /// Briefly shows the workspace and layout on screen when they change.
    public var showHUD: Bool = true
    /// Holding the shortcut modifier while scrolling switches workspace (vertical) or focus (horizontal).
    public var modifierScroll: Bool = true
    /// Slides windows to their new places, instead of jumping.
    public var animations: Bool = true
    public var animationDuration: Double = 0.16
    /// Swiping left and right on a trackpad moves along the row, or between workspaces.
    public var trackpadSwipes: Bool = true
    /// How many fingers a swipe uses: 3 or 4.
    public var swipeFingers: Int = 4

    public init() {}

    /// Missing keys fall back to defaults, so a hand-edited file can list only what it changes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        modifier = try c.decodeIfPresent(String.self, forKey: .modifier) ?? d.modifier
        defaultLayout = try c.decodeIfPresent(LayoutKind.self, forKey: .defaultLayout) ?? d.defaultLayout
        innerGap = try c.decodeIfPresent(Double.self, forKey: .innerGap) ?? d.innerGap
        outerGap = try c.decodeIfPresent(Double.self, forKey: .outerGap) ?? d.outerGap
        reserved = try c.decodeIfPresent(Insets.self, forKey: .reserved) ?? d.reserved
        scrollingDefaultWidth = try c.decodeIfPresent(Double.self, forKey: .scrollingDefaultWidth) ?? d.scrollingDefaultWidth
        focusBorder = try c.decodeIfPresent(Bool.self, forKey: .focusBorder) ?? d.focusBorder
        focusBorderWidth = try c.decodeIfPresent(Double.self, forKey: .focusBorderWidth) ?? d.focusBorderWidth
        focusBorderRadius = try c.decodeIfPresent(Double.self, forKey: .focusBorderRadius)
        floatApps = try c.decodeIfPresent([String].self, forKey: .floatApps) ?? d.floatApps
        bindings = try c.decodeIfPresent([String: String].self, forKey: .bindings) ?? d.bindings
        appWorkspaces = try c.decodeIfPresent([String: Int].self, forKey: .appWorkspaces) ?? d.appWorkspaces
        showHUD = try c.decodeIfPresent(Bool.self, forKey: .showHUD) ?? d.showHUD
        modifierScroll = try c.decodeIfPresent(Bool.self, forKey: .modifierScroll) ?? d.modifierScroll
        animations = try c.decodeIfPresent(Bool.self, forKey: .animations) ?? d.animations
        animationDuration = try c.decodeIfPresent(Double.self, forKey: .animationDuration) ?? d.animationDuration
        trackpadSwipes = try c.decodeIfPresent(Bool.self, forKey: .trackpadSwipes) ?? d.trackpadSwipes
        swipeFingers = try c.decodeIfPresent(Int.self, forKey: .swipeFingers) ?? d.swipeFingers
    }

    /// `TILEFY_CONFIG` points at a different file, which the real-window tests use.
    public static let fileURL: URL = {
        if let path = ProcessInfo.processInfo.environment["TILEFY_CONFIG"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tilefy/config.json")
    }()

    /// Returns the defaults if there is no file yet. Throws if the file exists but is invalid, so
    /// a typo can be reported instead of silently replacing the user's settings.
    public static func load() throws -> Config {
        guard let data = try? Data(contentsOf: fileURL) else { return Config() }
        return try JSONDecoder().decode(Config.self, from: data)
    }

    public func save() throws {
        try FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
    }

    public var tilingOptions: TilingOptions {
        TilingOptions(
            innerGap: innerGap,
            outerGap: outerGap,
            reserved: reserved,
            defaultLayout: defaultLayout,
            scrollingDefaultWidth: scrollingDefaultWidth
        )
    }

    /// Default bindings. They follow Omarchy where a key is shared, with `mod` in place of Super.
    /// `extra` is the one modifier that isn't part of `mod`, which is Omarchy's third modifier.
    public static let defaultBindings: [String: String] = {
        var b: [String: String] = [
            "mod+left": "focus-left", "mod+right": "focus-right", "mod+up": "focus-up", "mod+down": "focus-down",
            "mod+shift+left": "swap-left", "mod+shift+right": "swap-right",
            "mod+shift+up": "swap-up", "mod+shift+down": "swap-down",

            "mod+w": "close",
            "mod+t": "toggle-float",
            "mod+j": "toggle-split",
            "mod+f": "fullscreen",
            "mod+extra+f": "full-width",
            "mod+l": "layout-toggle",
            "mod+shift+l": "layout-next",

            "mod+equal": "grow-width", "mod+minus": "shrink-width",
            "mod+shift+equal": "grow-height", "mod+shift+minus": "shrink-height",
            "mod+0": "balance",

            "mod+tab": "workspace-next", "mod+shift+tab": "workspace-previous", "mod+extra+tab": "workspace-last",
            "mod+n": "focus-next", "mod+shift+n": "focus-previous",
            "mod+period": "focus-monitor-next", "mod+shift+period": "move-to-monitor-next",

            "mod+d": "layout-dwindle", "mod+s": "layout-scrolling", "mod+m": "layout-master",
            "mod+x": "layout-centeredMaster", "mod+g": "layout-grid", "mod+o": "layout-monocle",

            "mod+return": "promote",
            "mod+r": "cycle-width", "mod+c": "center", "mod+comma": "stack", "mod+shift+comma": "unstack",
            "mod+e": "retile",
            "mod+a": "toggle-scratchpad", "mod+shift+a": "move-to-scratchpad",
            "mod+shift+g": "toggle-group", "mod+extra+g": "remove-from-group",
            "mod+grave": "group-next", "mod+shift+grave": "group-previous",
            "mod+extra+left": "move-into-group-left", "mod+extra+right": "move-into-group-right",
            "mod+extra+up": "move-into-group-up", "mod+extra+down": "move-into-group-down",
            "mod+p": "toggle-sticky",
            "mod+extra+period": "move-workspace-to-monitor-next",
        ]
        for n in 1...9 {
            b["mod+\(n)"] = "workspace-\(n)"
            b["mod+shift+\(n)"] = "move-to-workspace-\(n)"
            b["mod+extra+\(n)"] = "send-to-workspace-\(n)"
        }
        return b
    }()

    /// Every active shortcut in canonical form, mapped to its command. User bindings win over
    /// defaults, and "none" removes a default.
    public var effectiveBindings: [String: String] {
        var result = defaultsResolved
        for (combo, command) in bindings {
            let key = Hotkey.canonical(resolved(combo))
            result[key] = command == "none" ? nil : command
        }
        return result
    }

    private var defaultsResolved: [String: String] {
        var result: [String: String] = [:]
        for (combo, command) in Self.defaultBindings {
            result[Hotkey.canonical(resolved(combo))] = command
        }
        return result
    }

    private var extraModifier: String {
        let parts = Set(modifier.split(separator: "+").map(String.init))
        return ["cmd", "alt", "ctrl"].first { !parts.contains($0) } ?? "shift"
    }

    private func resolved(_ combo: String) -> String {
        combo.split(separator: "+").map { part -> String in
            switch part {
            case "mod": return modifier
            case "extra": return extraModifier
            default: return String(part)
            }
        }.joined(separator: "+")
    }

    /// The combo bound to a command, for showing in menus and Settings.
    public func combo(for command: String) -> String? {
        effectiveBindings
            .filter { $0.value == command }
            .keys
            .sorted { ($0.count, $0) < ($1.count, $1) }
            .first
    }

    public func command(boundTo combo: String) -> String? {
        effectiveBindings[Hotkey.canonical(combo)]
    }

    /// Points a command at a new combo, replacing its old combos and anything else using the new one.
    public mutating func rebind(_ command: String, to combo: String) {
        unbind(command)
        bindings[Hotkey.canonical(combo)] = command
    }

    public mutating func unbind(_ command: String) {
        let defaults = defaultsResolved
        for (combo, bound) in effectiveBindings where bound == command {
            let key = bindings.keys.first { Hotkey.canonical(resolved($0)) == combo }
            if let key { bindings[key] = nil }
            if defaults[combo] != nil { bindings[combo] = "none" }
        }
    }

    /// Returns a command to its default shortcut.
    public mutating func resetBinding(_ command: String) {
        unbind(command)
        let defaults = defaultsResolved
        for (combo, bound) in defaults where bound == command {
            let key = bindings.keys.first { Hotkey.canonical(resolved($0)) == combo }
            if let key { bindings[key] = nil }
        }
    }
}

/// How shortcuts are grouped and named in Settings.
public enum ShortcutCatalog {
    public struct Item: Identifiable {
        public let label: String
        public let command: String
        public var id: String { command }
    }

    public struct Group: Identifiable {
        public let title: String
        public let items: [Item]
        public var id: String { title }
    }

    public static func label(for command: String) -> String? {
        groups.flatMap(\.items).first { $0.command == command }?.label
    }

    public static let groups: [Group] = [
        Group(title: "Windows", items: [
            Item(label: "Focus left", command: "focus-left"),
            Item(label: "Focus right", command: "focus-right"),
            Item(label: "Focus up", command: "focus-up"),
            Item(label: "Focus down", command: "focus-down"),
            Item(label: "Swap left", command: "swap-left"),
            Item(label: "Swap right", command: "swap-right"),
            Item(label: "Swap up", command: "swap-up"),
            Item(label: "Swap down", command: "swap-down"),
            Item(label: "Next window", command: "focus-next"),
            Item(label: "Previous window", command: "focus-previous"),
            Item(label: "Close", command: "close"),
            Item(label: "Float / tile", command: "toggle-float"),
            Item(label: "Fullscreen", command: "fullscreen"),
            Item(label: "Full width", command: "full-width"),
            Item(label: "Grow width", command: "grow-width"),
            Item(label: "Shrink width", command: "shrink-width"),
            Item(label: "Grow height", command: "grow-height"),
            Item(label: "Shrink height", command: "shrink-height"),
            Item(label: "Reset sizes", command: "balance"),
            Item(label: "Snap back into place", command: "retile"),
            Item(label: "Show / hide scratchpad", command: "toggle-scratchpad"),
            Item(label: "Move window to scratchpad", command: "move-to-scratchpad"),
            Item(label: "Sticky: keep on every workspace", command: "toggle-sticky"),
        ]),
        Group(title: "Layouts", items: [
            Item(label: "Toggle dwindle / scrolling", command: "layout-toggle"),
            Item(label: "Next layout", command: "layout-next"),
            Item(label: "Dwindle", command: "layout-dwindle"),
            Item(label: "Scrolling", command: "layout-scrolling"),
            Item(label: "Master & Stack", command: "layout-master"),
            Item(label: "Centered Master", command: "layout-centeredMaster"),
            Item(label: "Grid", command: "layout-grid"),
            Item(label: "Monocle", command: "layout-monocle"),
            Item(label: "Dwindle: flip split", command: "toggle-split"),
            Item(label: "Master: promote window", command: "promote"),
            Item(label: "Scrolling: cycle width", command: "cycle-width"),
            Item(label: "Scrolling: center column", command: "center"),
            Item(label: "Scrolling: stack into left column", command: "stack"),
            Item(label: "Scrolling: unstack", command: "unstack"),
        ]),
        Group(title: "Window Groups", items: [
            Item(label: "Make group / break up group", command: "toggle-group"),
            Item(label: "Take window out of group", command: "remove-from-group"),
            Item(label: "Next window in group", command: "group-next"),
            Item(label: "Previous window in group", command: "group-previous"),
            Item(label: "Move into group on the left", command: "move-into-group-left"),
            Item(label: "Move into group on the right", command: "move-into-group-right"),
            Item(label: "Move into group above", command: "move-into-group-up"),
            Item(label: "Move into group below", command: "move-into-group-down"),
        ]),
        Group(title: "Workspaces", items: (1...9).map {
            Item(label: "Go to workspace \($0)", command: "workspace-\($0)")
        } + [
            Item(label: "Next workspace", command: "workspace-next"),
            Item(label: "Previous workspace", command: "workspace-previous"),
            Item(label: "Last workspace", command: "workspace-last"),
        ] + (1...9).map {
            Item(label: "Move window to workspace \($0)", command: "move-to-workspace-\($0)")
        } + (1...9).map {
            Item(label: "Send window to workspace \($0)", command: "send-to-workspace-\($0)")
        }),
        Group(title: "Displays", items: [
            Item(label: "Focus next display", command: "focus-monitor-next"),
            Item(label: "Move window to next display", command: "move-to-monitor-next"),
            Item(label: "Move workspace to next display", command: "move-workspace-to-monitor-next"),
        ]),
    ]
}
