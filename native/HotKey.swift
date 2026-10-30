import Carbon
import Foundation

final class PanelHotKey {
    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<PanelHotKey>.fromOpaque(context).takeUnretainedValue().onPress?()
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func configure(_ choice: String) throws {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        guard choice != "off" else { return }
        let key: UInt32 = choice == "control-option-space" ? UInt32(kVK_Space) : UInt32(kVK_ANSI_P)
        let modifiers: UInt32 = choice == "control-option-space" ? UInt32(controlKey | optionKey) :
            choice == "control-option-p" ? UInt32(controlKey | optionKey) : UInt32(cmdKey | optionKey)
        let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x50495353, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else { throw PanelError("The global shortcut is already in use (\(status)). Choose another in Settings.") }
    }
    deinit { if let hotKey { UnregisterEventHotKey(hotKey) }; if let handler { RemoveEventHandler(handler) } }
}
