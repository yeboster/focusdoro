# Keyboard-first task picker

The picker opens with the search field focused. From there: type to narrow, ↑/↓ to move
the highlight, Return to start focusing on the highlighted task, Escape to back out.
Nothing needs the mouse.

## Pieces

| Type | File | Role |
| --- | --- | --- |
| `HighlightMove` | `Services/TaskHighlight.swift` | `up` / `down` / `first` / `last` |
| `TaskHighlight` | `Services/TaskHighlight.swift` | Pure selection maths: `next(_:in:from:)`, `resolve(current:in:)` |
| `AppModel.visibleTaskIDs` | `Services/AppModel.swift` | Flattened render order — search results, or every section's tasks |
| `AppModel.moveHighlight/activateHighlighted/clearHighlight` | `Services/AppModel.swift` | The intents the key handlers call |
| `TaskPickerView` | `Views/TaskPickerView.swift` | `onKeyPress` handlers, highlight ring, scroll-to-highlight |

## Rules

- **The visible order is the keyboard order.** `visibleTaskIDs` is built from the same
  `sync.searchResults` / `sync.sections` the list renders, so "next" can never mean a row
  the user cannot see.
- **Movement wraps.** The list is short; stopping dead at the bottom reads as broken.
- **The first press enters from the edge the key points at** — ↓ highlights the first row,
  ↑ the last.
- **A highlight that leaves the list is dropped, not resolved.** A search keystroke can
  filter the highlighted task away; the next ↓ then lands on the first *result*, not the
  second.
- **Return without a highlight takes the first row**, so type-then-Return works.
- **Escape is staged**: it clears the search, then the highlight, and never closes the
  popover — the menu-bar item already does that.
- **Clicking a row also sets the highlight**, so the keyboard resumes where the mouse left
  off.

## Why the arrow keys are handled on the text field

The search field holds focus the whole time, and a `TextField` would otherwise spend ↑/↓
moving its own caret. The handlers are attached to the field and return `.handled`, so the
keys reach the list instead. `ScrollViewReader` scrolls the highlighted row into view when
arrowing past the visible window.

## Tests

`Tests/FocusdoroCoreTests/TaskPickerKeyboardTests.swift` — the pure maths (wrapping, entry
edges, dropped highlights) plus the model-level behaviour: visible order matches the
render, Return starts a session, `start: false` selects without starting, an empty list
ignores Return, and a selection snapshots its project.
