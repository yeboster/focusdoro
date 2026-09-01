import CryptoKit
import Foundation

public struct UpdateRelease: Equatable, Sendable {
    public let commitSHA: String
    public let assetURL: URL
    public let assetDigest: String

    public init(commitSHA: String, assetURL: URL, assetDigest: String) {
        self.commitSHA = commitSHA
        self.assetURL = assetURL
        self.assetDigest = assetDigest
    }
}

public protocol UpdateChecking: Sendable {
    func check() async throws -> UpdateRelease?
    /// Fetches latest validated metadata without announcement dedupe. Used when
    /// notification action cold-launches process and in-memory release is absent.
    func checkForInstallation() async throws -> UpdateRelease?
}

public extension UpdateChecking {
    func checkForInstallation() async throws -> UpdateRelease? { try await check() }
}

public protocol UpdateInstalling: Sendable {
    func install(_ release: UpdateRelease) async throws
}

public enum UpdateError: Error, Equatable, Sendable {
    case unavailable
    case invalidRelease
    case insecureDownload
    case digestMismatch
    case unsupportedInstallLocation
    case destinationNotWritable
    case invalidBundle
    case invalidCommit
    case invalidSignature
    case mountFailed
    case stagingFailed
    case helperFailed

    public var userMessage: String {
        switch self {
        case .unavailable: return "The update service is temporarily unavailable."
        case .invalidRelease: return "The available update has invalid release metadata."
        case .insecureDownload: return "The update download did not use a secure connection."
        case .digestMismatch: return "The downloaded update failed its security check."
        case .unsupportedInstallLocation: return "Focusdoro can only update itself from /Applications."
        case .destinationNotWritable: return "Focusdoro cannot replace the app in /Applications."
        case .invalidBundle, .invalidCommit, .invalidSignature:
            return "The downloaded update could not be verified."
        case .mountFailed: return "The downloaded update could not be opened."
        case .stagingFailed, .helperFailed: return "The update could not be installed."
        }
    }
}

public enum UpdateReleaseParser {
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
            let digest: String?

            enum CodingKeys: String, CodingKey {
                case name, digest
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case assets
            case tagName = "tag_name"
        }
    }

    public static func commitSHA(from tag: String) -> String? {
        let prefix = "continuous-"
        guard tag.hasPrefix(prefix) else { return nil }
        let sha = String(tag.dropFirst(prefix.count))
        guard sha.count == 40, sha.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }) else { return nil }
        return sha
    }

    public static func isAllowedAsset(name: String, url: URL) -> Bool {
        name == "Focusdoro.dmg" && url.scheme?.lowercased() == "https"
    }

    public static func decode(_ data: Data) throws -> UpdateRelease {
        let decoded: GitHubRelease
        do {
            decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.invalidRelease
        }
        guard let sha = commitSHA(from: decoded.tagName),
              let asset = decoded.assets.first(where: { isAllowedAsset(name: $0.name, url: $0.browserDownloadURL) }),
              let digest = asset.digest,
              UpdateDigest.isValidGitHubDigest(digest) else {
            throw UpdateError.invalidRelease
        }
        return UpdateRelease(commitSHA: sha, assetURL: asset.browserDownloadURL, assetDigest: digest)
    }
}

public enum UpdateTransportPolicy {
    public static func allowsRedirect(to url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }

    public static func accepts(url: URL?, status: Int) -> Bool {
        guard let url else { return false }
        return allowsRedirect(to: url) && (200..<300).contains(status)
    }
}

private final class SecureUpdateRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(UpdateTransportPolicy.allowsRedirect(to:)) == true ? request : nil)
    }
}

private enum SecureUpdateSession {
    static func make() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: SecureUpdateRedirectDelegate(), delegateQueue: nil)
    }
}

public enum UpdateReleasePolicy {
    public static func shouldAnnounce(remoteSHA: String, installedSHA: String?, lastNotifiedSHA: String?) -> Bool {
        remoteSHA != installedSHA && remoteSHA != lastNotifiedSHA
    }
}

