import Foundation

/// Client-side grouping from each task's `due.date`, evaluated in the user's local
/// calendar and time zone (spec §7). Pure and fully deterministic for tests.
public enum TaskFilter {
    public static func group(tasks: [TodoistTask], now: Date, calendar: Calendar) -> TaskGroups {
        var groups = TaskGroups()
        let today = calendar.startOfDay(for: now)

        for task in tasks {
            guard let due = task.due, let dueDay = startOfDueDay(due, calendar: calendar) else {
                groups.undated.append(task)
                continue
            }
            if dueDay < today {
                groups.overdue.append(task)
            } else if dueDay == today {
                groups.today.append(task)
            } else {
                groups.upcoming.append(task)
            }
        }

        groups.overdue.sort(by: sortByDueThenPriority)
        groups.today.sort(by: sortByDueThenPriority)
        groups.upcoming.sort(by: sortByDueThenPriority)
        groups.undated.sort { priority($0) > priority($1) }
        return groups
    }

    /// Recurring tasks expose only their next occurrence, so the same rule applies.
    /// A timed `due.datetime` is converted into the local day it falls on.
    static func startOfDueDay(_ due: TodoistDue, calendar: Calendar) -> Date? {
        if let datetime = due.datetime, let instant = parseDateTime(datetime, declaredZone: due.timezone) {
            return calendar.startOfDay(for: instant)
        }
        return parseDateOnly(due.date, calendar: calendar)
    }

    static func parseDateOnly(_ value: String, calendar: Calendar) -> Date? {
        // An all-day `YYYY-MM-DD` is a local calendar day, not an instant in UTC.
        let parts = value.split(separator: "-")
        guard parts.count >= 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2].prefix(2))
        else {
            // `due.date` may itself be an RFC3339 timestamp on timed tasks.
            if let instant = parseDateTime(value, declaredZone: nil) {
                return calendar.startOfDay(for: instant)
            }
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        return calendar.date(from: components)
    }

    static func parseDateTime(_ value: String, declaredZone: String?) -> Date? {
        let formatter = ISO8601DateFormatter()
        // Floating datetimes (no trailing `Z` or offset) are local wall-clock times.
        let hasZone = value.hasSuffix("Z") || value.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        formatter.timeZone = hasZone ? TimeZone(identifier: "UTC") : (declaredZone.flatMap(TimeZone.init(identifier:)) ?? .current)
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.date(from: value)
    }

    private static func priority(_ task: TodoistTask) -> Int { task.priority ?? 1 }

    private static func sortByDueThenPriority(_ lhs: TodoistTask, _ rhs: TodoistTask) -> Bool {
        let left = lhs.due?.date ?? ""
        let right = rhs.due?.date ?? ""
        if left != right { return left < right }
        return priority(lhs) > priority(rhs)
    }

    /// Case- and diacritic-insensitive search over every active task, ranked.
    ///
    /// A plain substring match buries the obvious answer: searching "IT" matches every
    /// task containing "edit", "with", or "commit", so "Add IT bank account" ends up far
    /// down a long list. Matches are scored — whole word first, then word prefix, then
    /// bare substring — and the caller's existing order breaks ties.
    public static func search(_ query: String, in tasks: [TodoistTask]) -> [TodoistTask] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return tasks }

        let scored = tasks.enumerated().compactMap { index, task -> (task: TodoistTask, score: Int, index: Int)? in
            guard let score = matchScore(trimmed, in: task) else { return nil }
            return (task, score, index)
        }

        return scored
            .sorted { left, right in
                left.score == right.score ? left.index < right.index : left.score > right.score
            }
            .map(\.task)
    }

    /// Higher is a better match; `nil` means the task does not match at all.
    static func matchScore(_ query: String, in task: TodoistTask) -> Int? {
        var best = 0

        if let score = fieldScore(query, in: task.content) { best = max(best, score * 4) }
        if let labels = task.labels {
            for label in labels {
                if let score = fieldScore(query, in: label) { best = max(best, score * 2) }
            }
        }
        if let description = task.description, let score = fieldScore(query, in: description) {
            best = max(best, score)
        }
        return best == 0 ? nil : best
    }

    /// 3 = whole word, 2 = start of a word, 1 = substring anywhere.
    private static func fieldScore(_ query: String, in text: String) -> Int? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard text.range(of: query, options: options) != nil else { return nil }

        let words = text.split { !$0.isLetter && !$0.isNumber }
        for word in words {
            if word.compare(query, options: options) == .orderedSame { return 3 }
        }
        for word in words {
            if word.range(of: query, options: [options, .anchored]) != nil { return 2 }
        }
        return 1
    }
}
