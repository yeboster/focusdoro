import Foundation

/// Serializable description of a global hotkey. Carbon key codes and modifier mask.
public struct HotKeyBinding: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `shiftKey`, `controlKey`).
    public var modifiers: UInt32
    /// Human-readable form shown in settings, e.g. `⌥⌘F`.
    public var displayString: String

    public init(keyCode: UInt32, modifiers: UInt32, displayString: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayString = displayString
    }

    public var isValid: Bool { modifiers != 0 }
}

public enum HotKeyAction: String, Codable, Sendable, CaseIterable {
    case togglePopover
    case startStopTimer

    public var title: String {
        switch self {
        case .togglePopover: return "Open / close Focusdoro"
        case .startStopTimer: return "Start / stop timer"
        }
    }
}

/// How a focus session announces itself outside the app. Off by default: macOS Focus
/// needs the user to pick their Shortcuts, and Slack needs a token.
public struct FocusPresenceSettings: Codable, Equatable, Sendable {
    public var macFocusEnabled: Bool
    /// Name of a Shortcuts shortcut whose action turns the Focus on.
    public var startShortcutName: String?
    public var endShortcutName: String?
    public var slackEnabled: Bool
    public var slackStatusEnabled: Bool
    /// `{task}` is replaced with the task title.
    public var slackStatusTemplate: String
    public var slackStatusEmoji: String

    public init(
        macFocusEnabled: Bool = false,
        startShortcutName: String? = nil,
        endShortcutName: String? = nil,
        slackEnabled: Bool = false,
        slackStatusEnabled: Bool = true,
        slackStatusTemplate: String = "Focusing on {task}",
        slackStatusEmoji: String = ":tomato:"
    ) {
        self.macFocusEnabled = macFocusEnabled
        self.startShortcutName = startShortcutName
        self.endShortcutName = endShortcutName
        self.slackEnabled = slackEnabled
        self.slackStatusEnabled = slackStatusEnabled
        self.slackStatusTemplate = slackStatusTemplate
        self.slackStatusEmoji = slackStatusEmoji
    }

    public static let `default` = FocusPresenceSettings()

    /// True once the user has given macOS Focus everything it needs to run.
    public var macFocusIsUsable: Bool {
        macFocusEnabled
            && !(startShortcutName ?? "").isEmpty
            && !(endShortcutName ?? "").isEmpty
    }
}

/// Non-sensitive preferences only. The Todoist token lives in the Keychain and
/// must never be written here (spec §6).
public struct AppPreferences: Codable, Equatable, Sendable {
    public var focusDurationSeconds: Int
    public var shortBreakDurationSeconds: Int
    public var longBreakDurationSeconds: Int
    public var longBreakCadence: Int
    public var soundEnabled: Bool
    public var soundIdentifier: String
    public var notificationsEnabled: Bool
    public var bindings: [HotKeyAction: HotKeyBinding]
    public var lastSelectedTaskID: String?
    /// Seconds the completion overlay waits before auto-starting the break.
    public var breakAutoStartDelaySeconds: Int
    /// Optional on the wire so preferences written by an earlier build still decode:
    /// the synthesized decoder uses `decodeIfPresent` for optionals.
    public var taskDateScopeID: String?
    public var taskSortOrderID: String?
    public var taskFilterCriteria: TaskFilterCriteria?
    /// Whether a stopped focus session still posts its measured time to Todoist.
    /// Optional on the wire for the same backward-compatible reason as the two above.
    public var logsAbandonedTimeFlag: Bool?
    /// Optional for the same reason: an install written before focus mode existed
    /// decodes with nothing set and falls back to the all-off default.
    public var focusPresenceSettings: FocusPresenceSettings?

    /// Time already invested is real time, so the default is to log it.
    public var logsAbandonedTime: Bool {
        get { logsAbandonedTimeFlag ?? true }
        set { logsAbandonedTimeFlag = newValue }
    }

    public var presence: FocusPresenceSettings {
        get { focusPresenceSettings ?? .default }
        set { focusPresenceSettings = newValue }
    }

    public var taskDateScope: TaskDateScope {
        get { taskDateScopeID.flatMap(TaskDateScope.init(rawValue:)) ?? .today }
        set { taskDateScopeID = newValue.rawValue }
    }