public enum UpdateDigest {
    public static func isValidGitHubDigest(_ digest: String) -> Bool {
        guard digest.hasPrefix("sha256:") else { return false }
        let hex = digest.dropFirst("sha256:".count)
        return hex.count == 64 && hex.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    public static func matches(data: Data, githubDigest: String) -> Bool {
        guard isValidGitHubDigest(githubDigest) else { return false }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return githubDigest == "sha256:\(actual)"
    }
}

public enum UpdateReplacementHelper {
    /// Replacement and rollback stay on the Applications volume. Every path is a
    /// quoted positional argument; downloaded metadata never becomes shell source.
    public static let script = """
    #!/bin/sh
    PATH=/usr/bin:/bin
    export PATH
    pid="$1"
    current="$2"
    replacement="$3"
    backup="$4"
    temp_root="$5"
    while /bin/kill -0 "$pid" 2>/dev/null; do /bin/sleep 1; done
    if [ -e "$backup" ]; then /bin/rm -rf "$backup" || exit 1; fi
    if ! /bin/mv "$current" "$backup"; then /bin/rm -rf "$temp_root"; exit 1; fi
    if /bin/mv "$replacement" "$current"; then
      if /usr/bin/open "$current"; then
        /bin/rm -rf "$backup"
        /bin/rm -rf "$temp_root"
        exit 0
      fi
      /bin/rm -rf "$current"
    fi
    if ! /bin/mv "$backup" "$current"; then
      # Keep temp root and any surviving backup for manual recovery.
      exit 1
    fi
    /usr/bin/open "$current"
    /bin/rm -rf "$temp_root"
    exit 1
    """
}

public struct UpdateCommandResult: Sendable {
    public let status: Int32
    public let output: Data

    public init(status: Int32, output: Data = Data()) {
        self.status = status
        self.output = output
    }
}

public protocol UpdateCommandRunning: Sendable {
    func run(executable: URL, arguments: [String]) throws -> UpdateCommandResult
    func launchDetached(executable: URL, arguments: [String]) throws
}

public final class SystemUpdateCommandRunner: UpdateCommandRunning, @unchecked Sendable {
    public init() {}

    public func run(executable: URL, arguments: [String]) throws -> UpdateCommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain while child runs. Waiting first can deadlock when verbose tools fill
        // pipe buffer before they can exit.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return UpdateCommandResult(status: process.terminationStatus, output: output)
    }

    public func launchDetached(executable: URL, arguments: [String]) throws {
        let process = Process()
        let null = FileHandle.nullDevice
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = null
        process.standardOutput = null
        process.standardError = null
        try process.run()
    }
}

