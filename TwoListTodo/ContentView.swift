import Combine
import SwiftUI
import UserNotifications

private enum WorkingStatus: String, CaseIterable, Identifiable, Codable {
    case active = "Active"
    case onHold = "On Hold"

    var id: String { rawValue }
}

private struct Subtask: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var isDone = false
}

private struct TodoItem: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var priority: Int
    var dueDate: Date?
    var subtasks: [Subtask] = []
    var status: WorkingStatus? = nil
    var seriesID: UUID? = nil
}

private enum ListKind: String, Codable {
    case tasks
    case ideas
}

private enum AppTab: String, CaseIterable, Identifiable, Codable {
    case tasksList = "Tasks List"
    case ideasList = "Ideas List"
    case tasksWork = "Tasks Work"
    case ideasWork = "Ideas Work"

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
    var frequency: RecurrenceFrequency
    var intervalDays: Int = 2
    var weeklyDays: Set<Weekday> = []
    var lastGeneratedDate: Date = Date()
}

private struct AppState: Codable {
    var selectedTab: AppTab = .tasksList
    var tasks: [TodoItem] = []
    var ideas: [TodoItem] = []
    var tasksWorking: [TodoItem] = []
    var ideasWorking: [TodoItem] = []
    var tasksGraveyard: [TodoItem] = []
    var ideasGraveyard: [TodoItem] = []
    var tasksSeries: [RecurringSeries] = []
    var ideasSeries: [RecurringSeries] = []
}

private final class AppStatePersistence {
    static let shared = AppStatePersistence()

    private let iCloudKey = "TwoListTodoState"
    private let localKey = "TwoListTodoStateLocal"
    private let iCloudStore = NSUbiquitousKeyValueStore.default

    func load() -> AppState? {
        if let data = iCloudStore.data(forKey: iCloudKey),
           let state = decode(from: data) {
            return state
        }

        guard let data = UserDefaults.standard.data(forKey: localKey) else { return nil }
        return decode(from: data)
    }

