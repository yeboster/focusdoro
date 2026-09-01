import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var userMessage: String {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain access failed (\(status))."
        case .invalidData:
            return "The stored token could not be read."
        }
    }
}

public protocol TokenStoring: AnyObject, Sendable {
    func saveToken(_ token: String) throws
    func readToken() throws -> String?
    func deleteToken() throws
}

/// `kSecClassGenericPassword` entry scoped to the bundle identifier.
/// The token value is never logged, printed, or copied into `UserDefaults`.
public final class KeychainStore: TokenStoring, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = KeychainStore.defaultService, account: String = "todoist-api-token") {
        self.service = service
        self.account = account
    }

    /// Legacy service retained only so migration can delete its obsolete credential.
    public static var legacySlackService: String {
        (Bundle.main.bundleIdentifier ?? "com.focusdoro.app") + ".slack"
    }

    public static var defaultService: String {
        (Bundle.main.bundleIdentifier ?? "com.focusdoro.app") + ".todoist"
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func saveToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { throw KeychainError.invalidData }

        // Update in place when an entry already exists; otherwise insert.
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public func readToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return token.isEmpty ? nil : token
    }

    public func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// Deterministic in-memory double for tests and previews.
public final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(token: String? = nil) { self.token = token }

    public func saveToken(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        self.token = token
    }

    public func readToken() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    public func deleteToken() throws {
        lock.lock(); defer { lock.unlock() }
        token = nil
    }
}
