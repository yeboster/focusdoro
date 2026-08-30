import Foundation
import ServiceManagement

/// What the system says about the app's login item right now. `SMAppService` is the
/// source of truth — mirroring it into preferences would let the two drift when the
/// user flips the switch in System Settings instead of here.
public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, but the user still has to allow it in System Settings › Login Items.
    case requiresApproval
    /// No bundle to register: a bare `swift run` binary, or a unit-test process.
    case unavailable

    public var isOn: Bool { self == .enabled || self == .requiresApproval }
}

public enum LoginItemError: Error, Equatable {
    case unavailable
    case failed(String)

    public var userMessage: String {
        switch self {
        case .unavailable:
            return "Open at login needs the built Focusdoro.app; it does nothing for a raw binary."
        case .failed(let detail):
            return "macOS refused to change the login item: \(detail)"
        }
    }
}

public protocol LoginItemManaging: AnyObject, Sendable {
    func status() -> LoginItemStatus
    func setEnabled(_ enabled: Bool) throws
}

/// `SMAppService.mainApp` (macOS 13+) replaces the old login-item helper: no helper
/// target, no `SMLoginItemSetEnabled`, and the user can revoke it in System Settings.
public final class LoginItemService: LoginItemManaging, @unchecked Sendable {
    private let service: SMAppService?

    /// `SMAppService` needs a real bundle with an identifier; without one, registering
    /// throws `kSMErrorInvalidPlist` rather than doing anything useful.
    public init(service: SMAppService? = LoginItemService.defaultService()) {
        self.service = service
    }

    public static func defaultService() -> SMAppService? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return SMAppService.mainApp
    }

    public func status() -> LoginItemStatus {
        guard let service else { return .unavailable }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .disabled
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        guard let service else { throw LoginItemError.unavailable }
        do {
            if enabled {
                // Registering an already-registered app throws; the status check keeps
                // a double toggle from surfacing a bogus error.
                guard service.status != .enabled else { return }
                try service.register()
            } else {
                guard service.status != .notRegistered else { return }
                try service.unregister()
            }
        } catch {
            throw LoginItemError.failed((error as NSError).localizedDescription)
        }
    }
}

/// Test double, and the stand-in when the app runs unbundled.
public final class InMemoryLoginItemService: LoginItemManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var current: LoginItemStatus
    private var failure: LoginItemError?
    /// Mirrors the machine where the user has to approve the item in System Settings:
    /// registering succeeds, and the status stays `.requiresApproval`.
    private let needsApproval: Bool
    public private(set) var writes: [Bool] = []

    public init(status: LoginItemStatus = .disabled, failure: LoginItemError? = nil) {
        self.current = status
        self.failure = failure
        self.needsApproval = status == .requiresApproval
    }

    public func status() -> LoginItemStatus {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func setEnabled(_ enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        writes.append(enabled)
        if let failure { throw failure }
        current = enabled ? (needsApproval ? .requiresApproval : .enabled) : .disabled
    }
}