    public var taskSortOrder: TaskSortOrder {
        get { taskSortOrderID.flatMap(TaskSortOrder.init(rawValue:)) ?? .dueDate }
        set { taskSortOrderID = newValue.rawValue }
    }

    public var taskFilter: TaskFilterCriteria {
        get { taskFilterCriteria ?? .none }
        // An inactive filter is stored as nil, so a default install writes nothing.
        set { taskFilterCriteria = newValue.isActive ? newValue : nil }
    }

    public static let `default` = AppPreferences(
        focusDurationSeconds: 1500,
        shortBreakDurationSeconds: 300,
        longBreakDurationSeconds: 900,
        longBreakCadence: 4,
        soundEnabled: true,
        soundIdentifier: "Glass",
        notificationsEnabled: true,
        bindings: [
            .togglePopover: HotKeyBinding(keyCode: 3, modifiers: 2048 | 256, displayString: "⌥⌘F"),
            .startStopTimer: HotKeyBinding(keyCode: 17, modifiers: 2048 | 256, displayString: "⌥⌘T"),
        ],
        lastSelectedTaskID: nil,
        breakAutoStartDelaySeconds: 10
    )

    public init(
        focusDurationSeconds: Int,
        shortBreakDurationSeconds: Int,
        longBreakDurationSeconds: Int,
        longBreakCadence: Int,
        soundEnabled: Bool,
        soundIdentifier: String,
        notificationsEnabled: Bool,
        bindings: [HotKeyAction: HotKeyBinding],
        lastSelectedTaskID: String?,
        breakAutoStartDelaySeconds: Int,
        taskDateScopeID: String? = nil,
        taskSortOrderID: String? = nil,
        taskFilterCriteria: TaskFilterCriteria? = nil,
        logsAbandonedTimeFlag: Bool? = nil,
        focusPresenceSettings: FocusPresenceSettings? = nil
    ) {
        self.focusDurationSeconds = focusDurationSeconds
        self.shortBreakDurationSeconds = shortBreakDurationSeconds
        self.longBreakDurationSeconds = longBreakDurationSeconds
        self.longBreakCadence = longBreakCadence
        self.soundEnabled = soundEnabled
        self.soundIdentifier = soundIdentifier
        self.notificationsEnabled = notificationsEnabled
        self.bindings = bindings
        self.lastSelectedTaskID = lastSelectedTaskID
        self.breakAutoStartDelaySeconds = breakAutoStartDelaySeconds
        self.taskDateScopeID = taskDateScopeID
        self.taskSortOrderID = taskSortOrderID
        self.taskFilterCriteria = taskFilterCriteria
        self.logsAbandonedTimeFlag = logsAbandonedTimeFlag
        self.focusPresenceSettings = focusPresenceSettings
    }

    public func duration(for phase: TimerPhase) -> Int {
        switch phase {
        case .focus: return focusDurationSeconds
        case .shortBreak: return shortBreakDurationSeconds
        case .longBreak: return longBreakDurationSeconds
        }
    }

    /// Long break lands on every `longBreakCadence`-th completed focus session.
    public func breakPhase(afterCompletedFocusCount count: Int) -> TimerPhase {
        guard longBreakCadence > 0 else { return .shortBreak }
        return count % longBreakCadence == 0 && count > 0 ? .longBreak : .shortBreak
    }
}

public protocol PreferencesStoring: AnyObject {
    var preferences: AppPreferences { get set }
}

public final class UserDefaultsPreferencesStore: PreferencesStoring, @unchecked Sendable {
    private static let key = "focusdoro.preferences.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: AppPreferences

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cached = Self.load(from: defaults) ?? .default
    }

    public var preferences: AppPreferences {
        get {
            lock.lock(); defer { lock.unlock() }
            return cached
        }
        set {
            lock.lock()
            cached = newValue
            lock.unlock()
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.key)
            }
        }
    }

    private static func load(from defaults: UserDefaults) -> AppPreferences? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AppPreferences.self, from: data)
    }
}

public final class InMemoryPreferencesStore: PreferencesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppPreferences

    public init(_ value: AppPreferences = .default) { self.value = value }

    public var preferences: AppPreferences {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
