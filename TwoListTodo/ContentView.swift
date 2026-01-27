import Combine
import SwiftUI
import UserNotifications

private enum WorkingStatus: String, CaseIterable, Identifiable, Codable {
    case active = "Active"
    case onHold = "On Hold"

    var id: String { rawValue }
}

private struct IdeaItem: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var detail: String
}

private struct ProjectItem: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var detail: String
    var status: WorkingStatus = .active
}

private struct TaskItem: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var priority: Int
    var dueDate: Date?
    var estimatedMinutes: Int? = nil
    var status: WorkingStatus = .active
    var createdAt: Date = Date()
    var lastPriorityBumpDate: Date = Date()
    var dependencyID: UUID? = nil
    var lastWorkedAt: Date? = nil
    var scheduledDate: Date? = nil
    var seriesID: UUID? = nil
}

private enum AppTab: String, CaseIterable, Identifiable, Codable {
    case ideas = "Ideas"
    case tasks = "Tasks"
    case projects = "Projects"
    case guide = "Guide"

    var id: String { rawValue }
}

private enum RecurrenceFrequency: String, CaseIterable, Identifiable, Codable {
    case everyDays = "Every X Days"
    case weekly = "Weekly"

    var id: String { rawValue }
}

private enum Weekday: String, CaseIterable, Identifiable, Codable {
    case sunday = "Sunday"
    case monday = "Monday"
    case tuesday = "Tuesday"
    case wednesday = "Wednesday"
    case thursday = "Thursday"
    case friday = "Friday"
    case saturday = "Saturday"

    var id: String { rawValue }

    var calendarValue: Int {
        switch self {
        case .sunday: return 1
        case .monday: return 2
        case .tuesday: return 3
        case .wednesday: return 4
        case .thursday: return 5
        case .friday: return 6
        case .saturday: return 7
        }
    }
}

private struct RecurringSeries: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var priority: Int = 3
    var frequency: RecurrenceFrequency
    var intervalDays: Int = 2
    var weeklyDays: Set<Weekday> = []
    var dueDateOffsetDays: Int? = nil
    var lastGeneratedDate: Date = Date()
}

private struct AppState: Codable {
    var selectedTab: AppTab = .ideas
    var ideas: [IdeaItem] = []
    var projects: [ProjectItem] = []
    var tasks: [TaskItem] = []
    var scheduledTasks: [TaskItem] = []
    var tasksSeries: [RecurringSeries] = []
}

private final class AppStatePersistence {
    static let shared = AppStatePersistence()

    private let localKey = "TwoListTodoStateLocal"

    func load() -> AppState? {
        guard let data = UserDefaults.standard.data(forKey: localKey) else { return nil }
        return decode(from: data)
    }

    func save(_ state: AppState) {
        guard let data = encode(state) else { return }
        UserDefaults.standard.set(data, forKey: localKey)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: localKey)
    }

    private func encode(_ state: AppState) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(state)
    }

    private func decode(from data: Data) -> AppState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AppState.self, from: data)
    }
}

@MainActor
private final class AppStateStore: ObservableObject {
    @Published var selectedTab: AppTab = .ideas
    @Published var ideas: [IdeaItem] = []
    @Published var projects: [ProjectItem] = []
    @Published var tasks: [TaskItem] = []
    @Published var scheduledTasks: [TaskItem] = []
    @Published var tasksSeries: [RecurringSeries] = []

    private var cancellables: Set<AnyCancellable> = []

    init() {
        load()
        autosaveChanges()
    }

    func snapshot() -> AppState {
        AppState(
            selectedTab: selectedTab,
            ideas: ideas,
            projects: projects,
            tasks: tasks,
            scheduledTasks: scheduledTasks,
            tasksSeries: tasksSeries
        )
    }

    func apply(_ state: AppState) {
        selectedTab = state.selectedTab
        ideas = state.ideas
        projects = state.projects
        tasks = state.tasks
        scheduledTasks = state.scheduledTasks
        tasksSeries = state.tasksSeries
    }

    func save() {
        AppStatePersistence.shared.save(snapshot())
    }

    func reset() {
        apply(AppState())
        AppStatePersistence.shared.clear()
        save()
    }

    private func load() {
        guard let state = AppStatePersistence.shared.load() else { return }
        apply(state)
    }

    private func autosaveChanges() {
        objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.save()
            }
            .store(in: &cancellables)
    }
}

struct ContentView: View {
    @StateObject private var store = AppStateStore()

