import SwiftUI
import UserNotifications

private enum WorkingStatus: String, CaseIterable, Identifiable {
    case active = "Active"
    case waiting = "Waiting"
    case done = "Done"

    var id: String { rawValue }
}

private struct Subtask: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var isDone = false
}

private struct TodoItem: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var priority: Int
    var dueDate: Date?
    var subtasks: [Subtask] = []
    var status: WorkingStatus? = nil
    var seriesID: UUID? = nil
}

private enum ListKind: String {
    case tasks
    case ideas
}

private enum AppTab: String, CaseIterable, Identifiable {
    case tasksList = "Tasks List"
    case ideasList = "Ideas List"
    case tasksWork = "Tasks Work"
    case ideasWork = "Ideas Work"

    var id: String { rawValue }
}

private enum RecurrenceFrequency: String, CaseIterable, Identifiable {
    case everyDays = "Every X Days"
    case weekly = "Weekly"

    var id: String { rawValue }
}

private enum Weekday: String, CaseIterable, Identifiable {
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

private struct RecurringSeries: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var frequency: RecurrenceFrequency
    var intervalDays: Int = 2
    var weeklyDays: Set<Weekday> = []
    var lastGeneratedDate: Date = Date()
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .tasksList

    @State private var tasks: [TodoItem] = []
    @State private var ideas: [TodoItem] = []
    @State private var tasksWorking: [TodoItem] = []
    @State private var ideasWorking: [TodoItem] = []
    @State private var tasksGraveyard: [TodoItem] = []
    @State private var ideasGraveyard: [TodoItem] = []
    @State private var tasksSeries: [RecurringSeries] = []
    @State private var ideasSeries: [RecurringSeries] = []

    @State private var showingAddSheet = false
    @State private var addSheetKind: ListKind = .tasks

