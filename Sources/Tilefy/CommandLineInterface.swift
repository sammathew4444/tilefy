import Foundation
import TilefyCore

/// `Tilefy dispatch <command>` and `Tilefy status`, for scripts (like `hyprctl dispatch` on Hyprland).
/// They talk to the running app through distributed notifications.
enum CommandLineInterface {
    static let dispatchName = Notification.Name("app.tilefy.dispatch")
    static let statusRequestName = Notification.Name("app.tilefy.status-request")
    static let statusReplyName = Notification.Name("app.tilefy.status-reply")
    /// Opens a Settings tab: general, layouts, shortcuts or apps.
    static let settingsPrefix = "open-settings"
    static let togglePause = "toggle-pause"
    static let reloadConfig = "reload-config"

    /// Returns an exit code if the arguments were a command-line request, or nil to launch the app.
    static func runIfRequested(_ arguments: [String]) -> Int32? {
        switch arguments.dropFirst().first {
        case "dispatch":
            guard arguments.count == 3 else {
                print("usage: Tilefy dispatch <command>")
                return 64
            }
            let command = arguments[2]
            guard Command(command) != nil || command.hasPrefix(settingsPrefix) || command == togglePause || command == reloadConfig else {
                print("unknown command: \(command)")
                return 64
            }
            DistributedNotificationCenter.default().postNotificationName(
                dispatchName, object: command, userInfo: nil, deliverImmediately: true
            )
            return 0
        case "status":
            return printStatus()
        case "--help", "-h", "help":
            print("""
            usage:
              Tilefy                       start the app
              Tilefy --only-app=<id>       manage only one app (bundle ID or name)
              Tilefy dispatch <command>    run a command, e.g. workspace-2 or layout-grid
              Tilefy status                print the current state as JSON
            """)
            return 0
        default:
            return nil
        }
    }

    private static func printStatus() -> Int32 {
        var reply: String?
        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(forName: statusReplyName, object: nil, queue: .main) { note in
            reply = note.object as? String
        }
        defer { center.removeObserver(token) }

        center.postNotificationName(statusRequestName, object: nil, userInfo: nil, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(2)
        while reply == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        guard let reply else {
            print("Tilefy isn't running")
            return 1
        }
        print(reply)
        return 0
    }
}