    @State private var showingAddIdeaSheet = false
    @State private var showingAddTaskSheet = false
    @State private var showingSeriesSheet = false
    @State private var showingScheduledSheet = false
    @State private var editingIdea: IdeaItem? = nil
    @State private var editingTask: TaskItem? = nil
    @State private var editingScheduledTask: TaskItem? = nil
    @State private var showingResetAlert = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Tabs", selection: $store.selectedTab) {
                    ForEach(AppTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                Group {
                    switch store.selectedTab {
                    case .ideas:
                        IdeasListView(
                            ideas: store.ideas,
                            onMoveToProject: moveIdeaToProject,
                            onDelete: deleteIdeas,
                            onDeleteItem: deleteIdea,
                            onEdit: { editingIdea = $0 },
                            onAddTapped: { showingAddIdeaSheet = true }
                        )
                    case .tasks:
                        TasksListView(
                            tasks: $store.tasks,
                            onComplete: completeTask,
                            onAddTapped: { showingAddTaskSheet = true },
                            onShowSeries: { showingSeriesSheet = true },
                            onShowScheduled: { showingScheduledSheet = true },
                            onEdit: { editingTask = $0 },
                            onDelete: deleteTask
                        )
                    case .projects:
                        ProjectsView(
                            projects: $store.projects,
                            onComplete: completeProject
                        )
                    case .guide:
                        GuideView(
                            tasks: $store.tasks,
                            projects: $store.projects,
                            onCompleteTask: completeTask,
                            onMarkWorked: markTaskWorked,
                            onHoldTask: holdTask,
                            onCompleteProject: completeProject
                        )
                    }
                }
            }
            .navigationTitle("Two-List Todo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            showingResetAlert = true
                        } label: {
                            Label("Reset all data", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("App options")
                }
            }
            .sheet(isPresented: $showingAddIdeaSheet) {
                AddIdeaSheet { idea in
                    store.ideas.insert(idea, at: 0)
                }
            }
            .sheet(isPresented: $showingAddTaskSheet) {
                AddTaskSheet { task, scheduleOnly in
                    addTask(task, scheduleOnly: scheduleOnly)
                }
            }
            .sheet(isPresented: $showingSeriesSheet) {
                RecurringSeriesView(series: $store.tasksSeries, tasks: $store.tasks)
            }
            .sheet(isPresented: $showingScheduledSheet) {
                ScheduledTasksView(
                    scheduledTasks: $store.scheduledTasks,
                    onEdit: { editingScheduledTask = $0 }
                )
            }
            .sheet(item: $editingIdea) { idea in
                EditIdeaSheet(idea: idea) { updated in
                    updateIdea(updated)
                }
            }
            .sheet(item: $editingTask) { task in
                EditTaskSheet(task: task) { updated in
                    updateTask(updated)
                }
            }
            .sheet(item: $editingScheduledTask) { task in
                EditTaskSheet(task: task) { updated in
                    updateScheduledTask(updated)
                }
            }
            .alert("Reset all data?", isPresented: $showingResetAlert) {
                Button("Reset", role: .destructive) {
                    store.reset()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes all tasks, ideas, work area items, and recurring series from this device.")
            }
            .onAppear {
                NotificationManager.shared.requestAuthorization()
                NotificationManager.shared.scheduleDailyReminders()
                processScheduledTasks()
                processRecurringSeries()
                updateTaskPriorities()
            }
            .onChange(of: scenePhase) { newValue in
                if newValue == .active {
                    processScheduledTasks()
                    processRecurringSeries()
                    updateTaskPriorities()
                }
            }
        }
    }
    private func addTask(_ task: TaskItem, scheduleOnly: Bool) {
        if scheduleOnly {
            store.scheduledTasks.insert(task, at: 0)
        } else {
            store.tasks.insert(task, at: 0)
        }
    }

    private func addSeriesItem(_ series: RecurringSeries, to items: inout [TaskItem], generationDate: Date = Date()) {
        if items.contains(where: { $0.seriesID == series.id }) { return }
        let dueDate = series.dueDateOffsetDays.flatMap { offset in
            Calendar.current.date(byAdding: .day, value: offset, to: generationDate)
        }
        let newItem = TaskItem(
            title: series.title,
            priority: series.priority,
            dueDate: dueDate,
            status: .active,
            createdAt: generationDate,
            lastPriorityBumpDate: generationDate,
            seriesID: series.id
        )
        items.insert(newItem, at: 0)
    }

    private func deleteIdeas(at offsets: IndexSet) {
        store.ideas.remove(atOffsets: offsets)
    }

    private func deleteIdea(_ idea: IdeaItem) {
        store.ideas.removeAll { $0.id == idea.id }
    }

    private func deleteTask(_ task: TaskItem) {
        store.tasks.removeAll { $0.id == task.id }
        store.scheduledTasks.removeAll { $0.id == task.id }
    }

    private func updateIdea(_ idea: IdeaItem) {
        guard let index = store.ideas.firstIndex(where: { $0.id == idea.id }) else { return }
        store.ideas[index] = idea
    }

    private func updateTask(_ task: TaskItem) {
        guard let index = store.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        if task.scheduledDate != nil {
            store.tasks.remove(at: index)
            store.scheduledTasks.insert(task, at: 0)
        } else {
            store.tasks[index] = task
        }
    }

    private func updateScheduledTask(_ task: TaskItem) {
        guard let index = store.scheduledTasks.firstIndex(where: { $0.id == task.id }) else { return }
        if task.scheduledDate == nil {
            store.scheduledTasks.remove(at: index)
            store.tasks.insert(task, at: 0)
        } else {
            store.scheduledTasks[index] = task
        }
    }

    private func moveIdeaToProject(_ idea: IdeaItem) {
        guard let index = store.ideas.firstIndex(where: { $0.id == idea.id }) else { return }
        let item = store.ideas.remove(at: index)
        store.projects.insert(ProjectItem(title: item.title, detail: item.detail), at: 0)
    }

    private func completeTask(_ task: TaskItem) {
        store.tasks.removeAll { $0.id == task.id }
        activateDependentTasks(for: task)
    }

    private func markTaskWorked(_ task: TaskItem) {
        guard let index = store.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        store.tasks[index].lastWorkedAt = Date()
    }

    private func holdTask(_ task: TaskItem) {
        guard let index = store.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        store.tasks[index].status = .onHold
    }

    private func activateDependentTasks(for completedTask: TaskItem) {
        for index in store.tasks.indices {
            if store.tasks[index].dependencyID == completedTask.id {
                store.tasks[index].dependencyID = nil
                store.tasks[index].status = .active
            }
        }
    }

    private func completeProject(_ project: ProjectItem) {
        store.projects.removeAll { $0.id == project.id }
    }

    private func processRecurringSeries() {
        processRecurringSeries(for: &store.tasksSeries, items: &store.tasks)
    }

    private func processScheduledTasks() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let indicesToMove = store.scheduledTasks.enumerated().compactMap { index, item -> Int? in
            guard let scheduledDate = item.scheduledDate else { return nil }
            return calendar.startOfDay(for: scheduledDate) <= today ? index : nil
        }

        guard !indicesToMove.isEmpty else { return }

        for index in indicesToMove.sorted(by: >) {
            var item = store.scheduledTasks.remove(at: index)
            item.scheduledDate = nil
            item.status = .active
            store.tasks.insert(item, at: 0)
        }
    }

    private func updateTaskPriorities() {
        let calendar = Calendar.current
        let now = Date()
        for index in store.tasks.indices {
            if store.tasks[index].priority >= 5 {
                continue
            }
            let lastBump = store.tasks[index].lastPriorityBumpDate
            guard let months = calendar.dateComponents([.month], from: lastBump, to: now).month,
                  months > 0 else { continue }
            let cappedPriority = min(store.tasks[index].priority + months, 4)
            store.tasks[index].priority = cappedPriority
            if let nextBumpDate = calendar.date(byAdding: .month, value: months, to: lastBump) {
                store.tasks[index].lastPriorityBumpDate = nextBumpDate
            }
        }
    }

    private func processRecurringSeries(
        for seriesList: inout [RecurringSeries],
        items: inout [TaskItem]
    ) {
        let now = Date()
        let calendar = Calendar.current
        for index in seriesList.indices {
            let series = seriesList[index]
            guard let nextDate = nextOccurrence(for: series, calendar: calendar) else { continue }
            if calendar.startOfDay(for: nextDate) <= calendar.startOfDay(for: now) {
                if items.contains(where: { $0.seriesID == series.id }) {
                    NotificationManager.shared.sendSeriesPendingReminder(
                        title: series.title,
                        seriesID: series.id
                    )
                } else {
                    addSeriesItem(series, to: &items, generationDate: now)
                    seriesList[index].lastGeneratedDate = now
                }
            }
        }
    }

    private func nextOccurrence(for series: RecurringSeries, calendar: Calendar) -> Date? {
        switch series.frequency {
        case .everyDays:
            let interval = max(series.intervalDays, 1)
            return calendar.date(byAdding: .day, value: interval, to: calendar.startOfDay(for: series.lastGeneratedDate))
        case .weekly:
            guard !series.weeklyDays.isEmpty else { return nil }
            let start = calendar.startOfDay(for: series.lastGeneratedDate)
            var nextDate: Date? = nil
            for offset in 1...7 {
                guard let candidate = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
                let weekday = calendar.component(.weekday, from: candidate)
                if series.weeklyDays.contains(where: { $0.calendarValue == weekday }) {
                    nextDate = candidate
                    break
                }
            }
            return nextDate
        }
    }
}

