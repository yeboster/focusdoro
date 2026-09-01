import AppKit
import Foundation
import UserNotifications

public protocol NotificationPresenting: AnyObject {
    func requestAuthorizationIfNeeded() async -> Bool
    func notifyFocusComplete(taskTitle: String, nextBreak: TimerPhase)
    func notifyBreakComplete(nextPhase: TimerPhase)
    func notifyUpdateAvailable(automaticInstallEnabled: Bool)
    func playCompletionSound()
}

public extension NotificationPresenting {
    func notifyUpdateAvailable(automaticInstallEnabled: Bool) {}
}

/// Pure preference gate, split out so it can be tested without a notification centre.
public enum NotificationPolicy {
    public static func shouldNotify(preferences: AppPreferences, authorized: Bool) -> Bool {
        preferences.notificationsEnabled && authorized
    }

    public static func shouldPlaySound(preferences: AppPreferences) -> Bool {
        preferences.soundEnabled
    }

    public static func focusCompleteBody(
        taskTitle: String,
        nextBreak: TimerPhase,
        breakMinutes: Int,
        showTaskName: Bool
    ) -> String {
        guard showTaskName else {
            return "Focus complete. Your \(breakMinutes)-minute break is ready."
        }
        let trimmed = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = trimmed.isEmpty ? "your task" : "“\(trimmed)”"
        return "Focus on \(subject) is done. \(nextBreak.displayName) is \(breakMinutes) min."
    }

    public static func updateAvailableBody(automaticInstallEnabled: Bool) -> String {
        automaticInstallEnabled
            ? "Automatic installation is starting."
            : "An update is available to review and install."
    }

    public static func isInstallUpdateAction(_ identifier: String) -> Bool {
        identifier == NotificationService.installUpdateActionIdentifier
    }
}

public final class NotificationService: NotificationPresenting {
    public static let updateCategoryIdentifier = "FOCUSDORO_UPDATE"
    public static let installUpdateActionIdentifier = "INSTALL_UPDATE"

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
            body: NotificationPolicy.focusCompleteBody(
                taskTitle: taskTitle,
                nextBreak: nextBreak,
                breakMinutes: minutes,
                showTaskName: prefs.showTaskNamesInNotifications
            )
        )
    }

    public func notifyBreakComplete(nextPhase: TimerPhase) {
        post(title: "Break over", body: "Pick a Todoist task and start the next focus session.")
    }

    public func registerUpdateCategory() {
        guard let center else { return }
        let install = UNNotificationAction(
            identifier: Self.installUpdateActionIdentifier,
            title: "Install",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.updateCategoryIdentifier,
            actions: [install],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    public func notifyUpdateAvailable(automaticInstallEnabled: Bool) {
        guard let center, NotificationPolicy.shouldNotify(preferences: preferences.preferences, authorized: authorized) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Focusdoro update available"
        content.body = NotificationPolicy.updateAvailableBody(automaticInstallEnabled: automaticInstallEnabled)
        content.categoryIdentifier = Self.updateCategoryIdentifier
        let request = UNNotificationRequest(identifier: "focusdoro-update", content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
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
