# Security policy

## Supported versions

Report vulnerabilities in the latest commit on `main` and latest published Focusdoro release. Older builds are not separately supported.

## Report privately

Use GitHub private vulnerability reporting:

1. Open repository **Security** tab.
2. Open **Advisories**.
3. Select **Report a vulnerability**.

Do not open public issues, discussions, pull requests, or commits containing exploit details, API tokens, Authorization headers, private keys, or other secrets.

If a Todoist token may be exposed, revoke it in Todoist immediately, remove it from affected local copies, then include only redacted evidence in private report. Do not paste token into report.

## What to include

Include affected commit/release, macOS version, impact, reproduction steps, and proposed mitigation if known. Sanitized logs or minimal proof of concept help.

Maintainer aims to acknowledge private reports promptly and coordinate disclosure after fix is available. No response-time SLA is promised.

## Release trust boundary

Current local builds and continuous releases are ad-hoc signed. Structural signature verification and release digest checks detect corruption, but do not establish a Developer ID publisher identity. Do not treat automatic-update installation as publisher-authenticated until Developer ID signing, notarization, and signer-identity pinning ship.
