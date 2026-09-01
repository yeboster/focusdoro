import CryptoKit
import Foundation
import Testing
@testable import FocusdoroCore

@Suite("Secure update service")
struct UpdateServiceTests {
    private let sha = "0123456789abcdef0123456789abcdef01234567"

    @Test("Latest GitHub release decodes immutable SHA and DMG metadata")
    func decodesRelease() throws {
        let json = """
        {
          "tag_name": "continuous-0123456789abcdef0123456789abcdef01234567",
          "assets": [{
            "name": "Focusdoro.dmg",
            "browser_download_url": "https://github.com/yeboster/focusdoro/releases/download/continuous/Focusdoro.dmg",
            "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          }]
        }
        """

        let release = try UpdateReleaseParser.decode(Data(json.utf8))

        #expect(release.commitSHA == sha)
        #expect(release.assetURL.lastPathComponent == "Focusdoro.dmg")
        #expect(release.assetDigest == "sha256:" + String(repeating: "a", count: 64))
    }

    @Test("Release tag requires exactly 40 hexadecimal SHA characters", arguments: [
        "continuous-0123456789abcdef0123456789abcdef0123456",
        "continuous-0123456789abcdef0123456789abcdef012345678",
        "continuous-0123456789abcdef0123456789abcdef0123456z",
        "v1.0.0"
    ])
    func rejectsMalformedSHA(tag: String) {
        #expect(UpdateReleaseParser.commitSHA(from: tag) == nil)
    }

    @Test("Only HTTPS exact named release asset is accepted", arguments: [
        ("http://github.com/release/Focusdoro.dmg", "Focusdoro.dmg"),
        ("https://github.com/release/focusdoro.dmg", "focusdoro.dmg"),
        ("file:///tmp/Focusdoro.dmg", "Focusdoro.dmg")
    ])
    func rejectsUnsafeAsset(urlString: String, name: String) {
        #expect(!UpdateReleaseParser.isAllowedAsset(name: name, url: URL(string: urlString)!))
    }

    @Test("Installed SHA equality and last-notified SHA suppress update")
    func updateDedupe() {
        #expect(!UpdateReleasePolicy.shouldAnnounce(remoteSHA: sha, installedSHA: sha, lastNotifiedSHA: nil))
        #expect(!UpdateReleasePolicy.shouldAnnounce(remoteSHA: sha, installedSHA: String(repeating: "f", count: 40), lastNotifiedSHA: sha))
        #expect(UpdateReleasePolicy.shouldAnnounce(remoteSHA: sha, installedSHA: String(repeating: "f", count: 40), lastNotifiedSHA: nil))
    }

    @Test("SHA-256 comparison accepts GitHub digest and rejects mismatch")
    func digestComparison() {
        let bytes = Data("verified payload".utf8)
        let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(UpdateDigest.matches(data: bytes, githubDigest: "sha256:\(hex)"))
        #expect(!UpdateDigest.matches(data: bytes, githubDigest: "sha256:" + String(repeating: "0", count: 64)))
        #expect(!UpdateDigest.matches(data: bytes, githubDigest: hex))
    }

    @Test("Redirect and response policy accepts only HTTPS success responses")
    func secureTransportPolicy() {
        #expect(UpdateTransportPolicy.allowsRedirect(to: URL(string: "https://github.com/file")!))
        #expect(!UpdateTransportPolicy.allowsRedirect(to: URL(string: "http://github.com/file")!))
        #expect(UpdateTransportPolicy.accepts(url: URL(string: "https://api.github.com/release")!, status: 200))
        #expect(!UpdateTransportPolicy.accepts(url: URL(string: "https://api.github.com/release")!, status: 404))
        #expect(!UpdateTransportPolicy.accepts(url: URL(string: "http://api.github.com/release")!, status: 200))
    }

    @Test("Replacement helper pins commands and requires rollback")
    func hardenedHelperScript() {
        let script = UpdateReplacementHelper.script
        #expect(script.contains("PATH=/usr/bin:/bin"))
        #expect(script.contains("/bin/mv"))
        #expect(script.contains("/bin/rm"))
        #expect(script.contains("/bin/sleep"))
        #expect(script.contains("/usr/bin/open"))
        #expect(script.contains("if ! /bin/mv \"$backup\" \"$current\""))
    }

    @Test("Installer errors use fixed safe copy")
    func installerErrorCopy() {
        #expect(UpdateError.digestMismatch.userMessage == "The downloaded update failed its security check.")
        #expect(UpdateError.invalidSignature.userMessage == "The downloaded update could not be verified.")
        #expect(UpdateError.unsupportedInstallLocation.userMessage == "Focusdoro can only update itself from /Applications.")
    }
}
