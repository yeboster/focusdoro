import AppKit
import Foundation
import UserNotifications

public protocol NotificationPresenting: AnyObject {
    func requestAuthorizationIfNeeded() async -> Bool
    func notifyFocusComplete(taskTitle: String, nextBreak: TimerPhase)
    func notifyBreakComplete(nextPhase: TimerPhase)
    func playCompletionSound()
}

/// Pure preference gate, split out so it can be tested without a notification centre.
public enum NotificationPolicy {
    public static func shouldNotify(preferences: AppPreferences, authorized: Bool) -> Bool {
        preferences.notificationsEnabled && authorized
    }

    public static func shouldPlaySound(preferences: AppPreferences) -> Bool {
        preferences.soundEnabled
    }

    public static func focusCompleteBody(taskTitle: String, nextBreak: TimerPhase, breakMinutes: Int) -> String {
        let trimmed = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = trimmed.isEmpty ? "your task" : "“\(trimmed)”"
        return "Focus on \(subject) is done. \(nextBreak.displayName) is \(breakMinutes) min."
    }
}

public final class NotificationService: NotificationPresenting {
    private let preferences: PreferencesStoring
    private let center: UNUserNotificationCenter?
    private var authorized = false
    private var didRequest = false

    public init(preferences: PreferencesStoring, center: UNUserNotificationCenter? = NotificationService.defaultCenter()) {
        self.preferences = preferences
        self.center = center
    }

    /// `UNUserNotificationCenter.current()` traps when the process has no bundle
    /// identifier, which is exactly the case for a bare `swift run` binary.
    public static func defaultCenter() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    @discardableResult
    public func requestAuthorizationIfNeeded() async -> Bool {
        guard let center else { return false }
        guard !didRequest else { return authorized }
        didRequest = true
        do {
            authorized = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            authorized = false
        }
        return authorized
    }

    public func notifyFocusComplete(taskTitle: String, nextBreak: TimerPhase) {
        let prefs = preferences.preferences
        let minutes = max(1, prefs.duration(for: nextBreak) / 60)
        post(
            title: "Focus complete",
            body: NotificationPolicy.focusCompleteBody(taskTitle: taskTitle, nextBreak: nextBreak, breakMinutes: minutes)
        )
    }

    public func notifyBreakComplete(nextPhase: TimerPhase) {
        post(title: "Break over", body: "Pick a Todoist task and start the next focus session.")
    }

    private func post(title: String, body: String) {
        guard let center, NotificationPolicy.shouldNotify(preferences: preferences.preferences, authorized: authorized) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if NotificationPolicy.shouldPlaySound(preferences: preferences.preferences) {
            content.sound = .default
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    /// A named system sound rather than a bundled asset: no binary payload, and it
    /// already honours the system output device and mute state.
    public func playCompletionSound() {
        let prefs = preferences.preferences
        guard NotificationPolicy.shouldPlaySound(preferences: prefs) else { return }
        let sound = NSSound(named: NSSound.Name(prefs.soundIdentifier)) ?? NSSound(named: NSSound.Name("Glass"))
        sound?.play()
    }

    public static var availableSoundNames: [String] {
        ["Glass", "Ping", "Hero", "Submarine", "Blow", "Funk", "Purr", "Tink"]
    }
}
