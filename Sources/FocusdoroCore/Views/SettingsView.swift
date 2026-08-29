import AppKit
import SwiftUI

public struct SettingsView: View {
    @Bindable var model: AppModel
    /// Set while the user is recording a new shortcut for one action.
    @State private var recording: HotKeyAction?
    @State private var shortcutError: String?
    @Environment(\.popoverMaxHeight) private var popoverMaxHeight

    public init(model: AppModel) {
        self.model = model
    }

    private var preferences: Binding<AppPreferences> { $model.preferences }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                durations
                alerts
                focusMode
                shortcuts
                account
            }
            .padding(.bottom, Theme.Space.s)
        }
        .frame(minHeight: min(Theme.Metric.listMinHeight, listCap), maxHeight: listCap)
        .scrollIndicators(.never)
    }

    private var listCap: CGFloat { Theme.Metric.listCap(forPopoverHeight: popoverMaxHeight) }

    // MARK: - Section scaffolding

    /// One card per section with hairline-separated rows, so every control lands on the
    /// same right-hand edge instead of each row hugging its own content.
    private func section<Content: View>(
        _ title: String,
        footnote: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(title)
            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity)
            .cardSurface(radius: Theme.Radius.card)
            if let footnote {
                Text(footnote)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            control()
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, minHeight: Theme.Metric.settingsRowHeight)
        .accessibilityElement(children: .combine)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.Palette.cardStroke)
            .frame(height: 1)
            .padding(.leading, Theme.Space.m)
    }

    // MARK: - Durations

    private var durations: some View {
        section("Durations") {
            stepper("Focus", minutes: preferences.focusDurationSeconds, range: 1...180)
            rowDivider
            stepper("Short break", minutes: preferences.shortBreakDurationSeconds, range: 1...60)
            rowDivider
            stepper("Long break", minutes: preferences.longBreakDurationSeconds, range: 1...90)
            rowDivider
            row("Long break every") {
                value("\(model.preferences.longBreakCadence) sessions")
                // The value is drawn outside the Stepper: `.labelsHidden()` hides the
                // Stepper's own label, so a value placed inside it renders as nothing.
                Stepper("", value: preferences.longBreakCadence, in: 2...12)
                    .labelsHidden()
                    .fixedSize()
            }
        }
    }

    /// Fixed width so every value column lines up down the card.
    private func value(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.body.monospacedDigit())
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(1)
            .frame(minWidth: Theme.Metric.settingsValueWidth, alignment: .trailing)
    }

    private func stepper(_ title: String, minutes seconds: Binding<Int>, range: ClosedRange<Int>) -> some View {
        row(title) {
            value("\(seconds.wrappedValue / 60) min")
            Stepper(
                "",
                value: Binding(
                    get: { seconds.wrappedValue / 60 },
                    set: { seconds.wrappedValue = max(range.lowerBound, min(range.upperBound, $0)) * 60 }
                ),
                in: range
            )
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: - Alerts

    private var alerts: some View {
        section("Alerts") {
            toggleRow("Notification on completion", isOn: preferences.notificationsEnabled)
            rowDivider
            toggleRow("Completion sound", isOn: preferences.soundEnabled)
            if model.preferences.soundEnabled {
                rowDivider
                row("Sound") {
                    Picker("", selection: preferences.soundIdentifier) {
                        ForEach(NotificationService.availableSoundNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 132)
                    Button {
                        NSSound(named: NSSound.Name(model.preferences.soundIdentifier))?.play()
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Preview sound")
                }
            }
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        row(title) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.Palette.accent)
        }
    }

    // MARK: - Focus mode

    /// macOS has no public API for switching a Focus on, so the user points Focusdoro
    /// at their own Shortcuts. Slack needs a user token of its own.
    private var focusMode: some View {
        section(
            "Focus mode",
            footnote: "macOS Focus is switched by running your own shortcuts (Shortcuts app → new shortcut → “Set Focus”). Slack needs a user token with the dnd:write and users.profile:write scopes; it is stored only in your Keychain."
        ) {
            toggleRow("Turn on a macOS Focus", isOn: preferences.presence.macFocusEnabled)
            if model.preferences.presence.macFocusEnabled {
                rowDivider
                shortcutRow("Start shortcut", selection: preferences.presence.startShortcutName)
                rowDivider
                shortcutRow("End shortcut", selection: preferences.presence.endShortcutName)
            }
            rowDivider
            toggleRow("Pause Slack notifications", isOn: preferences.presence.slackEnabled)
            rowDivider
            row("Slack token") {
                if model.slackIsConnected {
                    Button("Remove") { model.disconnectSlack() }
                        .buttonStyle(SecondaryActionStyle())
                        .fixedSize()
                } else {
                    HStack(spacing: Theme.Space.s) {
                        SecureField("Paste user token", text: $model.slackTokenDraft)
                            .textFieldStyle(.plain)
                            .font(Theme.Font.body)
                            .frame(width: 140)
                            .onSubmit { Task { await model.connectSlack() } }
                            .accessibilityLabel("Slack user token")
                        Button("Connect") { Task { await model.connectSlack() } }
                            .buttonStyle(SecondaryActionStyle())
                            .fixedSize()
                            .disabled(model.isBusy || model.slackTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            if model.preferences.presence.slackEnabled {
                rowDivider
                toggleRow("Set Slack status", isOn: preferences.presence.slackStatusEnabled)
                if model.preferences.presence.slackStatusEnabled {
                    rowDivider
                    row("Status text") {
                        TextField("Focusing on {task}", text: preferences.presence.slackStatusTemplate)
                            .textFieldStyle(.plain)
                            .font(Theme.Font.body)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 180)
                            .accessibilityLabel("Slack status text")
                    }
                    rowDivider
                    row("Status emoji") {
                        TextField(":tomato:", text: preferences.presence.slackStatusEmoji)
                            .textFieldStyle(.plain)
                            .font(Theme.Font.body)
                            .multilineTextAlignment(.trailing)
                            .frame(width: Theme.Metric.settingsValueWidth + 20)
                            .accessibilityLabel("Slack status emoji")
                    }
                }
            }
        }
        .task { await model.loadAvailableShortcuts() }
    }

    /// The list comes from `shortcuts list`; a name saved earlier stays selectable even
    /// when the CLI is unavailable, so the setting is never silently dropped.
    private func shortcutRow(_ title: String, selection: Binding<String?>) -> some View {
        row(title) {
            Picker("", selection: selection) {
                Text("None").tag(String?.none)
                ForEach(shortcutNames(including: selection.wrappedValue), id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            .labelsHidden()
            .frame(width: 180)
        }
    }

    private func shortcutNames(including selected: String?) -> [String] {
        var names = model.availableShortcuts
        if let selected, !selected.isEmpty, !names.contains(selected) { names.insert(selected, at: 0) }
        return names
    }

    // MARK: - Shortcuts

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            section(
                "Global shortcuts",
                footnote: "Stop always opens the abandon confirmation. It never discards a session silently."
            ) {
                ForEach(Array(HotKeyAction.allCases.enumerated()), id: \.element) { index, action in
                    if index > 0 { rowDivider }
                    shortcutRow(action)
                }
            }
            if let shortcutError {
                Text(shortcutError)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shortcutRow(_ action: HotKeyAction) -> some View {
        row(action.title) {
            ShortcutRecorder(
                binding: model.preferences.bindings[action],
                isRecording: recording == action,
                onStart: { recording = action; shortcutError = nil },
                onCancel: { recording = nil },
                onCapture: { captured in
                    recording = nil
                    apply(captured, to: action)
                }
            )
            .frame(width: 108, height: 22)
        }
    }

    /// Validates the whole set before saving, so settings never claim a shortcut the
    /// service could not register (spec §9).
    private func apply(_ captured: HotKeyBinding, to action: HotKeyAction) {
        var prefs = model.preferences
        var bindings = prefs.bindings
        bindings[action] = captured
        do {
            try HotKeyService.validate(bindings)
            prefs.bindings = bindings
            model.preferences = prefs
            shortcutError = nil
            NotificationCenter.default.post(name: .focusdoroHotKeysChanged, object: nil)
        } catch let error as HotKeyError {
            shortcutError = error.userMessage
        } catch {
            shortcutError = "That shortcut could not be applied."
        }
    }

    // MARK: - Account

    private var account: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            section("Todoist account", footnote: "Stopping a session early still logs the minutes you spent on the Todoist task. Removing the token keeps every local session in your history.") {
                row("Connection") {
                    HStack(spacing: Theme.Space.s) {
                        Circle()
                            .fill(model.sync.connection == .connected ? Theme.Palette.success : Theme.Palette.warning)
                            .frame(width: 7, height: 7)
                        Text(connectionText)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                    }
                }
                rowDivider
                toggleRow("Log stopped sessions", isOn: preferences.logsAbandonedTime)
                rowDivider
                row("Token") {
                    Button("Remove") { model.confirmation = .disconnect }
                        .buttonStyle(SecondaryActionStyle())
                        .fixedSize()
                }
            }
        }
    }

    private var connectionText: String {
        switch model.sync.connection {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Not connected"
        case .tokenRejected: return "Token rejected — reconnect"
        }
    }
}

// MARK: - Shortcut recorder

public extension Notification.Name {
    static let focusdoroHotKeysChanged = Notification.Name("focusdoro.hotkeys.changed")
}

/// Captures one key-with-modifiers combination. A bare key without modifiers is
/// rejected before it reaches the service.
struct ShortcutRecorder: NSViewRepresentable {
    var binding: HotKeyBinding?
    var isRecording: Bool
    var onStart: () -> Void
    var onCancel: () -> Void
    var onCapture: (HotKeyBinding) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton()
        view.onStart = onStart
        view.onCancel = onCancel
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.onStart = onStart
        nsView.onCancel = onCancel
        nsView.onCapture = onCapture
        nsView.update(binding: binding, isRecording: isRecording)
    }

    final class RecorderButton: NSButton {
        var onStart: (() -> Void)?
        var onCancel: (() -> Void)?
        var onCapture: ((HotKeyBinding) -> Void)?
        private var isRecording = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(toggleRecording)
            setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var acceptsFirstResponder: Bool { true }

        func update(binding: HotKeyBinding?, isRecording recording: Bool) {
            isRecording = recording
            title = recording ? "Press keys…" : (binding?.displayString ?? "Not set")
            setAccessibilityLabel(recording ? "Recording shortcut" : "Shortcut \(binding?.displayString ?? "not set")")
            if recording, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        }

        @objc private func toggleRecording() {
            if isRecording { onCancel?() } else { onStart?() }
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            // Escape cancels without changing anything.
            if event.keyCode == 53 {
                onCancel?()
                return
            }
            let modifiers = HotKeyFormatter.carbonModifiers(from: event.modifierFlags)
            guard modifiers != 0 else { return }
            let keyCode = UInt32(event.keyCode)
            onCapture?(
                HotKeyBinding(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    displayString: HotKeyFormatter.displayString(keyCode: keyCode, modifiers: modifiers)
                )
            )
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }
    }
}
