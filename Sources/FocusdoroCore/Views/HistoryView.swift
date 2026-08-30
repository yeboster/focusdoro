import SwiftUI

/// Sections 7–8 of the popover order. All values come from the local Core Data store,
/// so this renders with no network round trip (acceptance criterion 10).
public struct HistoryView: View {
    @Bindable var model: AppModel
    /// Weekday labels follow the same calendar the store bucketed the week with.
    private let calendar: Calendar = .current

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            statsRow
            partialNote
            weekSection
            recentSection
        }
    }

    // MARK: - Three compact columns

    @ViewBuilder
    private var partialNote: some View {
        if model.todaySummary.partialMinutes > 0 {
            Text("Includes \(model.todaySummary.partialMinutes) min from \(model.todaySummary.abandonedFocusSessions) stopped session\(model.todaySummary.abandonedFocusSessions == 1 ? "" : "s").")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            // Today counts every minute focused, including the ones from sessions the
            // user stopped early: that time was still invested.
            stat(value: "\(model.todaySummary.investedMinutes)", unit: "min", label: "Today")
            divider
            stat(value: "\(model.todaySummary.completedFocusSessions)", unit: nil, label: "Sessions")
            divider
            stat(value: "\(model.todaySummary.streakDays)", unit: model.todaySummary.streakDays == 1 ? "day" : "days", label: "Streak")
        }
        .padding(.vertical, Theme.Space.s + 2)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Palette.cardStroke)
            .frame(width: 1, height: 26)
    }

    private func stat(value: String, unit: String?, label: String) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(Theme.Font.statValue)
                if let unit {
                    Text(unit).font(Theme.Font.meta).foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .foregroundStyle(Theme.Palette.textPrimary)
            Text(label)
                .font(Theme.Font.statLabel)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value) \(unit ?? "")")
    }


    // MARK: - This week

    /// Seven bars plus the projects the week went into. Everything is local, so this
    /// renders offline exactly like the today stats above it.
    @ViewBuilder
    private var weekSection: some View {
        if !model.weeklySummary.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel("This week")
                    Spacer()
                    Text("\(model.weeklySummary.investedMinutes) min · \(model.weeklySummary.completedFocusSessions) session\(model.weeklySummary.completedFocusSessions == 1 ? "" : "s")")
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    weekChart
                    if !model.weeklySummary.projects.isEmpty {
                        Rectangle()
                            .fill(Theme.Palette.cardStroke)
                            .frame(height: 1)
                        projectBreakdown
                    }
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
            }
        }
    }

    private var weekChart: some View {
        let summary = model.weeklySummary
        let heights = WeeklyStats.barHeights(for: summary, maxHeight: Self.chartHeight)
        let initials = WeeklyStats.dayInitials(for: summary, calendar: calendar)
        let busiest = summary.busiestDay?.date
        return HStack(alignment: .bottom, spacing: Theme.Space.s) {
            ForEach(Array(summary.days.enumerated()), id: \.element.id) { index, day in
                VStack(spacing: 5) {
                    // Bars grow from a common baseline, so the empty days still occupy
                    // their slot and the week keeps its shape.
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .frame(height: Self.chartHeight)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(day.date == busiest ? Theme.Palette.accent : Theme.Palette.accent.opacity(0.45))
                            .frame(height: heights.indices.contains(index) ? heights[index] : 0)
                    }
                    Text(initials.indices.contains(index) ? initials[index] : "")
                        .font(Theme.Font.statLabel)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Self.dayFormatter.string(from: day.date)): \(day.minutes) minutes")
            }
        }
    }

    private var projectBreakdown: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Three rows: enough to see where the week went, short enough that the
            // popover does not need another scroll view.
            ForEach(model.weeklySummary.projects.prefix(3)) { project in
                HStack(spacing: Theme.Space.s) {
                    Text(project.name)
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Theme.Space.s)
                    Text("\(project.minutes) min")
                        .font(Theme.Font.meta.monospacedDigit())
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private static let chartHeight: CGFloat = 34

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    // MARK: - Recent sessions

    @ViewBuilder
    private var recentSection: some View {
        if !model.recentSessions.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionLabel("Recent sessions")
                VStack(spacing: 1) {
                    ForEach(model.recentSessions.prefix(4), id: \.id) { session in
                        SessionRow(session: session) {
                            Task { await model.retryComment(sessionID: session.id) }
                        }
                    }
                }
                .cardSurface()
            }
        }
    }
}

struct SessionRow: View {
    let session: SessionRecord
    let onRetry: () -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 14)

            Text(session.taskTitleSnapshot.isEmpty ? session.kind.displayName : session.taskTitleSnapshot)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: Theme.Space.xs)

            if session.todoistCommentStatus == .failed {
                Button("Retry comment", action: onRetry)
                    .buttonStyle(QuietButtonStyle())
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.warning)
            }

            Text("\(CommentFormatter.minutes(forElapsedSeconds: Int(session.elapsedDurationSeconds)))m")
                .font(Theme.Font.meta.monospacedDigit())
                .foregroundStyle(Theme.Palette.textTertiary)

            if let endedAt = session.endedAt {
                Text(Self.timeFormatter.string(from: endedAt))
                    .font(Theme.Font.meta.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var icon: String {
        switch session.status {
        case .completed: return session.kind == .focus ? "checkmark.circle.fill" : "cup.and.saucer.fill"
        case .abandoned: return "xmark.circle.fill"
        case .interrupted: return "exclamationmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch session.status {
        case .completed: return session.kind == .focus ? Theme.Palette.success : Theme.Palette.textTertiary
        case .abandoned: return Theme.Palette.textTertiary
        case .interrupted, .failed: return Theme.Palette.warning
        }
    }

    private var accessibilityDescription: String {
        let minutes = CommentFormatter.minutes(forElapsedSeconds: Int(session.elapsedDurationSeconds))
        let title = session.taskTitleSnapshot.isEmpty ? session.kind.displayName : session.taskTitleSnapshot
        var text = "\(session.status.rawValue) \(session.kind.displayName), \(title), \(minutes) minutes"
        if session.todoistCommentStatus == .failed { text += ", Todoist comment failed" }
        return text
    }
}
