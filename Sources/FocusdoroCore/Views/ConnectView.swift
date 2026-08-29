import SwiftUI

/// First launch. The token goes straight to the Keychain after validation and is never
/// echoed back into any view state (spec §3).
public struct ConnectView: View {
    @Bindable var model: AppModel
    @FocusState private var tokenFieldFocused: Bool

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionLabel("Connect Todoist")
                Text("Focusdoro needs a Todoist personal API token to read your tasks, close them, and log focus time.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Todoist → Settings → Integrations → Developer → API token.")
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SecureField("Paste API token", text: $model.tokenDraft)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .focused($tokenFieldFocused)
                .padding(.horizontal, Theme.Space.s + 2)
                .frame(height: 34)
                .cardSurface(radius: Theme.Radius.chip)
                .onSubmit { Task { await model.connect() } }
                .accessibilityLabel("Todoist API token")

            Button(model.isBusy ? "Connecting…" : "Connect") {
                Task { await model.connect() }
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(model.isBusy || model.tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Text("The token is stored only in your macOS Keychain. It is never written to preferences, logs, or exported history.")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { tokenFieldFocused = true }
    }
}
