import Foundation

/// What a starting focus session tells the outside world about itself.
public struct FocusPresenceContext: Equatable, Sendable {
    public var taskTitle: String
    /// Minutes the session still has to run. Slack's snooze is expressed in minutes.
    public var minutes: Int
    public var endsAt: Date

    public init(taskTitle: String, minutes: Int, endsAt: Date) {
        self.taskTitle = taskTitle
        self.minutes = minutes
        self.endsAt = endsAt
    }
}

/// One outward-facing "I am focusing" surface: macOS Focus, Slack, and whatever comes
/// next. A channel that is switched off in preferences returns without doing anything.
public protocol PresenceChannel: Sendable {
    /// Shown in the banner when this channel is the one that failed.
    var name: String { get }
    func engage(_ context: FocusPresenceContext) async throws
    func release() async throws
}

public struct PresenceFailure: Equatable, Sendable {
    public var channel: String
    public var message: String

    public init(channel: String, message: String) {
        self.channel = channel
        self.message = message
    }
}

/// Fans a session's start and end out to every channel.
///
/// Nothing here can fail the timer: a channel that throws is collected into a
/// `PresenceFailure` and surfaced as a banner, and the remaining channels still run.
/// Release is idempotent, so a wake, a relaunch, and a normal finish can all call it.
public actor PresenceCoordinator {
    private let channels: [PresenceChannel]
    private var isEngaged = false

    public init(channels: [PresenceChannel]) {
        self.channels = channels
    }

    @discardableResult
    public func engage(_ context: FocusPresenceContext) async -> [PresenceFailure] {
        isEngaged = true
        return await forEachChannel { try await $0.engage(context) }
    }

    @discardableResult
    public func release() async -> [PresenceFailure] {
        guard isEngaged else { return [] }
        isEngaged = false
        return await forEachChannel { try await $0.release() }
    }

    private func forEachChannel(
        _ body: @Sendable (PresenceChannel) async throws -> Void
    ) async -> [PresenceFailure] {
        var failures: [PresenceFailure] = []
        for channel in channels {
            do {
                try await body(channel)
            } catch is CancellationError {
                continue
            } catch {
                failures.append(
                    PresenceFailure(channel: channel.name, message: PresenceMessage.text(for: error))
                )
            }
        }
        return failures
    }
}

public enum PresenceMessage {
    /// Plain language for the banner. Never interpolates a token or a raw response body.
    public static func text(for error: Error) -> String {
        switch error {
        case let error as SlackError: return error.userMessage
        case let error as ShortcutError: return error.userMessage
        default: return "Something went wrong."
        }
    }

    /// One banner line for however many channels failed.
    public static func banner(for failures: [PresenceFailure]) -> String? {
        guard let first = failures.first else { return nil }
        if failures.count == 1 { return "\(first.channel): \(first.message)" }
        let names = failures.map(\.channel).joined(separator: " and ")
        return "\(names) could not be updated for this session."
    }
}

/// Everything the settings screen needs to configure focus mode, bundled so `AppModel`
/// takes one optional collaborator instead of four.
public struct PresenceServices: Sendable {
    public let coordinator: PresenceCoordinator
    public let slack: SlackAPI
    /// Keychain entry for the Slack user token; separate from the Todoist one.
    public let slackTokens: TokenStoring
    public let shortcuts: ShortcutRunning

    public init(
        coordinator: PresenceCoordinator,
        slack: SlackAPI,
        slackTokens: TokenStoring,
        shortcuts: ShortcutRunning
    ) {
        self.coordinator = coordinator
        self.slack = slack
        self.slackTokens = slackTokens
        self.shortcuts = shortcuts
    }

    /// Wires the standard channels: macOS Focus through Shortcuts, plus Slack.
    public static func live(
        slack: SlackAPI,
        slackTokens: TokenStoring,
        shortcuts: ShortcutRunning = ShortcutsCommandRunner(),
        settings: @escaping @Sendable () -> FocusPresenceSettings
    ) -> PresenceServices {
        let hasToken: @Sendable () -> Bool = { ((try? slackTokens.readToken()) ?? nil)?.isEmpty == false }
        return PresenceServices(
            coordinator: PresenceCoordinator(channels: [
                MacFocusChannel(runner: shortcuts, settings: settings),
                SlackPresenceChannel(client: slack, settings: settings, hasToken: hasToken),
            ]),
            slack: slack,
            slackTokens: slackTokens,
            shortcuts: shortcuts
        )
    }
}
