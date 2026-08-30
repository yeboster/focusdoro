import Foundation

public enum HighlightMove: Equatable, Sendable {
    case up
    case down
    case first
    case last
}

/// Keyboard selection maths for the task picker. Pure so arrow-key behaviour is tested
/// without a window: the view only reports the visible order and renders the result.
public enum TaskHighlight {
    /// The id to highlight after `move`. Wraps at both ends, because the list is short
    /// enough that stopping dead at the bottom just feels broken.
    public static func next(_ move: HighlightMove, in ids: [String], from current: String?) -> String? {
        guard !ids.isEmpty else { return nil }
        switch move {
        case .first:
            return ids.first
        case .last:
            return ids.last
        case .up, .down:
            // An unknown or dropped highlight starts from the edge the key points at,
            // so the first arrow press always lands somewhere sensible.
            guard let current, let index = ids.firstIndex(of: current) else {
                return move == .down ? ids.first : ids.last
            }
            let offset = move == .down ? 1 : -1
            let wrapped = (index + offset + ids.count) % ids.count
            return ids[wrapped]
        }
    }

    /// Keeps a highlight only while it still exists — a search keystroke or a refresh
    /// can drop the highlighted task out of the list entirely.
    public static func resolve(current: String?, in ids: [String]) -> String? {
        guard let current, ids.contains(current) else { return ids.first }
        return current
    }
}
