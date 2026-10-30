import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys through Carbon's RegisterEventHotKey, which needs no
/// Accessibility permission.
final class HotKeys {
    static let shared = HotKeys()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var nextId: UInt32 = 1
    private var handlerInstalled = false

    struct Combo: CustomStringConvertible {
        var keyCode: UInt32
        var modifiers: UInt32
        var display: String
        var description: String { display }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    @discardableResult
    func register(_ combo: Combo, action: @escaping () -> Void) -> Bool {
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4D53_4E50), id: nextId) // 'MSNP'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        actions[nextId] = action
        nextId += 1
        return true
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeys.shared.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    // MARK: Parsing "cmd+shift+2"

    static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7,
        "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13,
        "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19,
        "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
        "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "slash": kVK_ANSI_Slash, "period": kVK_ANSI_Period,
        "comma": kVK_ANSI_Comma, "semicolon": kVK_ANSI_Semicolon, "quote": kVK_ANSI_Quote,
        "grave": kVK_ANSI_Grave, "backslash": kVK_ANSI_Backslash,
        "leftbracket": kVK_ANSI_LeftBracket, "rightbracket": kVK_ANSI_RightBracket,
    ]

    static func parse(_ text: String) -> Combo? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, let code = keyCodes[keyName] else { return nil }
        var mods: UInt32 = 0
        var disp = ""
        for p in parts.dropLast() {
            switch p {
            case "ctrl", "control": mods |= UInt32(controlKey); disp += "⌃"
            case "alt", "opt", "option": mods |= UInt32(optionKey); disp += "⌥"
            case "shift": mods |= UInt32(shiftKey); disp += "⇧"
            case "cmd", "command", "super": mods |= UInt32(cmdKey); disp += "⌘"
            default: return nil
            }
        }
        // Normalize display order to the macOS convention ⌃⌥⇧⌘.
        let order: [Character] = ["⌃", "⌥", "⇧", "⌘"]
        disp = String(order.filter { disp.contains($0) })
        return Combo(keyCode: UInt32(code), modifiers: mods, display: disp + keyName.uppercased())
    }

    /// For NSMenuItem key equivalents.
    static func menuEquivalent(_ text: String) -> (String, NSEvent.ModifierFlags)? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, key.count == 1 else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for p in parts.dropLast() {
            switch p {
            case "ctrl", "control": flags.insert(.control)
            case "alt", "opt", "option": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "cmd", "command", "super": flags.insert(.command)
            default: return nil
            }
        }
        return (key, flags)
    }
}
