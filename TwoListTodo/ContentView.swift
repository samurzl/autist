import SwiftUI

struct ContentView: View {
    @State private var todayItems: [String] = []
    @State private var laterItems: [String] = []
    @State private var todayDraft = ""
    @State private var laterDraft = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        TextField("Add a must-do", text: $todayDraft)
                            .textInputAutocapitalization(.sentences)
                            .submitLabel(.done)
                            .onSubmit(addTodayItem)

                        Button("Add") {
                            addTodayItem()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(todayDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    ForEach(todayItems, id: \.self) { item in
                        Text(item)
                    }
                    .onDelete(perform: removeTodayItems)
                } header: {
                    Text("Today")
                } footer: {
                    Text("Keep this list focused on the tasks that must happen today.")
                }

                Section {
                    HStack(spacing: 12) {
                        TextField("Add a later task", text: $laterDraft)
                            .textInputAutocapitalization(.sentences)
                            .submitLabel(.done)
                            .onSubmit(addLaterItem)

                        Button("Add") {
                            addLaterItem()
                        }
                        .buttonStyle(.bordered)
                        .disabled(laterDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    ForEach(laterItems, id: \.self) { item in
                        Text(item)
                    }
                    .onDelete(perform: removeLaterItems)
                } header: {
                    Text("Later")
                } footer: {
                    Text("Capture ideas you want to revisit when today is clear.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Two-List Todo")
            .toolbar {
                EditButton()
            }
        }
    }

    private func addTodayItem() {
        let trimmed = todayDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        todayItems.insert(trimmed, at: 0)
        todayDraft = ""
    }

    private func addLaterItem() {
        let trimmed = laterDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        laterItems.insert(trimmed, at: 0)
        laterDraft = ""
    }

    private func removeTodayItems(at offsets: IndexSet) {
        todayItems.remove(atOffsets: offsets)
    }

    private func removeLaterItems(at offsets: IndexSet) {
        laterItems.remove(atOffsets: offsets)
    }
}

#Preview {
    ContentView()
}
