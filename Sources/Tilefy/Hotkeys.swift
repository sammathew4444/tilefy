import Carbon.HIToolbox
import Foundation
import TilefyCore

/// Global shortcuts through Carbon's hot key API. It needs no permission, and doesn't intercept
/// any keystrokes other than the registered ones.
final class HotkeyCenter {
    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    private static let signature: OSType = 0x544C_4659  // 'TLFY'

    /// Replaces all shortcuts. Returns the combos macOS refused or that couldn't be parsed.
    @discardableResult
    func register(_ bindings: [(combo: String, action: () -> Void)]) -> [String] {
        installHandlerIfNeeded()
        unregisterAll()

        var failed: [String] = []
        for (index, binding) in bindings.enumerated() {
            guard let hotkey = Hotkey(binding.combo) else {
                failed.append(binding.combo)
                continue
            }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                hotkey.keyCode,
                hotkey.carbonModifiers,
                EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
                handlers[id] = binding.action
            } else {
                failed.append(binding.combo)
            }
        }
        return failed
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard status == noErr else { return status }
                let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
                center.handlers[id.id]?()
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }
}