    @State private var showingSeriesSheet = false
    @State private var seriesSheetKind: ListKind = .tasks

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Tabs", selection: $selectedTab) {
                    ForEach(AppTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                Group {
                    switch selectedTab {
                    case .tasksList:
                        ItemsListView(
                            title: "Tasks",
                            items: tasks,
                            onMoveToWork: { moveToWorkArea(item: $0, from: .tasks) },
                            onDelete: removeTasks,
                            onAddTapped: { openAddSheet(for: .tasks) }
                        )
                    case .ideasList:
                        ItemsListView(
                            title: "Ideas",
                            items: ideas,
                            onMoveToWork: { moveToWorkArea(item: $0, from: .ideas) },
                            onDelete: removeIdeas,
                            onAddTapped: { openAddSheet(for: .ideas) }
                        )
                    case .tasksWork:
                        WorkAreaView(
                            title: "Tasks Work Area",
                            items: $tasksWorking,
                            graveyard: $tasksGraveyard,
                            series: $tasksSeries,
                            onComplete: { completeItem($0, in: .tasks) },
                            onRestore: { restoreItem($0, in: .tasks) },
                            onAddSeriesTapped: { openSeriesSheet(for: .tasks) }
                        )
                    case .ideasWork:
                        WorkAreaView(
                            title: "Ideas Work Area",
                            items: $ideasWorking,
                            graveyard: $ideasGraveyard,
                            series: $ideasSeries,
                            onComplete: { completeItem($0, in: .ideas) },
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
            tasks.insert(item, at: 0)
        case .ideas:
            ideas.insert(item, at: 0)
        }
    }

    private func addSeries(_ series: RecurringSeries, to kind: ListKind) {
        switch kind {
        case .tasks:
            tasksSeries.append(series)
            addSeriesItem(series, to: &tasksWorking)
        case .ideas:
            ideasSeries.append(series)
            addSeriesItem(series, to: &ideasWorking)
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
        tasks.remove(atOffsets: offsets)
    }

    private func removeIdeas(at offsets: IndexSet) {
        ideas.remove(atOffsets: offsets)
    }

    private func moveToWorkArea(item: TodoItem, from kind: ListKind) {
        switch kind {
        case .tasks:
            guard let index = tasks.firstIndex(where: { $0.id == item.id }) else { return }
            var updated = tasks.remove(at: index)
            updated.status = .active
            tasksWorking.insert(updated, at: 0)
        case .ideas:
            guard let index = ideas.firstIndex(where: { $0.id == item.id }) else { return }
            var updated = ideas.remove(at: index)
            updated.status = .active
            ideasWorking.insert(updated, at: 0)
        }
    }

    private func completeItem(_ item: TodoItem, in kind: ListKind) {
        switch kind {
        case .tasks:
            tasksWorking.removeAll { $0.id == item.id }
            tasksGraveyard.insert(item, at: 0)
        case .ideas:
            ideasWorking.removeAll { $0.id == item.id }
            ideasGraveyard.insert(item, at: 0)
        }
    }

    private func restoreItem(_ item: TodoItem, in kind: ListKind) {
        switch kind {
        case .tasks:
            tasksGraveyard.removeAll { $0.id == item.id }
            var updated = item
            updated.status = .active
            tasksWorking.insert(updated, at: 0)
        case .ideas:
            ideasGraveyard.removeAll { $0.id == item.id }
            var updated = item
            updated.status = .active
            ideasWorking.insert(updated, at: 0)
        }
    }

    private func processRecurringSeries() {
        processRecurringSeries(for: &tasksSeries, workingItems: &tasksWorking, listKind: .tasks)
        processRecurringSeries(for: &ideasSeries, workingItems: &ideasWorking, listKind: .ideas)
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
                Section(header: Text(title)) {
                    ForEach(items) { item in
                        ListItemRow(item: item, onMoveToWork: { onMoveToWork(item) })
                    }
                    .onDelete(perform: onDelete)
                } footer: {
                    Text("Tap the left button to move an item into the work area.")
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
    let onRestore: (TodoItem) -> Void
    let onAddSeriesTapped: () -> Void

    var body: some View {
        List {
            Section(header: Text(title)) {
                if items.isEmpty {
                    ContentUnavailableView("No active tasks", systemImage: "tray")
                }
                ForEach($items) { $item in
                    WorkItemRow(item: $item, onComplete: { onComplete(item) })
                }
            }

            Section {
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
                    onAddSeriesTapped()
                } label: {
                    Label("Add recurring series", systemImage: "repeat")
                }
            } header: {
                Text("Recurring Series")
            } footer: {
                Text("Recurring series generate new items on their schedule. If a previous item is still active, you'll receive a reminder instead of a duplicate.")
            }

            Section {
                if graveyard.isEmpty {
                    ContentUnavailableView("No completed tasks", systemImage: "archivebox")
                }
                ForEach(graveyard) { item in
                    GraveyardRow(item: item, onRestore: { onRestore(item) })
                }
                .onDelete { offsets in
                    graveyard.remove(atOffsets: offsets)
                }
            } header: {
                Text("Task Graveyard")
            } footer: {
                Text("Restore a task to put it back in the work area.")
            }
        }
        .listStyle(.insetGrouped)
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
            .foregroundStyle(.accent)

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

    @State private var isExpanded = false
    @State private var subtaskDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
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

            Button {
                onComplete?(item)
            } label: {
                Label("Complete", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)

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
                        DatePicker("Due", selection: dueDateBinding, displayedComponents: .date)
                            .datePickerStyle(.compact)
                    }

                    Divider()

                    Text("Subtasks")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach($item.subtasks) { $subtask in
                        Toggle(subtask.title, isOn: $subtask.isDone)
                    }

                    HStack(spacing: 8) {
                        TextField("Add subtask", text: $subtaskDraft)
                            .textInputAutocapitalization(.sentences)
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
    }

    private var statusBinding: Binding<WorkingStatus> {
        Binding(
            get: { item.status ?? .active },
            set: { newValue in
                item.status = newValue
                if newValue == .done {
                    onComplete?(item)
                }
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

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
                    Stepper("Priority \(priority)", value: $priority, in: 1...5)
                    Toggle("Has due date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
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
