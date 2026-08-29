import Foundation

/// Renders the Slack status line for a session. Pure, so the placeholder rules and the
/// length cap are testable without a network.
public enum SlackStatusFormatter {
    public static let taskPlaceholder = "{task}"

    public static func text(template: String, taskTitle: String) -> String {
        let title = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = title.isEmpty ? "a task" : title
        let rendered = template.replacingOccurrences(of: taskPlaceholder, with: subject)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = rendered.isEmpty ? "Focusing" : rendered
        guard fallback.count > SlackClient.statusTextLimit else { return fallback }
        // Slack truncates silently; an ellipsis makes the cut deliberate.
        return String(fallback.prefix(SlackClient.statusTextLimit - 1)) + "…"
    }
}

/// Snoozes Slack notifications for the length of the session and, optionally, says what
/// the session is about in the profile status.
///
/// The snooze carries its own expiry, so a crash mid-session self-heals when it lapses;
/// `release()` still ends it early on a normal finish.
public final class SlackPresenceChannel: PresenceChannel, @unchecked Sendable {
    public let name = "Slack"
    private let client: SlackAPI
    private let settings: @Sendable () -> FocusPresenceSettings
    private let hasToken: @Sendable () -> Bool

    public init(
        client: SlackAPI,
        settings: @escaping @Sendable () -> FocusPresenceSettings,
        hasToken: @escaping @Sendable () -> Bool
    ) {
        self.client = client
        self.settings = settings
        self.hasToken = hasToken
    }

    public func engage(_ context: FocusPresenceContext) async throws {
        let settings = settings()
        guard settings.slackEnabled else { return }
        guard hasToken() else { throw SlackError.missingToken }

        try await client.setSnooze(minutes: context.minutes)
        guard settings.slackStatusEnabled else { return }
        try await client.setStatus(
            text: SlackStatusFormatter.text(template: settings.slackStatusTemplate, taskTitle: context.taskTitle),
            emoji: settings.slackStatusEmoji,
            expiresAt: context.endsAt
        )
    }

    public func release() async throws {
        let settings = settings()
        guard settings.slackEnabled, hasToken() else { return }

        // Clear the status even if ending the snooze fails: a stale "Focusing on …" is
        // the more visible of the two leftovers.
        var firstError: Error?
        do { try await client.endSnooze() } catch { firstError = error }
        if settings.slackStatusEnabled {
            do { try await client.clearStatus() } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }
}