/// GitHub release discovery and installer. Every OS interaction is injected so release
/// parsing, policy, and command boundaries remain independently testable.
public actor GitHubUpdateService: UpdateChecking, UpdateInstalling {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/yeboster/focusdoro/releases/latest")!
    public static let lastNotifiedKey = "focusdoro.update.lastNotifiedSHA"

    private let session: URLSession
    private let installedCommit: String?
    private let expectedBundleIdentifier: String?
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let commands: UpdateCommandRunning
    private let releaseURL: URL
    private let currentAppURL: URL
    private let processIdentifier: Int32
    private var installInProgress = false

    public init(
        session: URLSession? = nil,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        commands: UpdateCommandRunning = SystemUpdateCommandRunner(),
        releaseURL: URL = GitHubUpdateService.latestReleaseURL,
        currentAppURL: URL? = nil,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.session = session ?? SecureUpdateSession.make()
        self.installedCommit = bundle.object(forInfoDictionaryKey: "FocusdoroBuildCommit") as? String
        self.expectedBundleIdentifier = bundle.bundleIdentifier
        self.defaults = defaults
        self.fileManager = fileManager
        self.commands = commands
        self.releaseURL = releaseURL
        self.currentAppURL = currentAppURL ?? bundle.bundleURL
        self.processIdentifier = processIdentifier
    }

    public func check() async throws -> UpdateRelease? {
        let release = try await fetchLatestRelease()
        let last = defaults.string(forKey: Self.lastNotifiedKey)
        guard UpdateReleasePolicy.shouldAnnounce(
            remoteSHA: release.commitSHA,
            installedSHA: installedCommit,
            lastNotifiedSHA: last
        ) else { return nil }
        defaults.set(release.commitSHA, forKey: Self.lastNotifiedKey)
        return release
    }

    public func checkForInstallation() async throws -> UpdateRelease? {
        let release = try await fetchLatestRelease()
        return release.commitSHA == installedCommit ? nil : release
    }

    private func fetchLatestRelease() async throws -> UpdateRelease {
        guard releaseURL.scheme?.lowercased() == "https" else { throw UpdateError.insecureDownload }
        var request = URLRequest(url: releaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Focusdoro", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.unavailable
        }
        guard let http = response as? HTTPURLResponse,
              UpdateTransportPolicy.accepts(url: http.url, status: http.statusCode) else {
            throw UpdateError.unavailable
        }
        return try UpdateReleaseParser.decode(data)
    }

    public func install(_ release: UpdateRelease) async throws {
        guard !installInProgress else { throw UpdateError.helperFailed }
        installInProgress = true
        var installationHandedOff = false
        defer {
            if !installationHandedOff { installInProgress = false }
        }

        guard release.assetURL.scheme?.lowercased() == "https",
              release.assetURL.lastPathComponent == "Focusdoro.dmg" else {
            throw UpdateError.insecureDownload
        }
        guard UpdateReleaseParser.commitSHA(from: "continuous-\(release.commitSHA)") == release.commitSHA,
              UpdateDigest.isValidGitHubDigest(release.assetDigest) else {
            throw UpdateError.invalidRelease
        }

        let exactInstallURL = URL(fileURLWithPath: "/Applications/Focusdoro.app", isDirectory: true)
        guard currentAppURL.standardizedFileURL == exactInstallURL.standardizedFileURL else {
            throw UpdateError.unsupportedInstallLocation
        }
        guard fileManager.isWritableFile(atPath: "/Applications"),
              fileManager.isWritableFile(atPath: currentAppURL.path) else {
            throw UpdateError.destinationNotWritable
        }
        guard let expectedBundleIdentifier, !expectedBundleIdentifier.isEmpty else {
            throw UpdateError.invalidBundle
        }

        let root = fileManager.temporaryDirectory.appendingPathComponent("FocusdoroUpdate-\(UUID().uuidString)", isDirectory: true)
        let dmgURL = root.appendingPathComponent("Focusdoro.dmg")
        let mountURL = root.appendingPathComponent("mount", isDirectory: true)
        // Replacement and backup are hidden siblings of current app. Same-volume
        // renames are atomic; generic /tmp may live on another volume.
        let replacementURL = URL(
            fileURLWithPath: "/Applications/.Focusdoro-update-\(UUID().uuidString).app",
            isDirectory: true
        )
        let helperURL = root.appendingPathComponent("replace.sh")
        let backupURL = URL(fileURLWithPath: "/Applications/.Focusdoro-update-backup-\(UUID().uuidString).app", isDirectory: true)
        var mounted = false
        var handedToHelper = false
        defer {
            if mounted {
                _ = try? commands.run(
                    executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                    arguments: ["detach", mountURL.path]
                )
            }
            if !handedToHelper {
                try? fileManager.removeItem(at: replacementURL)
                try? fileManager.removeItem(at: root)
            }
        }

        do {
            try fileManager.createDirectory(at: mountURL, withIntermediateDirectories: true)
            let (download, response) = try await session.data(from: release.assetURL)
            guard let http = response as? HTTPURLResponse,
                  UpdateTransportPolicy.accepts(url: http.url, status: http.statusCode) else {
                throw UpdateError.insecureDownload
            }
            guard UpdateDigest.matches(data: download, githubDigest: release.assetDigest) else {
                throw UpdateError.digestMismatch
            }
            try download.write(to: dmgURL, options: [.atomic])
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.stagingFailed
        }

        let mountResult = try commands.run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", "-readonly", "-nobrowse", "-mountpoint", mountURL.path, dmgURL.path]
        )
        guard mountResult.status == 0 else { throw UpdateError.mountFailed }
        mounted = true

        let stagedURL = mountURL.appendingPathComponent("Focusdoro.app", isDirectory: true)
        guard let stagedBundle = Bundle(url: stagedURL),
              stagedBundle.bundleIdentifier == expectedBundleIdentifier else {
            throw UpdateError.invalidBundle
        }
        guard stagedBundle.object(forInfoDictionaryKey: "FocusdoroBuildCommit") as? String == release.commitSHA else {
            throw UpdateError.invalidCommit
        }
        let signature = try commands.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", stagedURL.path]
        )
        guard signature.status == 0 else { throw UpdateError.invalidSignature }

        do {
            try fileManager.copyItem(at: stagedURL, to: replacementURL)
            guard let copiedBundle = Bundle(url: replacementURL),
                  copiedBundle.bundleIdentifier == expectedBundleIdentifier else {
                throw UpdateError.invalidBundle
            }
            guard copiedBundle.object(forInfoDictionaryKey: "FocusdoroBuildCommit") as? String == release.commitSHA else {
                throw UpdateError.invalidCommit
            }
            let copiedSignature = try commands.run(
                executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--deep", "--strict", "--verbose=2", replacementURL.path]
            )
            guard copiedSignature.status == 0 else { throw UpdateError.invalidSignature }
            try UpdateReplacementHelper.script.write(to: helperURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.stagingFailed
        }

        // Detach before handing root to helper. Helper receives paths only as positional
        // arguments; release metadata never enters shell source or interpolation.
        let detach = try commands.run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["detach", mountURL.path]
        )
        guard detach.status == 0 else { throw UpdateError.mountFailed }
        mounted = false

        do {
            try commands.launchDetached(
                executable: URL(fileURLWithPath: "/usr/bin/nohup"),
                arguments: [
                    "/bin/sh", helperURL.path, String(processIdentifier), currentAppURL.path,
                    replacementURL.path, backupURL.path, root.path
                ]
            )
            handedToHelper = true
            installationHandedOff = true
        } catch {
            throw UpdateError.helperFailed
        }
    }
}
