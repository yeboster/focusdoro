import Foundation

/// Pure aggregation for the week view. Kept out of `SessionStore` so the bucketing and
/// the project rollup can be tested without a Core Data stack.
public enum WeeklyStats {
    /// Buckets focus sessions into the seven days starting at `weekStart` and rolls the
    /// same sessions up per project. Sessions outside the week are ignored, so the
    /// caller's fetch predicate and this function cannot disagree.
    public static func summarize(sessions: [SessionRecord], weekStart: Date, calendar: Calendar) -> WeeklySummary {
        let start = calendar.startOfDay(for: weekStart)
        let dayStarts: [Date] = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        var totals: [Date: DayTotal] = [:]
        for day in dayStarts { totals[day] = DayTotal(date: day) }

        struct ProjectAccumulator {
            var name: String
            var seconds: Int
            var completed: Int
        }
        var projects: [String: ProjectAccumulator] = [:]

        for session in sessions {
            guard session.kind == .focus, let endedAt = session.endedAt else { continue }
            let day = calendar.startOfDay(for: endedAt)
            guard var bucket = totals[day] else { continue }
            let seconds = max(0, Int(session.elapsedDurationSeconds))
            bucket.seconds += seconds
            if session.status == .completed { bucket.completedSessions += 1 }
            totals[day] = bucket

            // A session recorded before the project snapshot existed still belongs in
            // the rollup; it lands in the "No project" row rather than disappearing.
            let key = session.projectID ?? unassignedKey
            let name = session.projectNameSnapshot ?? (session.projectID == nil ? "No project" : "Other project")
            var accumulator = projects[key] ?? ProjectAccumulator(name: name, seconds: 0, completed: 0)
            // Later sessions carry the fresher name for the same project.
            if session.projectNameSnapshot != nil { accumulator.name = name }
            accumulator.seconds += seconds
            if session.status == .completed { accumulator.completed += 1 }
            projects[key] = accumulator
        }

        let ranked = projects
            .map { key, value in
                ProjectTotal(
                    projectID: key == unassignedKey ? nil : key,
                    name: value.name,
                    seconds: value.seconds,
                    completedSessions: value.completed
                )
            }
            // Name is the tie-break so the order does not flicker between reloads.
            .sorted { lhs, rhs in
                if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
                return lhs.name < rhs.name
            }

        return WeeklySummary(
            days: dayStarts.compactMap { totals[$0] },
            projects: ranked.filter { $0.seconds > 0 },
            startOfWeek: start
        )
    }

    private static let unassignedKey = "__none__"

    /// Bar heights for the week chart, scaled against the busiest day. A day with any
    /// focus at all keeps a visible stub, so "a little" never reads as "nothing".
    public static func barHeights(for summary: WeeklySummary, maxHeight: Double, minimumVisible: Double = 3) -> [Double] {
        let peak = summary.days.map(\.seconds).max() ?? 0
        guard peak > 0, maxHeight > 0 else { return summary.days.map { _ in 0 } }
        return summary.days.map { day in
            guard day.seconds > 0 else { return 0 }
            let scaled = maxHeight * Double(day.seconds) / Double(peak)
            return max(minimumVisible, scaled)
        }
    }

    /// Single-letter weekday initials in the week's own order.
    public static func dayInitials(for summary: WeeklySummary, calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return summary.days.map { day in
            let weekday = calendar.component(.weekday, from: day.date)
            let index = weekday - 1
            return symbols.indices.contains(index) ? symbols[index] : ""
        }
    }
}
