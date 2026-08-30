import SwiftUI

/// Today and overdue first, then search across every active task (spec §2). Sorting,
/// filtering, and project membership are all surfaced here; the ordering rules
/// themselves live in `TaskOrganizer`.
public struct TaskPickerView: View {
    @Bindable var model: AppModel
    @Bindable var sync: TodoistSync
    @FocusState private var searchFocused: Bool
    @Environment(\.popoverMaxHeight) private var popoverMaxHeight

    public init(model: AppModel) {
        self.model = model
        self.sync = model.sync
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            searchField
            controls
            content
        }
        // The picker is a keyboard surface first: the field takes focus on open so
        // arrows and Return work without a click.
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack {
            SectionLabel("Pick a Todoist task")
            Spacer()
            Button {
                Task { await sync.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityLabel("Refresh tasks")
            .disabled(sync.loadState == .loading)
        }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
            TextField("Search all active tasks", text: $sync.searchQuery)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .focused($searchFocused)
                // Arrow keys would otherwise move the caret inside the field; the list
                // is the more useful target while the picker is open.
                .onKeyPress(.upArrow) { model.moveHighlight(.up); return .handled }
                .onKeyPress(.downArrow) { model.moveHighlight(.down); return .handled }
                .onKeyPress(.return) {
                    Task { await model.activateHighlighted() }
                    return .handled
                }
                .onKeyPress(.escape) {
                    // First Escape drops the search, a second one the highlight; neither
                    // closes the popover, which the menu-bar item already does.
                    if sync.isSearching {
                        sync.searchQuery = ""
                    } else if model.highlightedTaskID != nil {
                        model.clearHighlight()
                    } else {
                        return .ignored
                    }
                    return .handled
                }
            if sync.isSearching {
                Button {
                    sync.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.s + 2)
        .frame(height: 32)
        .cardSurface(radius: Theme.Radius.chip)
    }

    // MARK: - Sort and filter

    private var controls: some View {
        HStack(spacing: Theme.Space.s) {
            sortMenu
            filterMenu
            Spacer(minLength: 0)
            if model.taskFilter.isActive {
                Button("Clear") { model.taskFilter = .none }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Clear filters")
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: sortBinding) {
                ForEach(TaskSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            menuLabel(icon: "arrow.up.arrow.down", text: model.taskSortOrder.title, isActive: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Sort by \(model.taskSortOrder.title)")
    }

    private var filterMenu: some View {
        Menu {
            Picker("Project", selection: projectBinding) {
                Text("All projects").tag(String?.none)
                ForEach(sync.projectsWithTasks) { project in
                    Text(project.name).tag(String?.some(project.id))
                }
            }
            .pickerStyle(.inline)

            Picker("Priority", selection: priorityBinding) {
                Text("Any priority").tag(TaskPriority.p4)
                // Highest first, and `.p4` above already covers "no minimum".
                ForEach(TaskPriority.allCases.reversed().filter(\.isFlagged)) { level in
                    Text("\(level.label) and above").tag(level)
                }
            }
            .pickerStyle(.inline)

            Toggle("Only tasks with a date", isOn: datedBinding)
        } label: {
            menuLabel(
                icon: "line.3.horizontal.decrease",
                text: model.taskFilter.summary(projectName: sync.selectedProjectName),
                isActive: model.taskFilter.isActive
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Filter tasks")
    }

    private func menuLabel(icon: String, text: String, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(Theme.Font.meta)
        }
        .foregroundStyle(isActive ? Theme.Palette.accent : Theme.Palette.textSecondary)
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 24)
        .cardSurface(radius: Theme.Radius.chip)
    }

    private var sortBinding: Binding<TaskSortOrder> {
        Binding(get: { model.taskSortOrder }, set: { model.taskSortOrder = $0 })
    }

    private var projectBinding: Binding<String?> {
        Binding(get: { model.taskFilter.projectID }, set: { model.taskFilter.projectID = $0 })
    }

    private var priorityBinding: Binding<TaskPriority> {
        Binding(get: { model.taskFilter.minimumPriority }, set: { model.taskFilter.minimumPriority = $0 })
    }

    private var datedBinding: Binding<Bool> {
        Binding(get: { model.taskFilter.hidesUndated }, set: { model.taskFilter.hidesUndated = $0 })
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch sync.loadState {
        case .loading where sync.allTasks.isEmpty:
            statusBlock(icon: "arrow.triangle.2.circlepath", title: "Loading tasks…", detail: nil, retry: false)
        case .failed(let error):
            statusBlock(
                icon: error == .unauthorized ? "key.slash" : "wifi.slash",
                title: error.userMessage,
                detail: error == .unauthorized ? "Reconnect in Settings." : "Your timer and history keep working offline.",
                retry: error != .unauthorized
            )
        case .idle where sync.allTasks.isEmpty:
            statusBlock(icon: "tray", title: "No tasks loaded yet.", detail: nil, retry: true)
        default:
            if sync.isSearching {
                let results = sync.searchResults
                if results.isEmpty {
                    statusBlock(icon: "magnifyingglass", title: "Nothing matches “\(sync.searchQuery)”.", detail: filterHint, retry: false)
                } else {
                    taskList(sections: [TaskSection(id: "results", title: "Results", tasks: results)])
                }
            } else {
                let sections = sync.sections
                if sections.isEmpty {
                    statusBlock(
                        icon: model.taskFilter.isActive ? "line.3.horizontal.decrease" : "checkmark.circle",
                        title: model.taskFilter.isActive ? "No task matches this filter." : "No active Todoist tasks.",
                        detail: model.taskFilter.isActive ? filterHint : "Nothing due — enjoy it.",
                        retry: !model.taskFilter.isActive
                    )
                } else {
                    taskList(sections: sections)
                }
            }
        }
    }

    private var filterHint: String? {
        model.taskFilter.isActive ? "A filter is hiding part of your list." : nil
    }

    private func taskList(sections: [TaskSection]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(sections) { section in
                        SectionLabel(section.title)
                            .padding(.top, Theme.Space.xs)
                        ForEach(section.tasks) { task in
                            PickerTaskRow(
                                task: task,
                                projectName: sync.projectName(id: task.projectID),
                                isProjectFiltered: model.taskFilter.projectID == task.projectID,
                                isHighlighted: model.highlightedTaskID == task.id,
                                select: { Task { await model.select(task: task) } },
                                filterByProject: {
                                    // Tapping the chip toggles the project filter.
                                    model.taskFilter.projectID = model.taskFilter.projectID == task.projectID ? nil : task.projectID
                                }
                            )
                            .id(task.id)
                        }
                    }
                }
                .padding(.bottom, Theme.Space.xs)
            }
            .frame(minHeight: min(Theme.Metric.listMinHeight, listCap), maxHeight: listCap)
            .scrollIndicators(.never)
            // Arrowing past the visible window has to bring the row along with it.
            .onChange(of: model.highlightedTaskID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var listCap: CGFloat { Theme.Metric.listCap(forPopoverHeight: popoverMaxHeight) }

    private func statusBlock(icon: String, title: String, detail: String?, retry: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(title)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                Text(detail)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            if retry {
                Button("Try again") { Task { await sync.refresh() } }
                    .buttonStyle(SecondaryActionStyle())
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// Picker row: priority flag, title, due/labels, and a project chip that filters.
/// The chip is a sibling button, not a nested one, so a tap cannot ambiguously mean
/// "start this task".
struct PickerTaskRow: View {
    let task: TodoistTask
    let projectName: String?
    let isProjectFiltered: Bool
    var isHighlighted: Bool = false
    let select: () -> Void
    let filterByProject: () -> Void

    private var priority: TaskPriority { TaskPriority(wireValue: task.priority) }

    var body: some View {
        HStack(spacing: Theme.Space.s + 2) {
            Button(action: select) {
                HStack(spacing: Theme.Space.s + 2) {
                    Image(systemName: priority.isFlagged ? "flag.fill" : "circle")
                        .font(.system(size: priority.isFlagged ? 12 : 14, weight: .regular))
                        .foregroundStyle(PickerTaskRow.color(for: priority))
                        .accessibilityLabel(priority.isFlagged ? "Priority \(priority.label)" : "No priority")

                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.content)
                            .font(Theme.Font.taskTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                        if let meta = metadata {
                            Text(meta)
                                .font(Theme.Font.meta)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Theme.Space.s)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Starts a focus session on this task")

            if let projectName {
                Button(action: filterByProject) {
                    Text(projectName)
                        .font(Theme.Font.meta)
                        .lineLimit(1)
                        .foregroundStyle(isProjectFiltered ? Theme.Palette.accent : Theme.Palette.textSecondary)
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .fill(isProjectFiltered ? Theme.Palette.accent.opacity(0.16) : Color.white.opacity(0.07))
                        )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 120)
                .accessibilityLabel("Project \(projectName)")
                .accessibilityHint(isProjectFiltered ? "Removes the project filter" : "Filters the list to this project")
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + 2)
        .frame(maxWidth: .infinity, minHeight: Theme.Metric.rowHeight, alignment: .leading)
        .cardSurface()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Palette.accent, lineWidth: isHighlighted ? 1.5 : 0)
        )
        .accessibilityAddTraits(isHighlighted ? [.isSelected] : [])
    }

    private var metadata: String? {
        var parts: [String] = []
        if let due = task.due { parts.append(due.string ?? due.date) }
        if let labels = task.labels, !labels.isEmpty { parts.append(labels.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func color(for priority: TaskPriority) -> Color {
        switch priority {
        case .p1: return Theme.Palette.danger
        case .p2: return Theme.Palette.warning
        case .p3: return Theme.Palette.accent
        case .p4: return Theme.Palette.textTertiary
        }
    }
}
