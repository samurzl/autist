import SwiftUI

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
}

private enum ListKind: String {
    case tasks
    case ideas
}

struct ContentView: View {
    @State private var tasks: [TodoItem] = []
    @State private var ideas: [TodoItem] = []
    @State private var tasksWorking: [TodoItem] = []
    @State private var ideasWorking: [TodoItem] = []

    @State private var tasksDraft = ""
    @State private var tasksPriority = 3
    @State private var tasksHasDueDate = false
    @State private var tasksDueDate = Date()

    @State private var ideasDraft = ""
    @State private var ideasPriority = 3
    @State private var ideasHasDueDate = false
    @State private var ideasDueDate = Date()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AddItemView(
                        title: "Add a task",
                        draft: $tasksDraft,
                        priority: $tasksPriority,
                        hasDueDate: $tasksHasDueDate,
                        dueDate: $tasksDueDate,
                        onAdd: addTask
                    )

                    ForEach(sortedItems(tasks)) { item in
                        if let index = tasks.firstIndex(where: { $0.id == item.id }) {
                            TodoItemRow(item: $tasks[index])
                                .onDrag { dragPayload(for: item, kind: .tasks) }
                        }
                    }
                    .onDelete(perform: removeTasks)
                } header: {
                    Text("Tasks")
                } footer: {
                    Text("Drag tasks into the working area to track their status.")
                }

                Section {
                    dropZoneHeader(title: "Tasks Working Area")

                    ForEach(sortedItems(tasksWorking)) { item in
                        if let index = tasksWorking.firstIndex(where: { $0.id == item.id }) {
                            TodoItemRow(item: $tasksWorking[index], showsStatus: true) { completed in
                                removeCompleted(completed, from: .tasks)
                            }
                        }
                    }
                    .onDelete(perform: removeTasksWorking)
                }
                .onDrop(of: [.text], isTargeted: nil) { providers in
                    handleDrop(providers, target: .tasks)
                }

                Section {
                    AddItemView(
                        title: "Add an idea",
                        draft: $ideasDraft,
                        priority: $ideasPriority,
                        hasDueDate: $ideasHasDueDate,
                        dueDate: $ideasDueDate,
                        onAdd: addIdea
                    )

                    ForEach(sortedItems(ideas)) { item in
                        if let index = ideas.firstIndex(where: { $0.id == item.id }) {
                            TodoItemRow(item: $ideas[index])
                                .onDrag { dragPayload(for: item, kind: .ideas) }
                        }
                    }
                    .onDelete(perform: removeIdeas)
                } header: {
                    Text("Ideas")
                } footer: {
                    Text("Ideas can be prioritized too, especially if they have due dates.")
                }

                Section {
                    dropZoneHeader(title: "Ideas Working Area")

                    ForEach(sortedItems(ideasWorking)) { item in
                        if let index = ideasWorking.firstIndex(where: { $0.id == item.id }) {
                            TodoItemRow(item: $ideasWorking[index], showsStatus: true) { completed in
                                removeCompleted(completed, from: .ideas)
                            }
                        }
                    }
                    .onDelete(perform: removeIdeasWorking)
                }
                .onDrop(of: [.text], isTargeted: nil) { providers in
                    handleDrop(providers, target: .ideas)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Two-List Todo")
            .toolbar {
                EditButton()
            }
        }
    }

    private func sortedItems(_ items: [TodoItem]) -> [TodoItem] {
        items.sorted { lhs, rhs in
            let lhsHasDueDate = lhs.dueDate != nil
            let rhsHasDueDate = rhs.dueDate != nil

            if lhsHasDueDate != rhsHasDueDate {
                return lhsHasDueDate && !rhsHasDueDate
            }

            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }

            if let lhsDate = lhs.dueDate, let rhsDate = rhs.dueDate, lhsDate != rhsDate {
                return lhsDate < rhsDate
            }

            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func addTask() {
        let trimmed = tasksDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let dueDate = tasksHasDueDate ? tasksDueDate : nil
        tasks.insert(TodoItem(title: trimmed, priority: tasksPriority, dueDate: dueDate), at: 0)
        tasksDraft = ""
        tasksHasDueDate = false
    }

    private func addIdea() {
        let trimmed = ideasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let dueDate = ideasHasDueDate ? ideasDueDate : nil
        ideas.insert(TodoItem(title: trimmed, priority: ideasPriority, dueDate: dueDate), at: 0)
        ideasDraft = ""
        ideasHasDueDate = false
    }

    private func removeTasks(at offsets: IndexSet) {
        tasks.remove(atOffsets: offsets)
    }

    private func removeIdeas(at offsets: IndexSet) {
        ideas.remove(atOffsets: offsets)
    }

    private func removeTasksWorking(at offsets: IndexSet) {
        tasksWorking.remove(atOffsets: offsets)
    }

    private func removeIdeasWorking(at offsets: IndexSet) {
        ideasWorking.remove(atOffsets: offsets)
    }

    private func dragPayload(for item: TodoItem, kind: ListKind) -> NSItemProvider {
        NSItemProvider(object: "\(kind.rawValue):\(item.id.uuidString)" as NSString)
    }

    private func handleDrop(_ providers: [NSItemProvider], target: ListKind) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let payload = object as? String else { return }
                    DispatchQueue.main.async {
                        moveItem(with: payload, to: target)
                    }
                }
                return true
            }
        }
        return false
    }

    private func moveItem(with payload: String, to target: ListKind) {
        let parts = payload.split(separator: ":")
        guard parts.count == 2, let sourceKind = ListKind(rawValue: String(parts[0])) else { return }
        guard sourceKind == target else { return }
        let idString = String(parts[1])
        guard let itemID = UUID(uuidString: idString) else { return }

        switch target {
        case .tasks:
            if let index = tasks.firstIndex(where: { $0.id == itemID }) {
                var item = tasks.remove(at: index)
                item.status = .active
                tasksWorking.append(item)
            }
        case .ideas:
            if let index = ideas.firstIndex(where: { $0.id == itemID }) {
                var item = ideas.remove(at: index)
                item.status = .active
                ideasWorking.append(item)
            }
        }
    }

    private func removeCompleted(_ item: TodoItem, from kind: ListKind) {
        switch kind {
        case .tasks:
            tasksWorking.removeAll { $0.id == item.id }
        case .ideas:
            ideasWorking.removeAll { $0.id == item.id }
        }
    }

    private func dropZoneHeader(title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            Label("Drop Here", systemImage: "tray.and.arrow.down")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AddItemView: View {
    let title: String
    @Binding var draft: String
    @Binding var priority: Int
    @Binding var hasDueDate: Bool
    @Binding var dueDate: Date
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TextField(title, text: $draft)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .onSubmit(onAdd)

                Button("Add") {
                    onAdd()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 16) {
                Stepper("Priority \(priority)", value: $priority, in: 1...5)
                Toggle("Due date", isOn: $hasDueDate)
            }

            if hasDueDate {
                DatePicker("", selection: $dueDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TodoItemRow: View {
    @Binding var item: TodoItem
    var showsStatus: Bool = false
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

            if showsStatus {
                Picker("Status", selection: statusBinding) {
                    ForEach(WorkingStatus.allCases) { status in
                        Text(status.rawValue).tag(status)
                    }
                }
                .pickerStyle(.segmented)
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

#Preview {
    ContentView()
}