    func save(_ state: AppState) {
        guard let data = encode(state) else { return }
        UserDefaults.standard.set(data, forKey: localKey)
        iCloudStore.set(data, forKey: iCloudKey)
        iCloudStore.synchronize()
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
    @Published var selectedTab: AppTab = .tasksList
    @Published var tasks: [TodoItem] = []
    @Published var ideas: [TodoItem] = []
    @Published var tasksWorking: [TodoItem] = []
    @Published var ideasWorking: [TodoItem] = []
    @Published var tasksGraveyard: [TodoItem] = []
    @Published var ideasGraveyard: [TodoItem] = []
    @Published var tasksSeries: [RecurringSeries] = []
    @Published var ideasSeries: [RecurringSeries] = []

    private var cancellables: Set<AnyCancellable> = []

    init() {
        load()
        observeICloudChanges()
        autosaveChanges()
    }

    func snapshot() -> AppState {
        AppState(
            selectedTab: selectedTab,
            tasks: tasks,
            ideas: ideas,
            tasksWorking: tasksWorking,
            ideasWorking: ideasWorking,
            tasksGraveyard: tasksGraveyard,
            ideasGraveyard: ideasGraveyard,
            tasksSeries: tasksSeries,
            ideasSeries: ideasSeries
        )
    }

    func apply(_ state: AppState) {
        selectedTab = state.selectedTab
        tasks = state.tasks
        ideas = state.ideas
        tasksWorking = state.tasksWorking
        ideasWorking = state.ideasWorking
        tasksGraveyard = state.tasksGraveyard
        ideasGraveyard = state.ideasGraveyard
        tasksSeries = state.tasksSeries
        ideasSeries = state.ideasSeries
    }

    func save() {
        AppStatePersistence.shared.save(snapshot())
    }

    private func load() {
        guard let state = AppStatePersistence.shared.load() else { return }
        apply(state)
    }

    private func observeICloudChanges() {
        NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let state = AppStatePersistence.shared.load() else { return }
                self?.apply(state)
            }
            .store(in: &cancellables)
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

    @State private var showingAddSheet = false
    @State private var addSheetKind: ListKind = .tasks

    @State private var showingSeriesSheet = false
    @State private var seriesSheetKind: ListKind = .tasks

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
                    case .tasksList:
                        ItemsListView(
                            title: "Tasks",
                            items: store.tasks,
                            onMoveToWork: { moveToWorkArea(item: $0, from: .tasks) },
                            onDelete: removeTasks,
                            onAddTapped: { openAddSheet(for: .tasks) }
                        )
                    case .ideasList:
                        ItemsListView(
                            title: "Ideas",
                            items: store.ideas,
                            onMoveToWork: { moveToWorkArea(item: $0, from: .ideas) },
                            onDelete: removeIdeas,
                            onAddTapped: { openAddSheet(for: .ideas) }
                        )
                    case .tasksWork:
                        WorkAreaView(
                            title: "Tasks Work Area",
                            items: $store.tasksWorking,
                            graveyard: $store.tasksGraveyard,
                            series: $store.tasksSeries,
                            onComplete: { completeItem($0, in: .tasks) },
                            onMoveToBacklog: { moveToBacklog($0, from: .tasks) },
                            onRestore: { restoreItem($0, in: .tasks) },
                            onAddSeriesTapped: { openSeriesSheet(for: .tasks) }
                        )
                    case .ideasWork:
                        WorkAreaView(
                            title: "Ideas Work Area",
                            items: $store.ideasWorking,
                            graveyard: $store.ideasGraveyard,
                            series: $store.ideasSeries,
                            onComplete: { completeItem($0, in: .ideas) },
                            onMoveToBacklog: { moveToBacklog($0, from: .ideas) },
                            onRestore: { restoreItem($0, in: .ideas) },
                            onAddSeriesTapped: { openSeriesSheet(for: .ideas) }
                        )
                    }
                }
            }
            .navigationTitle("Two-List Todo")
            .sheet(isPresented: $showingAddSheet) {
                AddItemSheet(kind: addSheetKind) { item in
                    addItem(item, to: addSheetKind)
                }
            }
            .sheet(isPresented: $showingSeriesSheet) {
                AddSeriesSheet { series in
                    addSeries(series, to: seriesSheetKind)
                }
            }
            .onAppear {
                NotificationManager.shared.requestAuthorization()
                NotificationManager.shared.scheduleDailyReminders()
                processRecurringSeries()
            }
            .onChange(of: scenePhase) { newValue in
                if newValue == .active {
                    processRecurringSeries()
                }
            }
        }
    }

    private func openAddSheet(for kind: ListKind) {
        addSheetKind = kind
        showingAddSheet = true
    }

    private func openSeriesSheet(for kind: ListKind) {
        seriesSheetKind = kind
        showingSeriesSheet = true
    }

    private func addItem(_ item: TodoItem, to kind: ListKind) {
        switch kind {
        case .tasks:
            store.tasks.insert(item, at: 0)
        case .ideas:
            store.ideas.insert(item, at: 0)
        }
    }

    private func addSeries(_ series: RecurringSeries, to kind: ListKind) {
        switch kind {
        case .tasks:
            store.tasksSeries.append(series)
            addSeriesItem(series, to: &store.tasksWorking)
        case .ideas:
            store.ideasSeries.append(series)
            addSeriesItem(series, to: &store.ideasWorking)
        }
    }

    private func addSeriesItem(_ series: RecurringSeries, to items: inout [TodoItem]) {
        if items.contains(where: { $0.seriesID == series.id }) { return }
        let newItem = TodoItem(
            title: series.title,
            priority: 3,
            dueDate: nil,
            subtasks: [],
            status: .active,
            seriesID: series.id
        )
        items.insert(newItem, at: 0)
    }

    private func removeTasks(at offsets: IndexSet) {
        store.tasks.remove(atOffsets: offsets)
    }

    private func removeIdeas(at offsets: IndexSet) {
        store.ideas.remove(atOffsets: offsets)
    }

    private func moveToWorkArea(item: TodoItem, from kind: ListKind) {
        switch kind {
        case .tasks:
            guard let index = store.tasks.firstIndex(where: { $0.id == item.id }) else { return }
            var updated = store.tasks.remove(at: index)
            updated.status = .active
            store.tasksWorking.insert(updated, at: 0)
        case .ideas:
            guard let index = store.ideas.firstIndex(where: { $0.id == item.id }) else { return }
            var updated = store.ideas.remove(at: index)
            updated.status = .active
            store.ideasWorking.insert(updated, at: 0)
        }
    }

    private func moveToBacklog(_ item: TodoItem, from kind: ListKind) {
        switch kind {
        case .tasks:
            store.tasksWorking.removeAll { $0.id == item.id }
            var updated = item
            updated.status = nil
            store.tasks.insert(updated, at: 0)
        case .ideas:
            store.ideasWorking.removeAll { $0.id == item.id }
            var updated = item
            updated.status = nil
            store.ideas.insert(updated, at: 0)
        }
    }

    private func completeItem(_ item: TodoItem, in kind: ListKind) {
        switch kind {
        case .tasks:
            store.tasksWorking.removeAll { $0.id == item.id }
            store.tasksGraveyard.insert(item, at: 0)
        case .ideas:
            store.ideasWorking.removeAll { $0.id == item.id }
            store.ideasGraveyard.insert(item, at: 0)
        }
    }

    private func restoreItem(_ item: TodoItem, in kind: ListKind) {
        switch kind {
        case .tasks:
            store.tasksGraveyard.removeAll { $0.id == item.id }
            var updated = item
            updated.status = .active
            store.tasksWorking.insert(updated, at: 0)
        case .ideas:
            store.ideasGraveyard.removeAll { $0.id == item.id }
            var updated = item
            updated.status = .active
            store.ideasWorking.insert(updated, at: 0)
        }
    }

    private func processRecurringSeries() {
        processRecurringSeries(for: &store.tasksSeries, workingItems: &store.tasksWorking, listKind: .tasks)
        processRecurringSeries(for: &store.ideasSeries, workingItems: &store.ideasWorking, listKind: .ideas)
    }

    private func processRecurringSeries(
        for seriesList: inout [RecurringSeries],
        workingItems: inout [TodoItem],
        listKind: ListKind
    ) {
        let now = Date()
        let calendar = Calendar.current
        for index in seriesList.indices {
            let series = seriesList[index]
            guard let nextDate = nextOccurrence(for: series, calendar: calendar) else { continue }
            if calendar.startOfDay(for: nextDate) <= calendar.startOfDay(for: now) {
                if workingItems.contains(where: { $0.seriesID == series.id }) {
                    NotificationManager.shared.sendSeriesPendingReminder(
                        title: series.title,
                        listKind: listKind,
                        seriesID: series.id
                    )
                } else {
                    addSeriesItem(series, to: &workingItems)
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

private struct ItemsListView: View {
    let title: String
    let items: [TodoItem]
    let onMoveToWork: (TodoItem) -> Void
    let onDelete: (IndexSet) -> Void
    let onAddTapped: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List {
                Section {
                    ForEach(items) { item in
                        ListItemRow(item: item, onMoveToWork: { onMoveToWork(item) })
                    }
                    .onDelete(perform: onDelete)
                } header: {
                    Text(title)
                } footer: {
                    Text("Tap the left button to move an item into the work area.")
                }
            }
#if os(macOS)
            .listStyle(.inset)
#else
            .listStyle(.insetGrouped)
#endif

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
            .accessibilityLabel("Add \(title)")
            .padding()
        }
    }
}

private struct WorkAreaView: View {
    let title: String
    @Binding var items: [TodoItem]
    @Binding var graveyard: [TodoItem]
    @Binding var series: [RecurringSeries]
    let onComplete: (TodoItem) -> Void
    let onMoveToBacklog: (TodoItem) -> Void
    let onRestore: (TodoItem) -> Void
    let onAddSeriesTapped: () -> Void

    @State private var activeSheet: WorkAreaSheet? = nil

    var body: some View {
        List {
            Section {
                if items.isEmpty {
                    if #available(iOS 17.0, macOS 14.0, *) {
                        ContentUnavailableView("No active tasks", systemImage: "tray")
                    } else {
                        UnavailableContentView(title: "No active tasks", systemImage: "tray")
                    }
                }
                ForEach($items) { $item in
                    WorkItemRow(item: $item, onComplete: onComplete, onMoveToBacklog: onMoveToBacklog)
                }
            } header: {
                Text(title)
            }
        }
#if os(macOS)
        .listStyle(.inset)
#else
        .listStyle(.insetGrouped)
#endif
        .toolbar {
#if os(macOS)
            ToolbarItem(placement: .automatic) {
#else
            ToolbarItem(placement: .topBarTrailing) {
#endif
                Menu {
                    Button {
                        activeSheet = .recurringSeries
                    } label: {
                        Label("Recurring series", systemImage: "repeat")
                    }

                    Button {
                        activeSheet = .graveyard
                    } label: {
                        Label("Graveyard", systemImage: "archivebox")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Work area options")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .recurringSeries:
                    recurringSeriesView
                case .graveyard:
                    graveyardView
                }
            }
        }
    }

    private func seriesDescription(_ series: RecurringSeries) -> String {
        switch series.frequency {
        case .everyDays:
            return "Every \(series.intervalDays) days"
        case .weekly:
            let days = Weekday.allCases.filter { series.weeklyDays.contains($0) }
                .map { $0.rawValue }
                .joined(separator: ", ")
            return "Weekly on \(days)"
        }
    }

    private var recurringSeriesView: some View {
        List {
            Section {
                if series.isEmpty {
                    if #available(iOS 17.0, macOS 14.0, *) {
                        ContentUnavailableView("No recurring series", systemImage: "repeat")
                    } else {
                        UnavailableContentView(title: "No recurring series", systemImage: "repeat")
                    }
                }

                ForEach(series) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                            .font(.headline)
                        Text(seriesDescription(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    series.remove(atOffsets: offsets)
                }

                Button {
                    activeSheet = nil
                    DispatchQueue.main.async {
                        onAddSeriesTapped()
                    }
                } label: {
                    Label("Add recurring series", systemImage: "repeat")
                }
            } footer: {
                Text("Recurring series generate new items on their schedule. If a previous item is still active, you'll receive a reminder instead of a duplicate.")
            }
        }
#if os(macOS)
        .listStyle(.inset)
#else
        .listStyle(.insetGrouped)
#endif
        .navigationTitle("Recurring Series")
    }

    private var graveyardView: some View {
        List {
            Section {
                if graveyard.isEmpty {
                    if #available(iOS 17.0, macOS 14.0, *) {
                        ContentUnavailableView("No completed tasks", systemImage: "archivebox")
                    } else {
                        UnavailableContentView(title: "No completed tasks", systemImage: "archivebox")
                    }
                }

                ForEach(graveyard) { item in
                    GraveyardRow(item: item, onRestore: { onRestore(item) })
                }
                .onDelete { offsets in
                    graveyard.remove(atOffsets: offsets)
                }
            } footer: {
                Text("Restore a task to put it back in the work area.")
            }
        }
#if os(macOS)
        .listStyle(.inset)
#else
        .listStyle(.insetGrouped)
#endif
        .navigationTitle("Task Graveyard")
    }
}

private enum WorkAreaSheet: Identifiable {
    case recurringSeries
    case graveyard

    var id: String {
        switch self {
        case .recurringSeries:
            return "recurringSeries"
        case .graveyard:
            return "graveyard"
        }
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

private struct ListItemRow: View {
    let item: TodoItem
    let onMoveToWork: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                onMoveToWork()
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)

                HStack(spacing: 8) {
                    Label("P\(item.priority)", systemImage: "flag.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let dueDate = item.dueDate {
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
            }
        }
        .padding(.vertical, 4)
    }
}

private struct WorkItemRow: View {
    @Binding var item: TodoItem
    var onComplete: ((TodoItem) -> Void)? = nil
    var onMoveToBacklog: ((TodoItem) -> Void)? = nil

    @State private var isExpanded = false
    @State private var subtaskDraft = ""
    @State private var showDueDatePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(item.status == .onHold ? .secondary : .primary)

                    HStack(spacing: 8) {
                        Label("P\(item.priority)", systemImage: "flag.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(item.status == .onHold ? .tertiary : .secondary)

                        if let dueDate = item.dueDate {
                            Label {
                                Text(dueDate, style: .date)
                            } icon: {
                                Image(systemName: "calendar")
                            }
                            .font(.caption)
                            .foregroundStyle(item.status == .onHold ? .tertiary : .secondary)
                        } else {
                            Text("No due date")
                                .font(.caption)
                                .foregroundStyle(item.status == .onHold ? .tertiary : .secondary)
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

            Picker("Status", selection: statusBinding) {
                ForEach(WorkingStatus.allCases) { status in
                    Text(status.rawValue).tag(status)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Button {
                    onComplete?(item)
                } label: {
                    Label("Complete", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onMoveToBacklog?(item)
                } label: {
                    Label("Backlog", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Priority", selection: $item.priority) {
                        ForEach(1...5, id: \.self) { value in
                            Text("Priority \(value)").tag(value)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("Has due date", isOn: dueDateToggle)

                    if item.dueDate != nil {
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

                    Text("Subtasks")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach($item.subtasks) { $subtask in
                        HStack {
                            Toggle(subtask.title, isOn: $subtask.isDone)
                            Spacer()
                            Button {
                                removeSubtask(subtask)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .accessibilityLabel("Remove subtask")
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Add subtask", text: $subtaskDraft)
#if os(iOS)
                            .textInputAutocapitalization(.sentences)
#endif
                        Button("Add") {
                            addSubtask()
                        }
                        .buttonStyle(.bordered)
                        .disabled(subtaskDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
        .opacity(item.status == .onHold ? 0.6 : 1)
    }

    private var statusBinding: Binding<WorkingStatus> {
        Binding(
            get: { item.status ?? .active },
            set: { newValue in
                item.status = newValue
            }
        )
    }

    private var dueDateToggle: Binding<Bool> {
        Binding(
            get: { item.dueDate != nil },
            set: { hasDueDate in
                if hasDueDate {
                    item.dueDate = item.dueDate ?? Date()
                } else {
                    item.dueDate = nil
                }
            }
        )
    }

    private var dueDateBinding: Binding<Date> {
        Binding(
            get: { item.dueDate ?? Date() },
            set: { item.dueDate = $0 }
        )
    }

    private func addSubtask() {
        let trimmed = subtaskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        item.subtasks.append(Subtask(title: trimmed))
        subtaskDraft = ""
    }

    private func removeSubtask(_ subtask: Subtask) {
        item.subtasks.removeAll { $0.id == subtask.id }
    }
}

private struct GraveyardRow: View {
    let item: TodoItem
    let onRestore: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                Text("Completed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onRestore()
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

private struct AddItemSheet: View {
    let kind: ListKind
    let onAdd: (TodoItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var priority = 3
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var showDueDatePicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
#if os(iOS)
                        .textInputAutocapitalization(.sentences)
#endif
                    Stepper("Priority \(priority)", value: $priority, in: 1...5)
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
                }
            }
            .navigationTitle(kind == .tasks ? "Add Task" : "Add Idea")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let item = TodoItem(title: trimmed, priority: priority, dueDate: hasDueDate ? dueDate : nil)
                        onAdd(item)
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

private struct AddSeriesSheet: View {
    let onAdd: (RecurringSeries) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var frequency: RecurrenceFrequency = .everyDays
    @State private var intervalDays = 2
    @State private var weeklyDays: Set<Weekday> = [.monday]

    var body: some View {
        NavigationStack {
            Form {
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
            content.title = "Check your work areas"
            content.body = "Review the tasks and ideas in your work areas to make sure they fit today."
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger)
            center.add(request)
        }
    }

    func sendSeriesPendingReminder(title: String, listKind: ListKind, seriesID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "Recurring task still active"
        content.body = "\(title) is still in your \(listKind == .tasks ? "tasks" : "ideas") work area. Complete it before the next scheduled entry."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "series-pending-\(seriesID.uuidString)", content: content, trigger: trigger)
        center.add(request)
    }
}

#Preview {
    ContentView()
}