private struct IdeasListView: View {
    let ideas: [IdeaItem]
    let onMoveToProject: (IdeaItem) -> Void
    let onDelete: (IndexSet) -> Void
    let onDeleteItem: (IdeaItem) -> Void
    let onEdit: (IdeaItem) -> Void
    let onAddTapped: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List {
                Section {
                    if ideas.isEmpty {
                        if #available(iOS 17.0, *) {
                            ContentUnavailableView("No ideas yet", systemImage: "lightbulb")
                        } else {
                            UnavailableContentView(title: "No ideas yet", systemImage: "lightbulb")
                        }
                    }
                    ForEach(ideas) { idea in
                        IdeaRow(idea: idea)
                            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                                if value.translation.width > 120, abs(value.translation.width) > abs(value.translation.height) {
                                    onMoveToProject(idea)
                                }
                            })
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    onEdit(idea)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)

                                Button(role: .destructive) {
                                    onDeleteItem(idea)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete(perform: onDelete)
                } header: {
                    Text("Ideas")
                }
            }
            .listStyle(.insetGrouped)

            Button {
                onAddTapped()
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding()
                    .background(Circle().fill(Color.accentColor))
                    .shadow(radius: 4)
            }
            .accessibilityLabel("Add idea")
            .padding()
        }
    }
}

private struct TasksListView: View {
    @Binding var tasks: [TaskItem]
    let onComplete: (TaskItem) -> Void
    let onAddTapped: () -> Void
    let onShowSeries: () -> Void
    let onShowScheduled: () -> Void
    let onEdit: (TaskItem) -> Void
    let onDelete: (TaskItem) -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List {
                Section {
                    if tasks.isEmpty {
                        if #available(iOS 17.0, *) {
                            ContentUnavailableView("No tasks yet", systemImage: "checklist")
                        } else {
                            UnavailableContentView(title: "No tasks yet", systemImage: "checklist")
                        }
                    }
                    ForEach(sortedTaskIndices, id: \.self) { index in
                        TaskRow(
                            task: $tasks[index],
                            allTasks: tasks,
                            onComplete: onComplete
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                onEdit(tasks[index])
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)

                            Button(role: .destructive) {
                                onDelete(tasks[index])
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Tasks")
                }
            }
            .listStyle(.insetGrouped)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            onShowSeries()
                        } label: {
                            Label("Recurring tasks", systemImage: "repeat")
                        }

