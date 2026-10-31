import Carbon.HIToolbox
import Foundation

/// A parsed key combination such as "ctrl+alt+shift+left".
public struct Hotkey: Equatable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32

    private static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "return": kVK_Return, "space": kVK_Space, "tab": kVK_Tab, "escape": kVK_Escape, "delete": kVK_Delete,
        "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period,
        "slash": kVK_ANSI_Slash, "semicolon": kVK_ANSI_Semicolon, "quote": kVK_ANSI_Quote,
        "grave": kVK_ANSI_Grave, "backslash": kVK_ANSI_Backslash,
        "leftbracket": kVK_ANSI_LeftBracket, "rightbracket": kVK_ANSI_RightBracket,
    ]

    private static let modifierBits: [String: Int] = [
        "cmd": cmdKey, "alt": optionKey, "ctrl": controlKey, "shift": shiftKey,
    ]

    public init?(_ combo: String) {
        var modifiers = 0
        var key: Int?
        for part in combo.lowercased().split(separator: "+").map(String.init) {
            if let bit = Self.modifierBits[part] {
                modifiers |= bit
            } else if key == nil, let code = Self.keyCodes[part] {
                key = code
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        keyCode = UInt32(key)
        carbonModifiers = UInt32(modifiers)
    }

    /// "ctrl+alt+shift+left" becomes "⌃⌥⇧←".
    public static func displayString(_ combo: String) -> String {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        let symbols: [(String, String)] = [("ctrl", "⌃"), ("alt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
        let modifiers = symbols.filter { parts.contains($0.0) }.map(\.1).joined()
        let names: [String: String] = [
            "left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "tab": "⇥", "space": "Space",
            "escape": "⎋", "delete": "⌫", "minus": "-", "equal": "=", "comma": ",", "period": ".", "slash": "/",
            "semicolon": ";", "quote": "'", "grave": "`", "backslash": "\\", "leftbracket": "[", "rightbracket": "]",
        ]
        let key = parts.first { part in !symbols.contains { $0.0 == part } } ?? ""
        return modifiers + (names[key] ?? key.uppercased())
    }

    /// Rewrites a combo with modifiers in a fixed order, so equal combos compare equal.
    public static func canonical(_ combo: String) -> String {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        let order = ["ctrl", "alt", "shift", "cmd"]
        let modifiers = order.filter { parts.contains($0) }
        let keys = parts.filter { !order.contains($0) }
        return (modifiers + keys).joined(separator: "+")
    }

    /// Builds a combo from a key press, for the shortcut recorder. Nil for keys Tilefy can't bind.
    public static func combo(keyCode: Int, ctrl: Bool, alt: Bool, shift: Bool, cmd: Bool) -> String? {
        guard let name = keyCodes.first(where: { $0.value == keyCode })?.key else { return nil }
        var parts: [String] = []
        if ctrl { parts.append("ctrl") }
        if alt { parts.append("alt") }
        if shift { parts.append("shift") }
        if cmd { parts.append("cmd") }
        return (parts + [name]).joined(separator: "+")
    }

    /// macOS 15 and later refuse global shortcuts that use only Option or Option+Shift, and a
    /// shortcut needs a real modifier so it doesn't swallow ordinary typing.
    public static func isAllowedAsGlobalShortcut(_ combo: String) -> Bool {
        let parts = Set(canonical(combo).split(separator: "+").map(String.init))
        return parts.contains("ctrl") || parts.contains("cmd")
    }
}
