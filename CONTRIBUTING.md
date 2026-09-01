# Contributing

Thanks for improving Focusdoro.

## Development setup

Focusdoro requires macOS 14 or later and Swift 6 tools. Xcode is not required for local development.

```bash
make test
make build
make app
```

Use `make test`, not plain `swift test`: Command Line Tools need framework search paths supplied by the Makefile. `make app` builds an ad-hoc-signed local bundle. `make install` replaces `/Applications/Focusdoro.app`; use it only when you intend to replace installed app.

## Changes

- Keep Todoist API traffic on API v1.
- Keep Todoist tokens in Keychain only. Never commit tokens, Authorization headers, private keys, signing profiles, local databases, logs, or generated bundles.
- Test fixtures must use obvious non-working values. Never use a real credential, even revoked one.
- Add or update swift-testing coverage for behavior changes. Run `make test` and `make build` before opening pull request.
- Keep README, privacy, security, and feature specs accurate when data flow or release behavior changes.
- Preserve macOS Focus support through user-selected Shortcuts; Focusdoro has no Slack integration.

## Security reports

Do not use public issues for security bugs or secret exposure. Follow [SECURITY.md](SECURITY.md) and use GitHub private vulnerability reporting.

## License

Contributions are licensed under [MIT](LICENSE).