                        Button {
                            onShowScheduled()
                        } label: {
                            Label("Scheduled tasks", systemImage: "calendar")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Task options")
                }
            }

            Button {
                onAddTapped()
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding()
                    .background(Circle().fill(Color.accentColor))
                    .shadow(radius: 4)
            }
            .accessibilityLabel("Add task")
            .padding()
        }
    }

    private var sortedTaskIndices: [Int] {
        tasks.indices.sorted { lhs, rhs in
            taskSortComparator(tasks[lhs], tasks[rhs])
        }
    }
}

private struct ProjectsView: View {
    @Binding var projects: [ProjectItem]
    let onComplete: (ProjectItem) -> Void

    var body: some View {
        List {
            Section {
                if projects.isEmpty {
                    if #available(iOS 17.0, *) {
                        ContentUnavailableView("No project items yet", systemImage: "tray")
                    } else {
                        UnavailableContentView(title: "No project items yet", systemImage: "tray")
                    }
                }
                ForEach($projects) { $project in
                    ProjectRow(project: $project, onComplete: onComplete)
                }
            } header: {
                Text("Projects")
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct GuideView: View {
    @Binding var tasks: [TaskItem]
    @Binding var projects: [ProjectItem]
    let onCompleteTask: (TaskItem) -> Void
    let onMarkWorked: (TaskItem) -> Void
    let onHoldTask: (TaskItem) -> Void
    let onCompleteProject: (ProjectItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let task = topTask {
                    GuideTaskCard(task: task)

                    HStack(spacing: 12) {
                        Button {
                            onCompleteTask(task)
                        } label: {
                            Label("Complete", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            onMarkWorked(task)
                        } label: {
                            Label("Worked", systemImage: "bolt.fill")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            onHoldTask(task)
                        } label: {
                            Label("On Hold", systemImage: "pause.circle")
                        }
                        .buttonStyle(.bordered)
                    }

                    if task.dueDate == nil, task.priority < 5 {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Projects")
                                .font(.headline)
                            if projects.isEmpty {
                                Text("No project items ready.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(projects) { project in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(project.title)
                                                .font(.subheadline.weight(.semibold))
                                            if !project.detail.isEmpty {
                                                Text(project.detail)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Button {
                                            onCompleteProject(project)
                                        } label: {
                                            Image(systemName: "checkmark.circle")
                                        }
                                        .buttonStyle(.bordered)
                                        .accessibilityLabel("Complete project item")
                                    }
                                    .padding(.vertical, 6)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                } else {
                    if #available(iOS 17.0, *) {
                        ContentUnavailableView("No tasks ready", systemImage: "sparkles")
                    } else {
                        UnavailableContentView(title: "No tasks ready", systemImage: "sparkles")
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Lowest hanging fruit")
                        .font(.headline)
                    if let quickTask = lowestHangingFruit {
                        GuideTaskCard(task: quickTask)

                        HStack(spacing: 12) {
                            Button {
                                onCompleteTask(quickTask)
                            } label: {
                                Label("Complete", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                onHoldTask(quickTask)
                            } label: {
                                Label("On Hold", systemImage: "pause.circle")
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Text("No quick wins with estimated times yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var topTask: TaskItem? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return availableTasks.sorted(by: taskSortComparator).first
    }

    private var availableTasks: [TaskItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return tasks.filter { task in
            guard task.status == .active else { return false }
            if let workedAt = task.lastWorkedAt {
                return calendar.startOfDay(for: workedAt) != today
            }
            return true
        }
    }

    private var lowestHangingFruit: TaskItem? {
        availableTasks
            .filter { $0.estimatedMinutes != nil }
            .sorted { left, right in
                guard let leftMinutes = left.estimatedMinutes,
                      let rightMinutes = right.estimatedMinutes else { return false }
                if leftMinutes != rightMinutes {
                    return leftMinutes < rightMinutes
                }
                return taskSortComparator(left, right)
            }
            .first
    }
}

private struct UnavailableContentView: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }
}

private struct IdeaRow: View {
    let idea: IdeaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(idea.title)
                .font(.headline)
            if !idea.detail.isEmpty {
                Text(idea.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct TaskRow: View {
    @Binding var task: TaskItem
    let allTasks: [TaskItem]
    let onComplete: (TaskItem) -> Void

    @State private var isExpanded = false
    @State private var showDueDatePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.headline)
                        .foregroundStyle(task.status == .onHold ? .secondary : .primary)
                    HStack(spacing: 8) {
                        Label("P\(task.priority)", systemImage: "flag.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(task.status == .onHold ? .tertiary : .secondary)
                        if let estimatedMinutes = task.estimatedMinutes {
                            Label("\(estimateDescription(estimatedMinutes))", systemImage: "hourglass")
                                .font(.caption)
                                .foregroundStyle(task.status == .onHold ? .tertiary : .secondary)
                        } else {
                            Text("No estimate")
                                .font(.caption)
                                .foregroundStyle(task.status == .onHold ? .tertiary : .secondary)
                        }
                        if let dueDate = task.dueDate {
                            Label {
                                Text(dueDate, style: .date)
                            } icon: {
                                Image(systemName: "calendar")
                            }
                            .font(.caption)
                            .foregroundStyle(task.status == .onHold ? .tertiary : .secondary)
                        } else {
                            Text("No due date")
                                .font(.caption)
                                .foregroundStyle(task.status == .onHold ? .tertiary : .secondary)
                        }
                    }
                }

                Spacer()

                Button {
                    withAnimation {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Picker("Status", selection: $task.status) {
                ForEach(WorkingStatus.allCases) { status in
                    Text(status.rawValue).tag(status)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Button {
                    onComplete(task)
                } label: {
                    Label("Complete", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Priority", selection: $task.priority) {
                        ForEach(1...5, id: \.self) { value in
                            Text("Priority \(value)").tag(value)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("Has estimate", isOn: estimateToggle)

                    if task.estimatedMinutes != nil {
                        Stepper(
                            "Estimated time \(estimateDescription(estimateMinutesBinding.wrappedValue))",
                            value: estimateMinutesBinding,
                            in: 5...480,
                            step: 5
                        )
                    }

                    Toggle("Has due date", isOn: dueDateToggle)

                    if task.dueDate != nil {
                        Button {
                            showDueDatePicker = true
                        } label: {
                            HStack {
                                Text("Due date")
                                Spacer()
                                Text(dueDateBinding.wrappedValue, style: .date)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showDueDatePicker) {
                            DatePicker("Due date", selection: dueDateBinding, displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .onChange(of: dueDateBinding.wrappedValue) { _ in
                                    showDueDatePicker = false
                                }
                                .padding()
                        }
                    }

                    Divider()

                    Picker("Depends on", selection: dependencyBinding) {
                        Text("None").tag(nil as UUID?)
                        ForEach(allTasks.filter { $0.id != task.id }) { entry in
                            Text(entry.title).tag(Optional(entry.id))
                        }
                    }
                    .pickerStyle(.menu)

                    if task.status == .onHold, dependencyBinding.wrappedValue == nil {
                        Text("On-hold tasks can automatically resume when a dependency is completed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
        .opacity(task.status == .onHold ? 0.6 : 1)
    }

    private var dueDateToggle: Binding<Bool> {
        Binding(
            get: { task.dueDate != nil },
            set: { hasDueDate in
                if hasDueDate {
                    task.dueDate = task.dueDate ?? Date()
                } else {
                    task.dueDate = nil
                }
            }
        )
    }

    private var estimateToggle: Binding<Bool> {
        Binding(
            get: { task.estimatedMinutes != nil },
            set: { hasEstimate in
                if hasEstimate {
                    task.estimatedMinutes = task.estimatedMinutes ?? 30
                } else {
                    task.estimatedMinutes = nil
                }
            }
        )
    }

    private var estimateMinutesBinding: Binding<Int> {
        Binding(
            get: { task.estimatedMinutes ?? 30 },
            set: { task.estimatedMinutes = $0 }
        )
    }

    private var dueDateBinding: Binding<Date> {
        Binding(
            get: { task.dueDate ?? Date() },
            set: { task.dueDate = $0 }
        )
    }

    private var dependencyBinding: Binding<UUID?> {
        Binding(
            get: { task.dependencyID },
            set: { newValue in
                task.dependencyID = newValue
            }
        )
    }
}

private struct ProjectRow: View {
    @Binding var project: ProjectItem
    let onComplete: (ProjectItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.title)
                        .font(.headline)
                        .foregroundStyle(project.status == .onHold ? .secondary : .primary)
                    if !project.detail.isEmpty {
                        Text(project.detail)
                            .font(.caption)
                            .foregroundStyle(project.status == .onHold ? .tertiary : .secondary)
                    }
                }

                Spacer()

                Button {
                    onComplete(project)
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Complete project item")
            }

            Picker("Status", selection: $project.status) {
                ForEach(WorkingStatus.allCases) { status in
                    Text(status.rawValue).tag(status)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 6)
        .opacity(project.status == .onHold ? 0.6 : 1)
    }
}

private struct GuideTaskCard: View {
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title)
                .font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                Label("P\(task.priority)", systemImage: "flag.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let estimatedMinutes = task.estimatedMinutes {
                    Label(estimateDescription(estimatedMinutes), systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No estimate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let dueDate = task.dueDate {
                    Label {
                        Text(dueDate, style: .date)
                    } icon: {
                        Image(systemName: "calendar")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("No due date")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(task.status.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}

private struct AddIdeaSheet: View {
    let onAdd: (IdeaItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var detail = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Idea") {
                    TextField("Title", text: $title)
#if os(iOS)
                        .textInputAutocapitalization(.sentences)
#endif
                    TextField("Description", text: $detail, axis: .vertical)
                }
            }
            .navigationTitle("Add Idea")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onAdd(IdeaItem(title: trimmed, detail: detail.trimmingCharacters(in: .whitespacesAndNewlines)))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct EditIdeaSheet: View {
    let idea: IdeaItem
    let onSave: (IdeaItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var detail: String

    init(idea: IdeaItem, onSave: @escaping (IdeaItem) -> Void) {
        self.idea = idea
        self.onSave = onSave
        _title = State(initialValue: idea.title)
        _detail = State(initialValue: idea.detail)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Idea") {
                    TextField("Title", text: $title)
#if os(iOS)
                        .textInputAutocapitalization(.sentences)
#endif
                    TextField("Description", text: $detail, axis: .vertical)
                }
            }
            .navigationTitle("Edit Idea")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onSave(IdeaItem(id: idea.id, title: trimmed, detail: detail.trimmingCharacters(in: .whitespacesAndNewlines)))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct AddTaskSheet: View {
    let onAdd: (TaskItem, Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var priority = 3
    @State private var hasEstimate = false
    @State private var estimatedMinutes = 30
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var showDueDatePicker = false
    @State private var isScheduled = false
    @State private var scheduledDate = Date()
    @State private var showScheduledDatePicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
#if os(iOS)
                        .textInputAutocapitalization(.sentences)
#endif
                    Stepper("Priority \(priority)", value: $priority, in: 1...5)
                    Toggle("Has estimate", isOn: $hasEstimate)
                    if hasEstimate {
                        Stepper(
                            "Estimated time \(estimateDescription(estimatedMinutes))",
                            value: $estimatedMinutes,
                            in: 5...480,
                            step: 5
                        )
                    }
                    Toggle("Has due date", isOn: $hasDueDate)
                    if hasDueDate {
                        Button {
                            showDueDatePicker = true
                        } label: {
                            HStack {
                                Text("Due date")
                                Spacer()
                                Text(dueDate, style: .date)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showDueDatePicker) {
                            DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .onChange(of: dueDate) { _ in
                                    showDueDatePicker = false
                                }
                                .padding()
                        }
                    }

                    Toggle("Schedule for later", isOn: $isScheduled)
                    if isScheduled {
                        Button {
                            showScheduledDatePicker = true
                        } label: {
                            HStack {
                                Text("Scheduled date")
                                Spacer()
                                Text(scheduledDate, style: .date)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showScheduledDatePicker) {
                            DatePicker("Scheduled date", selection: $scheduledDate, displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .onChange(of: scheduledDate) { _ in
                                    showScheduledDatePicker = false
                                }
                                .padding()
                        }
                    }
                }
            }
            .navigationTitle("Add Task")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let now = Date()
                        let task = TaskItem(
                            title: trimmed,
                            priority: priority,
                            dueDate: hasDueDate ? dueDate : nil,
                            estimatedMinutes: hasEstimate ? estimatedMinutes : nil,
                            status: .active,
                            createdAt: now,
                            lastPriorityBumpDate: now,
                            scheduledDate: isScheduled ? scheduledDate : nil
                        )
                        onAdd(task, isScheduled)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct EditTaskSheet: View {
    let task: TaskItem
    let onSave: (TaskItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var priority: Int
    @State private var status: WorkingStatus
    @State private var hasEstimate: Bool
    @State private var estimatedMinutes: Int
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var showDueDatePicker = false
    @State private var isScheduled: Bool
    @State private var scheduledDate: Date
    @State private var showScheduledDatePicker = false

    init(task: TaskItem, onSave: @escaping (TaskItem) -> Void) {
        self.task = task
        self.onSave = onSave
        _title = State(initialValue: task.title)
        _priority = State(initialValue: task.priority)
        _status = State(initialValue: task.status)
        _hasEstimate = State(initialValue: task.estimatedMinutes != nil)
        _estimatedMinutes = State(initialValue: task.estimatedMinutes ?? 30)
        _hasDueDate = State(initialValue: task.dueDate != nil)
        _dueDate = State(initialValue: task.dueDate ?? Date())
        _isScheduled = State(initialValue: task.scheduledDate != nil)
        _scheduledDate = State(initialValue: task.scheduledDate ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
#if os(iOS)
                        .textInputAutocapitalization(.sentences)
#endif
                    Picker("Status", selection: $status) {
                        ForEach(WorkingStatus.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    Stepper("Priority \(priority)", value: $priority, in: 1...5)
                    Toggle("Has estimate", isOn: $hasEstimate)
                    if hasEstimate {
                        Stepper(
                            "Estimated time \(estimateDescription(estimatedMinutes))",
                            value: $estimatedMinutes,
                            in: 5...480,
                            step: 5
                        )
                    }
                    Toggle("Has due date", isOn: $hasDueDate)
                    if hasDueDate {
                        Button {
                            showDueDatePicker = true
                        } label: {
                            HStack {
                                Text("Due date")
                                Spacer()
                                Text(dueDate, style: .date)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showDueDatePicker) {
                            DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .onChange(of: dueDate) { _ in
                                    showDueDatePicker = false
                                }
                                .padding()
                        }
                    }

                    Toggle("Schedule for later", isOn: $isScheduled)
                    if isScheduled {
                        Button {
                            showScheduledDatePicker = true
                        } label: {
                            HStack {
                                Text("Scheduled date")
                                Spacer()
                                Text(scheduledDate, style: .date)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showScheduledDatePicker) {
                            DatePicker("Scheduled date", selection: $scheduledDate, displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .onChange(of: scheduledDate) { _ in
                                    showScheduledDatePicker = false
                                }
                                .padding()
                        }
                    }
                }
            }
            .navigationTitle("Edit Task")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        var updated = task
                        updated.title = trimmed
                        updated.priority = priority
                        updated.status = status
                        updated.dueDate = hasDueDate ? dueDate : nil
                        updated.estimatedMinutes = hasEstimate ? estimatedMinutes : nil
                        updated.scheduledDate = isScheduled ? scheduledDate : nil
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ScheduledTasksView: View {
    @Binding var scheduledTasks: [TaskItem]
    let onEdit: (TaskItem) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if scheduledTasks.isEmpty {
                        if #available(iOS 17.0, *) {
                            ContentUnavailableView("No scheduled tasks", systemImage: "calendar")
                        } else {
                            UnavailableContentView(title: "No scheduled tasks", systemImage: "calendar")
                        }
                    }
                    ForEach(scheduledTasks) { task in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(task.title)
                                .font(.headline)
                            HStack(spacing: 8) {
                                Label("P\(task.priority)", systemImage: "flag.fill")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let scheduledDate = task.scheduledDate {
                                    Label {
                                        Text(scheduledDate, style: .date)
                                    } icon: {
                                        Image(systemName: "clock")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                if let dueDate = task.dueDate {
                                    Label {
                                        Text(dueDate, style: .date)
                                    } icon: {
                                        Image(systemName: "calendar")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                onEdit(task)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)

                            Button(role: .destructive) {
                                scheduledTasks.removeAll { $0.id == task.id }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Scheduled Tasks")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Scheduled Tasks")
        }
    }
}

private struct RecurringSeriesView: View {
    @Binding var series: [RecurringSeries]
    @Binding var tasks: [TaskItem]

    @State private var showingAddSeries = false
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section {
                    if series.isEmpty {
                        if #available(iOS 17.0, *) {
                            ContentUnavailableView("No recurring tasks", systemImage: "repeat")
                        } else {
                            UnavailableContentView(title: "No recurring tasks", systemImage: "repeat")
                        }
                    }

                    ForEach(series) { entry in
                        NavigationLink(value: entry) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title)
                                    .font(.headline)
                                Text(seriesDescription(entry))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(seriesMeta(entry))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                navigationPath.append(entry)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)

                            Button(role: .destructive) {
                                removeSeries(entry)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { offsets in
                        removeSeries(at: offsets)
                    }

                    Button {
                        showingAddSeries = true
                    } label: {
                        Label("Add recurring task", systemImage: "repeat")
                    }
                } footer: {
                    Text("Recurring tasks generate new items on their schedule. If a previous item is still active, you'll receive a reminder instead of a duplicate.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Recurring Tasks")
            .navigationDestination(for: RecurringSeries.self) { entry in
                EditSeriesSheet(series: entry) { updated in
                    updateSeries(updated)
                }
            }
            .sheet(isPresented: $showingAddSeries) {
                AddSeriesSheet { newSeries in
                    series.append(newSeries)
                    addSeriesItem(newSeries)
                }
            }
        }
    }

    private func addSeriesItem(_ entry: RecurringSeries, generationDate: Date = Date()) {
        if tasks.contains(where: { $0.seriesID == entry.id }) { return }
        let dueDate = entry.dueDateOffsetDays.flatMap { offset in
            Calendar.current.date(byAdding: .day, value: offset, to: generationDate)
        }
        let newItem = TaskItem(
            title: entry.title,
            priority: entry.priority,
            dueDate: dueDate,
            status: .active,
            createdAt: generationDate,
            lastPriorityBumpDate: generationDate,
            seriesID: entry.id
        )
        tasks.insert(newItem, at: 0)
    }

    private func removeSeries(at offsets: IndexSet) {
        let ids = offsets.map { series[$0].id }
        series.remove(atOffsets: offsets)
        tasks.removeAll { item in
            guard let seriesID = item.seriesID else { return false }
            return ids.contains(seriesID)
        }
    }

    private func removeSeries(_ entry: RecurringSeries) {
        guard let index = series.firstIndex(where: { $0.id == entry.id }) else { return }
        removeSeries(at: IndexSet(integer: index))
    }

    private func updateSeries(_ updated: RecurringSeries) {
        guard let index = series.firstIndex(where: { $0.id == updated.id }) else { return }
        var newSeries = updated
        newSeries.lastGeneratedDate = series[index].lastGeneratedDate
        series[index] = newSeries
        let dueDate = updated.dueDateOffsetDays.flatMap { offset in
            Calendar.current.date(byAdding: .day, value: offset, to: newSeries.lastGeneratedDate)
        }
        for itemIndex in tasks.indices {
            if tasks[itemIndex].seriesID == updated.id {
                tasks[itemIndex].title = updated.title
                tasks[itemIndex].priority = updated.priority
                tasks[itemIndex].dueDate = dueDate
            }
        }
    }

    private func seriesDescription(_ entry: RecurringSeries) -> String {
        switch entry.frequency {
        case .everyDays:
            return "Every \(entry.intervalDays) days"
        case .weekly:
            let days = Weekday.allCases.filter { entry.weeklyDays.contains($0) }
                .map { $0.rawValue }
                .joined(separator: ", ")
            return "Weekly on \(days)"
        }
    }

    private func seriesMeta(_ entry: RecurringSeries) -> String {
        var parts: [String] = ["P\(entry.priority)"]
        if let offset = entry.dueDateOffsetDays {
            parts.append("Due \(offset) days after")
        } else {
            parts.append("No due date")
        }
        return parts.joined(separator: " • ")
    }
}

private func estimateDescription(_ minutes: Int) -> String {
    if minutes < 60 {
        return "\(minutes)m"
    }
    let hours = Double(minutes) / 60.0
    if minutes % 60 == 0 {
        return String(format: "%.0fh", hours)
    }
    return String(format: "%.1fh", hours)
}

private func taskSortComparator(_ left: TaskItem, _ right: TaskItem) -> Bool {
    let leftHasDue = left.dueDate != nil
    let rightHasDue = right.dueDate != nil

    if leftHasDue != rightHasDue {
        return leftHasDue && !rightHasDue
    }

    if let leftDue = left.dueDate, let rightDue = right.dueDate, leftDue != rightDue {
        return leftDue < rightDue
    }

    if left.priority != right.priority {
        return left.priority > right.priority
    }

    return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
}

private struct AddSeriesSheet: View {
    let onAdd: (RecurringSeries) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var frequency: RecurrenceFrequency = .everyDays
    @State private var priority = 3
    @State private var hasDueDate = false
    @State private var dueDateOffsetDays = 1
    @State private var intervalDays = 2
    @State private var weeklyDays: Set<Weekday> = [.monday]

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    Stepper("Priority \(priority)", value: $priority, in: 1...5)
                    Toggle("Has due date", isOn: $hasDueDate)
                    if hasDueDate {
                        Stepper("Due \(dueDateOffsetDays) days after", value: $dueDateOffsetDays, in: 0...30)
                    }
                }

                Section("Series") {
                    TextField("Title", text: $title)
#if os(iOS)
                        .textInputAutocapitalization(.sentences)
#endif
                    Picker("Frequency", selection: $frequency) {
                        ForEach(RecurrenceFrequency.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                }

                if frequency == .everyDays {
                    Section("Every X days") {
                        Stepper("Every \(intervalDays) days", value: $intervalDays, in: 1...30)
                    }
                } else {
                    Section("Weekly on") {
                        ForEach(Weekday.allCases) { day in
                            Toggle(day.rawValue, isOn: Binding(
                                get: { weeklyDays.contains(day) },
                                set: { isOn in
                                    if isOn {
                                        weeklyDays.insert(day)
                                    } else {
                                        weeklyDays.remove(day)
                                    }
                                }
                            ))
                        }
                    }
                }
            }
            .navigationTitle("Add Recurring Series")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        var series = RecurringSeries(title: trimmed, frequency: frequency)
                        series.priority = priority
                        series.dueDateOffsetDays = hasDueDate ? dueDateOffsetDays : nil
                        if frequency == .everyDays {
                            series.intervalDays = intervalDays
                        } else {
                            series.weeklyDays = weeklyDays
                        }
                        series.lastGeneratedDate = Date()
                        onAdd(series)
                        dismiss()
                    }
                    .disabled(isAddDisabled)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var isAddDisabled: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return true
        }
        if frequency == .weekly {
            return weeklyDays.isEmpty
        }
        return false
    }
}

private struct EditSeriesSheet: View {
    let series: RecurringSeries
    let onSave: (RecurringSeries) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var frequency: RecurrenceFrequency
    @State private var priority: Int
    @State private var hasDueDate: Bool
    @State private var dueDateOffsetDays: Int
    @State private var intervalDays: Int
    @State private var weeklyDays: Set<Weekday>

    init(series: RecurringSeries, onSave: @escaping (RecurringSeries) -> Void) {
        self.series = series
        self.onSave = onSave
        _title = State(initialValue: series.title)
        _frequency = State(initialValue: series.frequency)
        _priority = State(initialValue: series.priority)
        _hasDueDate = State(initialValue: series.dueDateOffsetDays != nil)
        _dueDateOffsetDays = State(initialValue: series.dueDateOffsetDays ?? 1)
        _intervalDays = State(initialValue: series.intervalDays)
        _weeklyDays = State(initialValue: series.weeklyDays)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    Stepper("Priority \(priority)", value: $priority, in: 1...5)
                    Toggle("Has due date", isOn: $hasDueDate)
                    if hasDueDate {
                        Stepper("Due \(dueDateOffsetDays) days after", value: $dueDateOffsetDays, in: 0...30)
                    }
                }

                Section("Series") {
                    TextField("Title", text: $title)
#if os(iOS)
                        .textInputAutocapitalization(.sentences)
#endif
                    Picker("Frequency", selection: $frequency) {
                        ForEach(RecurrenceFrequency.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                }

                if frequency == .everyDays {
                    Section("Every X days") {
                        Stepper("Every \(intervalDays) days", value: $intervalDays, in: 1...30)
                    }
                } else {
                    Section("Weekly on") {
                        ForEach(Weekday.allCases) { day in
                            Toggle(day.rawValue, isOn: Binding(
                                get: { weeklyDays.contains(day) },
                                set: { isOn in
                                    if isOn {
                                        weeklyDays.insert(day)
                                    } else {
                                        weeklyDays.remove(day)
                                    }
                                }
                            ))
                        }
                    }
                }
            }
            .navigationTitle("Edit Recurring Series")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        var updated = series
                        updated.title = trimmed
                        updated.frequency = frequency
                        updated.priority = priority
                        updated.dueDateOffsetDays = hasDueDate ? dueDateOffsetDays : nil
                        if frequency == .everyDays {
                            updated.intervalDays = intervalDays
                            updated.weeklyDays = []
                        } else {
                            updated.weeklyDays = weeklyDays
                        }
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(isSaveDisabled)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var isSaveDisabled: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return true
        }
        if frequency == .weekly {
            return weeklyDays.isEmpty
        }
        return false
    }
}

private final class NotificationManager {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func scheduleDailyReminders() {
        let reminders = [(hour: 6, minute: 0, identifier: "morning-reminder"),
                         (hour: 21, minute: 0, identifier: "evening-reminder")]

        center.removePendingNotificationRequests(withIdentifiers: reminders.map { $0.identifier })

        for reminder in reminders {
            var dateComponents = DateComponents()
            dateComponents.hour = reminder.hour
            dateComponents.minute = reminder.minute

            let content = UNMutableNotificationContent()
            content.title = "Review your tasks"
            content.body = "Check your tasks, projects, and ideas so your day stays on track."
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger)
            center.add(request)
        }
    }

    func sendSeriesPendingReminder(title: String, seriesID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "Recurring task still active"
        content.body = "\(title) is still in your tasks list. Complete it before the next scheduled entry."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "series-pending-\(seriesID.uuidString)", content: content, trigger: trigger)
        center.add(request)
    }
}

#Preview {
    ContentView()
}
