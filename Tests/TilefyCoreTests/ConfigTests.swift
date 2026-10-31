import Foundation
import XCTest
@testable import TilefyCore

final class ConfigTests: XCTestCase {
    func testMissingKeysFallBackToDefaults() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"innerGap": 20}"#.utf8))
        XCTAssertEqual(config.innerGap, 20)
        XCTAssertEqual(config.outerGap, Config().outerGap)
        XCTAssertEqual(config.modifier, "ctrl+alt")
    }

    func testRoundTrip() throws {
        var config = Config()
        config.defaultLayout = .grid
        config.reserved = Insets(top: 30)
        config.appWorkspaces = ["com.example": 3]
        config.rebind("close", to: "ctrl+cmd+q")
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: data), config)
    }

    func testAnInvalidLayoutIsAnError() {
        XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: Data(#"{"defaultLayout": "spiral"}"#.utf8)))
    }

    func testDefaultBindingsAreAllValid() {
        for modifier in ["ctrl+alt", "ctrl+cmd", "cmd+alt"] {
            var config = Config()
            config.modifier = modifier
            let bindings = config.effectiveBindings
            XCTAssertEqual(bindings.count, Config.defaultBindings.count, "\(modifier): two defaults collide")
            for (combo, command) in bindings {
                XCTAssertNotNil(Hotkey(combo), "\(combo) doesn't parse")
                XCTAssertNotNil(Command(command), "\(command) isn't a command")
                XCTAssertTrue(Hotkey.isAllowedAsGlobalShortcut(combo), "\(combo) would be refused by macOS")
            }
        }
    }

    func testEveryBoundCommandIsInTheSettingsList() {
        let listed = Set(ShortcutCatalog.groups.flatMap(\.items).map(\.command))
        for command in Set(Config.defaultBindings.values) {
            XCTAssertTrue(listed.contains(command), "\(command) is missing from Settings")
        }
        for command in listed {
            XCTAssertNotNil(Command(command), "Settings lists unknown command \(command)")
        }
    }

    func testUserBindingOverridesADefault() {
        var config = Config()
        config.bindings = ["mod+w": "layout-grid"]
        XCTAssertEqual(config.command(boundTo: "ctrl+alt+w"), "layout-grid")
    }

    func testNoneRemovesADefault() {
        var config = Config()
        config.bindings = ["mod+w": "none"]
        XCTAssertNil(config.command(boundTo: "ctrl+alt+w"))
    }

    func testModifierOrderDoesntMatter() {
        var config = Config()
        config.bindings = ["alt+ctrl+y": "layout-grid"]
        XCTAssertEqual(config.command(boundTo: "ctrl+alt+y"), "layout-grid")
    }

    func testRebindMovesTheShortcut() {
        var config = Config()
        config.rebind("close", to: "ctrl+cmd+q")
        XCTAssertEqual(config.combo(for: "close"), "ctrl+cmd+q")
        XCTAssertNil(config.command(boundTo: "ctrl+alt+w"), "the old combo is free")
    }

    func testRebindTwiceKeepsOnlyTheLatest() {
        var config = Config()
        config.rebind("close", to: "ctrl+cmd+q")
        config.rebind("close", to: "ctrl+cmd+x")
        XCTAssertEqual(config.combo(for: "close"), "ctrl+cmd+x")
        XCTAssertNil(config.command(boundTo: "ctrl+cmd+q"))
    }

    func testRebindOntoATakenComboTakesItOver() {
        var config = Config()
        config.rebind("close", to: "ctrl+alt+t")
        XCTAssertEqual(config.command(boundTo: "ctrl+alt+t"), "close")
        XCTAssertNil(config.combo(for: "toggle-float"))
    }

    func testResetRestoresTheDefault() {
        var config = Config()
        config.rebind("close", to: "ctrl+cmd+q")
        config.resetBinding("close")
        XCTAssertEqual(config.combo(for: "close"), "ctrl+alt+w")
        XCTAssertNil(config.command(boundTo: "ctrl+cmd+q"))
    }

    func testUnbind() {
        var config = Config()
        config.unbind("close")
        XCTAssertNil(config.combo(for: "close"))
        XCTAssertNil(config.command(boundTo: "ctrl+alt+w"))
    }

    func testExtraIsTheModifierNotInUse() {
        var config = Config()
        XCTAssertEqual(config.combo(for: "send-to-workspace-1"), "ctrl+alt+cmd+1")
        config.modifier = "ctrl+cmd"
        XCTAssertEqual(config.combo(for: "send-to-workspace-1"), "ctrl+alt+cmd+1")
        config.modifier = "cmd+alt"
        XCTAssertEqual(config.combo(for: "send-to-workspace-1"), "ctrl+alt+cmd+1")
        XCTAssertEqual(config.combo(for: "workspace-1"), "alt+cmd+1")
    }
}

