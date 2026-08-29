import AppKit
import Carbon.HIToolbox
import Foundation

public enum HotKeyError: Error, Equatable {
    case invalidBinding(HotKeyAction)
    case duplicateBinding(HotKeyAction, HotKeyAction)
    case registrationFailed(HotKeyAction, OSStatus)

    public var userMessage: String {
        switch self {
        case .invalidBinding(let action):
            return "\(action.title) needs at least one modifier key."
        case .duplicateBinding(let first, let second):
            return "\(first.title) and \(second.title) use the same shortcut."
        case .registrationFailed(let action, _):
            return "macOS refused the shortcut for \(action.title). Another app may already own it."
        }
    }
}

public protocol HotKeyRegistering: AnyObject {
    func register(bindings: [HotKeyAction: HotKeyBinding]) throws
    func unregisterAll()
}

/// Carbon `RegisterEventHotKey`, chosen over a third-party package so the app keeps a
/// zero-runtime-dependency footprint (spec §9). Handlers always run on the main thread.
public final class HotKeyService: HotKeyRegistering {
    public var onTogglePopover: (() -> Void)?
    public var onStartStop: (() -> Void)?

    private var handlerRef: EventHandlerRef?
    private var registered: [UInt32: (ref: EventHotKeyRef, action: HotKeyAction)] = [:]
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x4644_524F // 'FDRO'

    public init() {}

    deinit {
        unregisterAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Validates the whole set before touching Carbon, so a bad second binding cannot
    /// leave the first one half-registered.
    public static func validate(_ bindings: [HotKeyAction: HotKeyBinding]) throws {
        for (action, binding) in bindings where !binding.isValid {
            throw HotKeyError.invalidBinding(action)
        }
        let sorted = bindings.sorted { $0.key.rawValue < $1.key.rawValue }
        for i in sorted.indices {
            for j in sorted.indices where j > i {
                if sorted[i].value.keyCode == sorted[j].value.keyCode,
                   sorted[i].value.modifiers == sorted[j].value.modifiers {
                    throw HotKeyError.duplicateBinding(sorted[i].key, sorted[j].key)
                }
            }
        }
    }

    public func register(bindings: [HotKeyAction: HotKeyBinding]) throws {
        try Self.validate(bindings)
        unregisterAll()
        installHandlerIfNeeded()

        // Deterministic order so a failure message names a stable action.
        for (action, binding) in bindings.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: nextID)
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, id, GetEventDispatcherTarget(), 0, &ref)
            guard status == noErr, let ref else {
                unregisterAll()
                throw HotKeyError.registrationFailed(action, status)
            }
            registered[nextID] = (ref, action)
            nextID += 1
        }
    }

    public func unregisterAll() {
        for (_, entry) in registered { UnregisterEventHotKey(entry.ref) }
        registered.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr else { return status }
            let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
            service.handle(id: id.id)
            return noErr
        }, 1, &spec, context, &handlerRef)
    }

    private func handle(id: UInt32) {
        guard let action = registered[id]?.action else { return }
        // Carbon dispatches on the main run loop already; the hop keeps that a guarantee.
        DispatchQueue.main.async { [weak self] in
            switch action {
            case .togglePopover: self?.onTogglePopover?()
            case .startStopTimer: self?.onStartStop?()
            }
        }
    }
}

// MARK: - Key formatting

public enum HotKeyFormatter {
    public static let cmd: UInt32 = UInt32(cmdKey)
    public static let option: UInt32 = UInt32(optionKey)
    public static let shift: UInt32 = UInt32(shiftKey)
    public static let control: UInt32 = UInt32(controlKey)

    /// Converts an AppKit modifier flag set into Carbon's mask.
    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= cmd }
        if flags.contains(.option) { value |= option }
        if flags.contains(.shift) { value |= shift }
        if flags.contains(.control) { value |= control }
        return value
    }

    public static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var text = ""
        if modifiers & control != 0 { text += "⌃" }
        if modifiers & option != 0 { text += "⌥" }
        if modifiers & shift != 0 { text += "⇧" }
        if modifiers & cmd != 0 { text += "⌘" }
        text += keyName(for: keyCode)
        return text
    }

    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "5", 23: "6", 25: "9", 26: "7", 28: "8", 29: "0",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    public static func keyName(for keyCode: UInt32) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }
}
