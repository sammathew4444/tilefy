import AppKit

if let exitCode = CommandLineInterface.runIfRequested(CommandLine.arguments) {
    exit(exitCode)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