final class HotkeyTests: XCTestCase {
    func testParsing() {
        XCTAssertNotNil(Hotkey("ctrl+alt+left"))
        XCTAssertNotNil(Hotkey("CMD+Shift+Return"))
        XCTAssertNil(Hotkey("ctrl+alt"), "no key")
        XCTAssertNil(Hotkey("ctrl+banana"), "unknown key")
        XCTAssertNil(Hotkey("ctrl+a+b"), "two keys")
    }

    func testDisplay() {
        XCTAssertEqual(Hotkey.displayString("ctrl+alt+shift+left"), "⌃⌥⇧←")
        XCTAssertEqual(Hotkey.displayString("cmd+alt+w"), "⌥⌘W")
        XCTAssertEqual(Hotkey.displayString("ctrl+alt+return"), "⌃⌥↩")
    }

    func testCanonicalOrder() {
        XCTAssertEqual(Hotkey.canonical("cmd+shift+alt+ctrl+Q"), "ctrl+alt+shift+cmd+q")
    }

    func testRecorderRoundTrip() {
        let combo = Hotkey.combo(keyCode: Int(Hotkey("ctrl+alt+g")!.keyCode), ctrl: true, alt: true, shift: false, cmd: false)
        XCTAssertEqual(combo, "ctrl+alt+g")
        XCTAssertNil(Hotkey.combo(keyCode: 9999, ctrl: true, alt: false, shift: false, cmd: false))
    }

    func testOptionOnlyShortcutsAreRefused() {
        XCTAssertFalse(Hotkey.isAllowedAsGlobalShortcut("alt+a"))
        XCTAssertFalse(Hotkey.isAllowedAsGlobalShortcut("alt+shift+a"))
        XCTAssertFalse(Hotkey.isAllowedAsGlobalShortcut("a"))
        XCTAssertTrue(Hotkey.isAllowedAsGlobalShortcut("ctrl+a"))
        XCTAssertTrue(Hotkey.isAllowedAsGlobalShortcut("alt+cmd+a"))
    }
}

final class ScrollAccumulatorTests: XCTestCase {
    func testManySmallDeltasMakeOneStep() {
        var scroll = ScrollAccumulator(threshold: 30)
        XCTAssertNil(scroll.add(dx: 0, dy: 10))
        XCTAssertNil(scroll.add(dx: 0, dy: 10))
        XCTAssertEqual(scroll.add(dx: 0, dy: 10), .up)
        XCTAssertNil(scroll.add(dx: 0, dy: 10), "starts over after a step")
    }

    func testDominantAxisWins() {
        var scroll = ScrollAccumulator(threshold: 30)
        XCTAssertNil(scroll.add(dx: 20, dy: 5))
        XCTAssertEqual(scroll.add(dx: 20, dy: 5), .left)
    }

    func testDirectionChangeCancelsTheOtherAxis() {
        var scroll = ScrollAccumulator(threshold: 30)
        XCTAssertNil(scroll.add(dx: 25, dy: 0))
        XCTAssertNil(scroll.add(dx: 0, dy: -25))
        XCTAssertNil(scroll.add(dx: 25, dy: 0), "the horizontal progress was discarded")
    }
}
