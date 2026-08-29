import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import FocusdoroCore

@Suite("Global hot keys")
struct HotKeyServiceTests {
    private let toggle = HotKeyBinding(keyCode: 3, modifiers: HotKeyFormatter.option | HotKeyFormatter.cmd, displayString: "⌥⌘F")
    private let startStop = HotKeyBinding(keyCode: 17, modifiers: HotKeyFormatter.option | HotKeyFormatter.cmd, displayString: "⌥⌘T")

    @Test("The default bindings validate")
    func defaultsValidate() throws {
        try HotKeyService.validate(AppPreferences.default.bindings)
    }

    @Test("A binding with no modifier is rejected")
    func modifierRequired() {
        let bindings: [HotKeyAction: HotKeyBinding] = [
            .togglePopover: HotKeyBinding(keyCode: 3, modifiers: 0, displayString: "F"),
        ]
        #expect(throws: HotKeyError.invalidBinding(.togglePopover)) {
            try HotKeyService.validate(bindings)
        }
    }

    @Test("Two actions cannot share the same shortcut")
    func duplicateRejected() {
        let bindings: [HotKeyAction: HotKeyBinding] = [
            .togglePopover: toggle,
            .startStopTimer: toggle,
        ]
        #expect(throws: HotKeyError.self) {
            try HotKeyService.validate(bindings)
        }
    }

    @Test("The same key code with different modifiers is not a duplicate")
    func sameKeyDifferentModifiers() throws {
        let bindings: [HotKeyAction: HotKeyBinding] = [
            .togglePopover: toggle,
            .startStopTimer: HotKeyBinding(keyCode: 3, modifiers: HotKeyFormatter.control | HotKeyFormatter.shift, displayString: "⌃⇧F"),
        ]
        try HotKeyService.validate(bindings)
    }

    @Test("Validation runs before registration, so a bad set leaves nothing registered")
    func validationPrecedesRegistration() {
        let service = HotKeyService()
        let bindings: [HotKeyAction: HotKeyBinding] = [
            .togglePopover: toggle,
            .startStopTimer: HotKeyBinding(keyCode: 17, modifiers: 0, displayString: "T"),
        ]
        #expect(throws: HotKeyError.invalidBinding(.startStopTimer)) {
            try service.register(bindings: bindings)
        }
        service.unregisterAll()
    }

    @Test("Unregistering when nothing is registered is safe and repeatable")
    func unregisterIsIdempotent() {
        let service = HotKeyService()
        service.unregisterAll()
        service.unregisterAll()
    }

    @Test("Every error maps to a plain-language message that names the action")
    func errorMessages() {
        #expect(HotKeyError.invalidBinding(.togglePopover).userMessage.contains(HotKeyAction.togglePopover.title))
        #expect(HotKeyError.invalidBinding(.togglePopover).userMessage.contains("modifier"))

        let duplicate = HotKeyError.duplicateBinding(.togglePopover, .startStopTimer)
        #expect(duplicate.userMessage.contains(HotKeyAction.startStopTimer.title))

        let failure = HotKeyError.registrationFailed(.startStopTimer, OSStatus(-9878))
        #expect(failure.userMessage.contains(HotKeyAction.startStopTimer.title))
        // The raw OSStatus is diagnostic noise; users get an actionable sentence instead.
        #expect(!failure.userMessage.contains("9878"))
    }

    @Test("AppKit modifier flags convert to the Carbon mask")
    func carbonModifiers() {
        #expect(HotKeyFormatter.carbonModifiers(from: [.command]) == HotKeyFormatter.cmd)
        #expect(HotKeyFormatter.carbonModifiers(from: [.option, .command]) == HotKeyFormatter.option | HotKeyFormatter.cmd)
        #expect(HotKeyFormatter.carbonModifiers(from: [.shift, .control]) == HotKeyFormatter.shift | HotKeyFormatter.control)
        // Caps lock and function are not shortcut modifiers for our purposes.
        #expect(HotKeyFormatter.carbonModifiers(from: [.capsLock, .function]) == 0)
    }

    @Test("Display strings use the canonical macOS symbol order")
    func displayStringOrder() {
        let all = HotKeyFormatter.control | HotKeyFormatter.option | HotKeyFormatter.shift | HotKeyFormatter.cmd
        #expect(HotKeyFormatter.displayString(keyCode: 3, modifiers: all) == "⌃⌥⇧⌘F")
        #expect(HotKeyFormatter.displayString(keyCode: 17, modifiers: HotKeyFormatter.option | HotKeyFormatter.cmd) == "⌥⌘T")
        #expect(HotKeyFormatter.displayString(keyCode: 49, modifiers: HotKeyFormatter.cmd) == "⌘Space")
    }

    @Test("An unknown key code still produces something displayable")
    func unknownKeyName() {
        #expect(HotKeyFormatter.keyName(for: 999) == "Key 999")
        #expect(!HotKeyFormatter.displayString(keyCode: 999, modifiers: HotKeyFormatter.cmd).isEmpty)
    }

    @Test("Bindings survive a preferences encode/decode round trip")
    func bindingsSerialize() throws {
        var preferences = AppPreferences.default
        preferences.bindings[.startStopTimer] = HotKeyBinding(keyCode: 49, modifiers: HotKeyFormatter.control, displayString: "⌃Space")

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        #expect(decoded.bindings[.startStopTimer] == preferences.bindings[.startStopTimer])
        #expect(decoded.bindings[.togglePopover] == preferences.bindings[.togglePopover])
        try HotKeyService.validate(decoded.bindings)
    }
}

@Suite("Notification policy")
struct NotificationPolicyTests {
    @Test("Notifications need both the preference and system authorization")
    func notifyRequiresBoth() {
        var preferences = AppPreferences.default
        #expect(NotificationPolicy.shouldNotify(preferences: preferences, authorized: true))
        #expect(!NotificationPolicy.shouldNotify(preferences: preferences, authorized: false))

        preferences.notificationsEnabled = false
        #expect(!NotificationPolicy.shouldNotify(preferences: preferences, authorized: true))
    }

    @Test("The sound is independent of notification authorization")
    func soundIsIndependent() {
        var preferences = AppPreferences.default
        preferences.notificationsEnabled = false
        #expect(NotificationPolicy.shouldPlaySound(preferences: preferences))

        preferences.soundEnabled = false
        #expect(!NotificationPolicy.shouldPlaySound(preferences: preferences))
    }

    @Test("The focus-complete body names the task and the upcoming break")
    func focusCompleteBody() {
        let body = NotificationPolicy.focusCompleteBody(taskTitle: "Write the handoff doc", nextBreak: .shortBreak, breakMinutes: 5)
        #expect(body.contains("Write the handoff doc"))
        #expect(body.contains("5 min"))
        #expect(body.contains(TimerPhase.shortBreak.displayName))
    }

    @Test("A blank task title falls back to neutral wording rather than empty quotes")
    func blankTitleFallback() {
        let body = NotificationPolicy.focusCompleteBody(taskTitle: "   ", nextBreak: .longBreak, breakMinutes: 15)
        #expect(body.contains("your task"))
        #expect(!body.contains("“”"))
        #expect(body.contains("15 min"))
    }

    @Test("Every offered sound name is a real system sound")
    func soundsExist() throws {
        #expect(NotificationService.availableSoundNames.contains(AppPreferences.default.soundIdentifier))
        for name in NotificationService.availableSoundNames {
            #expect(NSSound(named: name) != nil, "\(name) is not a system sound")
        }
    }
}
