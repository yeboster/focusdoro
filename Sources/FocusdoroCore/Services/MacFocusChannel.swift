import Foundation

public enum ShortcutError: Error, Equatable {
    case notConfigured
    case missing(name: String)
    case failed(name: String, status: Int32)
    case unavailable

    public var userMessage: String {
        switch self {
        case .notConfigured:
            return "Pick the shortcuts that turn your Focus on and off in Settings."
        case .missing(let name):
            return "The shortcut “\(name)” no longer exists."
        case .failed(let name, _):
            return "The shortcut “\(name)” did not run."
        case .unavailable:
            return "The Shortcuts command-line tool is unavailable."
        }
    }
}

public protocol ShortcutRunning: Sendable {
    func run(named name: String) async throws
    func availableShortcuts() async -> [String]
}

/// macOS exposes no API for switching a Focus on, but the Shortcuts app does: a
/// shortcut whose only action is "Set Focus" can be run headlessly with
/// `/usr/bin/shortcuts run <name>`. That keeps Focusdoro out of private frameworks and
/// leaves the user in charge of which Focus is used.
public final class ShortcutsCommandRunner: ShortcutRunning, @unchecked Sendable {
    public static let executablePath = "/usr/bin/shortcuts"
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func run(named name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ShortcutError.notConfigured }
        let result = try await execute(arguments: ["run", trimmed])
        guard result.status == 0 else {
            // `shortcuts` answers a name it cannot resolve with a non-zero status and a
            // message on stderr; the two cases read very differently to the user.
            if result.errorOutput.localizedCaseInsensitiveContains("couldn't find")
                || result.errorOutput.localizedCaseInsensitiveContains("not found") {
                throw ShortcutError.missing(name: trimmed)
            }
            throw ShortcutError.failed(name: trimmed, status: result.status)
        }
    }

    public func availableShortcuts() async -> [String] {
        guard let result = try? await execute(arguments: ["list"]), result.status == 0 else { return [] }
        return result.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private struct ProcessResult {
        var status: Int32
        var output: String
        var errorOutput: String
    }

    private func execute(arguments: [String]) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: Self.executablePath) else {
            throw ShortcutError.unavailable
        }
        let timeout = timeout
        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.executablePath)
            process.arguments = arguments
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do {
                try process.run()
            } catch {
                throw ShortcutError.unavailable
            }
            // A shortcut that opens a dialog would otherwise hang the session start.
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning { process.terminate() }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ProcessResult(
                status: process.terminationStatus,
                output: String(data: outData, encoding: .utf8) ?? "",
                errorOutput: String(data: errData, encoding: .utf8) ?? ""
            )
        }.value
    }
}

/// Runs the user's "focus on" shortcut when a session starts and the "focus off" one
/// when it ends. Disabled by default: it only does anything once both are picked.
public final class MacFocusChannel: PresenceChannel, @unchecked Sendable {
    public let name = "macOS Focus"
    private let runner: ShortcutRunning
    private let settings: @Sendable () -> FocusPresenceSettings

    public init(runner: ShortcutRunning, settings: @escaping @Sendable () -> FocusPresenceSettings) {
        self.runner = runner
        self.settings = settings
    }

    public func engage(_ context: FocusPresenceContext) async throws {
        let settings = settings()
        guard settings.macFocusEnabled else { return }
        guard let shortcut = settings.startShortcutName, !shortcut.isEmpty else {
            throw ShortcutError.notConfigured
        }
        try await runner.run(named: shortcut)
    }

    public func release() async throws {
        let settings = settings()
        guard settings.macFocusEnabled else { return }
        guard let shortcut = settings.endShortcutName, !shortcut.isEmpty else {
            throw ShortcutError.notConfigured
        }
        try await runner.run(named: shortcut)
    }
}
