import Combine
import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

private enum WorkingStatus: String, CaseIterable, Identifiable, Codable {
    case active = "Active"
    case onHold = "On Hold"

    var id: String { rawValue }
}

private let defaultDailyCapacityMinutes = 240
private let highRiskPriorityThreshold = 4
private let highRiskDueWindowDays = 7

private struct LocationCoordinate: Hashable, Codable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct TaskLocationTrigger: Hashable, Codable {
    var center: LocationCoordinate
    var radiusMeters: Double
    var polygon: [LocationCoordinate] = []

    var usesPolygon: Bool {
        polygon.count >= 3
    }

    var monitoringRadius: CLLocationDistance {
        max(radiusMeters, 100)
    }

    func contains(_ location: CLLocation) -> Bool {
        if usesPolygon {
            return polygonContains(location.coordinate, polygon: polygon)
        }

        let centerLocation = CLLocation(
            latitude: center.latitude,
            longitude: center.longitude
        )
        return centerLocation.distance(from: location) <= radiusMeters
    }
}

private struct DependencyReference: Hashable, Codable, Identifiable {
    var taskID: UUID
    var descendantIDs: [UUID] = []

    var id: String {
        ([taskID.uuidString] + descendantIDs.map(\.uuidString)).joined(separator: "::")
    }

    var isTask: Bool {
        descendantIDs.isEmpty
    }

    var parent: DependencyReference? {
        guard !descendantIDs.isEmpty else { return nil }
        return DependencyReference(taskID: taskID, descendantIDs: Array(descendantIDs.dropLast()))
    }

    init(taskID: UUID, descendantIDs: [UUID] = []) {
        self.taskID = taskID
        self.descendantIDs = descendantIDs
    }

    init(taskID: UUID, subtaskID: UUID?) {
        self.taskID = taskID
        if let subtaskID {
            descendantIDs = [subtaskID]
        } else {
            descendantIDs = []
        }
    }

    func appending(_ childID: UUID) -> DependencyReference {
        DependencyReference(taskID: taskID, descendantIDs: descendantIDs + [childID])
    }

    func isAncestor(of other: DependencyReference) -> Bool {
        guard taskID == other.taskID else { return false }
        guard descendantIDs.count < other.descendantIDs.count else { return false }
        return Array(other.descendantIDs.prefix(descendantIDs.count)) == descendantIDs
    }

    private enum CodingKeys: String, CodingKey {
        case taskID
        case descendantIDs
        case subtaskID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decode(UUID.self, forKey: .taskID)
        if let descendantIDs = try container.decodeIfPresent([UUID].self, forKey: .descendantIDs) {
            self.descendantIDs = descendantIDs
        } else if let legacySubtaskID = try container.decodeIfPresent(UUID.self, forKey: .subtaskID) {
            descendantIDs = [legacySubtaskID]
        } else {
            descendantIDs = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(descendantIDs, forKey: .descendantIDs)
    }
}

private struct DependencyOption: Identifiable, Hashable {
    let reference: DependencyReference
    let title: String
    let subtitle: String

    var id: String { reference.id }
}

private enum IdeaCategory: String, CaseIterable, Identifiable, Codable {
    case snack = "Snacks"
    case project = "Projects"
    case quest = "Quests"

    var id: String { rawValue }

    var timespanDescription: String {
        switch self {
        case .snack:
            return "Low effort, low identity joy and texture."
        case .project:
            return "Weeks to months and skill-or-goal oriented."
        case .quest:
            return "Months to years and identity-shaping."
        }
    }

    var tintColor: Color {
        switch self {
        case .snack:
            return .secondary
        case .project:
            return .green
        case .quest:
            return .blue
        }
    }
}

private enum TaskEstimateUnit: String, CaseIterable, Identifiable {
    case minutes = "Minutes"
    case hour = "Hour"
    case day = "Day"
    case weeks = "Weeks"
    case months = "Months"

    var id: String { rawValue }

    func minuteMultiplier(dailyCapacityMinutes: Int) -> Int {
        let safeCapacity = max(1, dailyCapacityMinutes)
        switch self {
        case .minutes:
            return 1
        case .hour:
            return 60
        case .day:
            return safeCapacity
        case .weeks:
            return safeCapacity * 7
        case .months:
            return safeCapacity * 30
        }
    }
}

private struct SubtaskItem: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var status: WorkingStatus = .active
    var dueDate: Date? = nil
    var estimatedMinutes: Int? = nil
    var note: String = ""
    var blockingDependency: DependencyReference? = nil
    var createdAt: Date = Date()
    var completedAt: Date? = nil
    var subtasks: [SubtaskItem] = []
    var subtaskGraveyard: [SubtaskItem] = []

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case dueDate
        case estimatedMinutes
        case note
        case blockingDependency
        case createdAt
        case completedAt
        case subtasks
        case subtaskGraveyard
    }

    init(
        id: UUID = UUID(),
        title: String,
        status: WorkingStatus = .active,
        dueDate: Date? = nil,
        estimatedMinutes: Int? = nil,
        note: String = "",
        blockingDependency: DependencyReference? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        subtasks: [SubtaskItem] = [],
        subtaskGraveyard: [SubtaskItem] = []
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.dueDate = dueDate
        self.estimatedMinutes = estimatedMinutes
        self.note = note
        self.blockingDependency = blockingDependency
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.subtasks = subtasks
        self.subtaskGraveyard = subtaskGraveyard
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
        estimatedMinutes = try container.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        blockingDependency = try container.decodeIfPresent(DependencyReference.self, forKey: .blockingDependency)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        var decodedSubtasks = try container.decodeIfPresent([SubtaskItem].self, forKey: .subtasks) ?? []
        var decodedGraveyard = try container.decodeIfPresent([SubtaskItem].self, forKey: .subtaskGraveyard) ?? []
        let migratedCompleted = decodedSubtasks.filter { $0.completedAt != nil }
        decodedSubtasks.removeAll { $0.completedAt != nil }
        decodedGraveyard.append(contentsOf: migratedCompleted)
        subtasks = decodedSubtasks
        subtaskGraveyard = decodedGraveyard

        if let workingStatus = try? container.decode(WorkingStatus.self, forKey: .status) {
            status = workingStatus
            return
        }

        let legacyStatus = (try? container.decode(String.self, forKey: .status)) ?? "Active"
        switch legacyStatus.lowercased() {
        case "on hold", "onhold":
            status = .onHold
        case "completed":
            status = .active
            if completedAt == nil {
                completedAt = Date()
            }
        default:
            status = .active
        }
    }
}

private struct IdeaItem: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var detail: String
    var category: IdeaCategory = .snack

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case detail
        case category
    }

    init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        category: IdeaCategory = .snack
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.category = category
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        category = try container.decodeIfPresent(IdeaCategory.self, forKey: .category) ?? .snack
    }
}

private struct ProjectItem: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var detail: String
    var status: WorkingStatus = .active
    var category: IdeaCategory = .project

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case detail
        case status
        case category
    }

    init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        status: WorkingStatus = .active,
        category: IdeaCategory = .project
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.category = category
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        category = try container.decodeIfPresent(IdeaCategory.self, forKey: .category) ?? .project

        if let decodedStatus = try? container.decode(WorkingStatus.self, forKey: .status) {
            status = decodedStatus
            return
        }

        let legacyStatus = (try? container.decode(String.self, forKey: .status)) ?? "Active"
        switch legacyStatus.lowercased() {
        case "on hold", "onhold":
            status = .onHold
        default:
            status = .active
        }
    }
}

private struct TaskItem: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var priority: Int
    var dueDate: Date?
    var estimatedMinutes: Int? = nil
    var status: WorkingStatus = .active
    var isManuallyMustDoNow: Bool = false
    var createdAt: Date = Date()
    var lastPriorityBumpDate: Date = Date()
    var lastWorkedAt: Date? = nil
    var scheduledDate: Date? = nil
    var scheduledParentTaskID: UUID? = nil
    var seriesID: UUID? = nil
    var onHoldSince: Date? = nil
    var onHoldUntil: Date? = nil
    var blockingDependency: DependencyReference? = nil
    var locationTrigger: TaskLocationTrigger? = nil
    var note: String = ""
    var subtasks: [SubtaskItem] = []
    var subtaskGraveyard: [SubtaskItem] = []

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case priority
        case dueDate
        case estimatedMinutes
        case status
        case isManuallyMustDoNow
        case createdAt
        case lastPriorityBumpDate
        case lastWorkedAt
        case scheduledDate
        case scheduledParentTaskID
        case seriesID
        case onHoldSince
        case onHoldUntil
        case blockingDependency
        case locationTrigger
        case note
        case subtasks
        case subtaskGraveyard
    }

    init(
        id: UUID = UUID(),
        title: String,
        priority: Int,
        dueDate: Date?,
        estimatedMinutes: Int? = nil,
        status: WorkingStatus = .active,
        isManuallyMustDoNow: Bool = false,
        createdAt: Date = Date(),
        lastPriorityBumpDate: Date = Date(),
        lastWorkedAt: Date? = nil,
        scheduledDate: Date? = nil,
        scheduledParentTaskID: UUID? = nil,
        seriesID: UUID? = nil,
        onHoldSince: Date? = nil,
        onHoldUntil: Date? = nil,
        blockingDependency: DependencyReference? = nil,
        locationTrigger: TaskLocationTrigger? = nil,
        note: String = "",
        subtasks: [SubtaskItem] = [],
        subtaskGraveyard: [SubtaskItem] = []
    ) {
        self.id = id
        self.title = title
        self.priority = priority
        self.dueDate = dueDate
        self.estimatedMinutes = estimatedMinutes
        self.status = status
        self.isManuallyMustDoNow = isManuallyMustDoNow
        self.createdAt = createdAt
        self.lastPriorityBumpDate = lastPriorityBumpDate
        self.lastWorkedAt = lastWorkedAt
        self.scheduledDate = scheduledDate
        self.scheduledParentTaskID = scheduledParentTaskID
        self.seriesID = seriesID
        self.onHoldSince = onHoldSince
        self.onHoldUntil = onHoldUntil
        self.blockingDependency = blockingDependency
        self.locationTrigger = locationTrigger
        self.note = note
        self.subtasks = subtasks
        self.subtaskGraveyard = subtaskGraveyard
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        priority = try container.decode(Int.self, forKey: .priority)
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
        estimatedMinutes = try container.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        status = try container.decodeIfPresent(WorkingStatus.self, forKey: .status) ?? .active
        isManuallyMustDoNow = try container.decodeIfPresent(Bool.self, forKey: .isManuallyMustDoNow) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastPriorityBumpDate = try container.decodeIfPresent(Date.self, forKey: .lastPriorityBumpDate) ?? createdAt
        lastWorkedAt = try container.decodeIfPresent(Date.self, forKey: .lastWorkedAt)
        scheduledDate = try container.decodeIfPresent(Date.self, forKey: .scheduledDate)
        scheduledParentTaskID = try container.decodeIfPresent(UUID.self, forKey: .scheduledParentTaskID)
        seriesID = try container.decodeIfPresent(UUID.self, forKey: .seriesID)
        onHoldSince = try container.decodeIfPresent(Date.self, forKey: .onHoldSince)
        onHoldUntil = try container.decodeIfPresent(Date.self, forKey: .onHoldUntil)
        blockingDependency = try container.decodeIfPresent(DependencyReference.self, forKey: .blockingDependency)
        locationTrigger = try container.decodeIfPresent(TaskLocationTrigger.self, forKey: .locationTrigger)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        var decodedSubtasks = try container.decodeIfPresent([SubtaskItem].self, forKey: .subtasks) ?? []
        var decodedGraveyard = try container.decodeIfPresent([SubtaskItem].self, forKey: .subtaskGraveyard) ?? []
        let migratedCompleted = decodedSubtasks.filter { $0.completedAt != nil }
        decodedSubtasks.removeAll { $0.completedAt != nil }
        decodedGraveyard.append(contentsOf: migratedCompleted)
        subtasks = decodedSubtasks
        subtaskGraveyard = decodedGraveyard
    }
}

private enum AppTab: String, CaseIterable, Identifiable, Codable {
    case ideas = "Ideas"
    case projects = "Projects"
    case tasks = "Tasks"
    case guide = "Guide"

    var id: String { rawValue }
}

private enum RecurrenceFrequency: String, CaseIterable, Identifiable, Codable {
    case everyDays = "Every X Days"
    case weekly = "Weekly"
    case monthly = "Monthly"

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
    var appearanceHour: Int = 9
    var appearanceMinute: Int = 0
    var dueDateOffsetDays: Int? = nil
    var estimatedMinutes: Int? = nil
    var locationTrigger: TaskLocationTrigger? = nil
    var lastGeneratedDate: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case priority
        case frequency
        case intervalDays
        case weeklyDays
        case appearanceHour
        case appearanceMinute
        case dueDateOffsetDays
        case estimatedMinutes
        case locationTrigger
        case lastGeneratedDate
    }

    init(
        id: UUID = UUID(),
        title: String,
        priority: Int = 3,
        frequency: RecurrenceFrequency,
        intervalDays: Int = 2,
        weeklyDays: Set<Weekday> = [],
        appearanceHour: Int = 9,
        appearanceMinute: Int = 0,
        dueDateOffsetDays: Int? = nil,
        estimatedMinutes: Int? = nil,
        locationTrigger: TaskLocationTrigger? = nil,
        lastGeneratedDate: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.priority = priority
        self.frequency = frequency
        self.intervalDays = intervalDays
        self.weeklyDays = weeklyDays
        self.appearanceHour = appearanceHour
        self.appearanceMinute = appearanceMinute
        self.dueDateOffsetDays = dueDateOffsetDays
        self.estimatedMinutes = estimatedMinutes
        self.locationTrigger = locationTrigger
        self.lastGeneratedDate = lastGeneratedDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 3
        frequency = try container.decode(RecurrenceFrequency.self, forKey: .frequency)
        intervalDays = try container.decodeIfPresent(Int.self, forKey: .intervalDays) ?? 2
        weeklyDays = try container.decodeIfPresent(Set<Weekday>.self, forKey: .weeklyDays) ?? []
        appearanceHour = try container.decodeIfPresent(Int.self, forKey: .appearanceHour) ?? 9
        appearanceMinute = try container.decodeIfPresent(Int.self, forKey: .appearanceMinute) ?? 0
        dueDateOffsetDays = try container.decodeIfPresent(Int.self, forKey: .dueDateOffsetDays)
        estimatedMinutes = try container.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        locationTrigger = try container.decodeIfPresent(TaskLocationTrigger.self, forKey: .locationTrigger)
        lastGeneratedDate = try container.decodeIfPresent(Date.self, forKey: .lastGeneratedDate) ?? Date()
    }
}

private struct ImprovementNote: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var detail: String
    var createdAt: Date = Date()
}

private struct AppState: Codable, Equatable {
    var selectedTab: AppTab = .guide
    var ideas: [IdeaItem] = []
    var projects: [ProjectItem] = []
    var tasks: [TaskItem] = []
    var completedTasksArchive: [TaskItem] = []
    var scheduledTasks: [TaskItem] = []
    var tasksSeries: [RecurringSeries] = []
    var improvementNotes: [ImprovementNote] = []
    var dailyCapacityMinutes: Int = defaultDailyCapacityMinutes
    var lastModifiedAt: Date = .distantPast

    enum CodingKeys: String, CodingKey {
        case selectedTab
        case ideas
        case projects
        case tasks
        case completedTasksArchive
        case scheduledTasks
        case tasksSeries
        case improvementNotes
        case dailyCapacityMinutes
        case lastModifiedAt
    }

    init(
        selectedTab: AppTab = .guide,
        ideas: [IdeaItem] = [],
        projects: [ProjectItem] = [],
        tasks: [TaskItem] = [],
        completedTasksArchive: [TaskItem] = [],
        scheduledTasks: [TaskItem] = [],
        tasksSeries: [RecurringSeries] = [],
        improvementNotes: [ImprovementNote] = [],
        dailyCapacityMinutes: Int = defaultDailyCapacityMinutes,
        lastModifiedAt: Date = .distantPast
    ) {
        self.selectedTab = selectedTab
        self.ideas = ideas
        self.projects = projects
        self.tasks = tasks
        self.completedTasksArchive = completedTasksArchive
        self.scheduledTasks = scheduledTasks
        self.tasksSeries = tasksSeries
        self.improvementNotes = improvementNotes
        self.dailyCapacityMinutes = max(1, dailyCapacityMinutes)
        self.lastModifiedAt = lastModifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedTab = try container.decodeIfPresent(AppTab.self, forKey: .selectedTab) ?? .guide
        ideas = try container.decodeIfPresent([IdeaItem].self, forKey: .ideas) ?? []
        projects = try container.decodeIfPresent([ProjectItem].self, forKey: .projects) ?? []
        tasks = try container.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? []
        completedTasksArchive = try container.decodeIfPresent([TaskItem].self, forKey: .completedTasksArchive) ?? []
        scheduledTasks = try container.decodeIfPresent([TaskItem].self, forKey: .scheduledTasks) ?? []
        tasksSeries = try container.decodeIfPresent([RecurringSeries].self, forKey: .tasksSeries) ?? []
        improvementNotes = try container.decodeIfPresent([ImprovementNote].self, forKey: .improvementNotes) ?? []
        dailyCapacityMinutes = max(
            1,
            try container.decodeIfPresent(Int.self, forKey: .dailyCapacityMinutes) ?? defaultDailyCapacityMinutes
        )
        lastModifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastModifiedAt) ?? .distantPast
    }
}

private struct LegacyAppState: Codable {
    var selectedTab: AppTab = .guide
    var ideas: [IdeaItem] = []
    var projects: [ProjectItem] = []
    var tasks: [TaskItem] = []
    var scheduledTasks: [TaskItem] = []
    var tasksSeries: [RecurringSeries] = []
}

private enum ItemNoteKind: String, CaseIterable {
    case idea
    case project
    case task
    case improvement

    var filePrefix: String {
        rawValue
    }
}

private struct ParsedMarkdownNote {
    var title: String?
    var body: String
}

private final class AppStatePersistence {
    static let shared = AppStatePersistence()

    private let localKey = "TwoListTodoStateLocal"
    private let localBackupKey = "TwoListTodoStateLocalBackup"
    private let syncFolderBookmarkKey = "TwoListTodoSyncFolderBookmark"
    private let syncStateFilename = "TwoListTodoState.json"
    private let syncBackupStateFilename = "TwoListTodoState.backup.json"
    private let notesDirectoryName = "ItemNotes"
    private let fileManager = FileManager.default

    func load() -> AppState? {
        if let syncedState = loadFromCloud() {
            return syncedState
        }
        guard let stateData = bestLocalStateData(),
              var state = decode(from: stateData) else { return nil }
        applyMarkdownNotes(to: &state, in: localNotesDirectoryURL)
        return state
    }

    func save(_ state: AppState) {
        guard let data = encode(state) else { return }
        if let existingLocalData = UserDefaults.standard.data(forKey: localKey),
           existingLocalData != data {
            UserDefaults.standard.set(existingLocalData, forKey: localBackupKey)
        }
        UserDefaults.standard.set(data, forKey: localKey)
        let didWriteRemote = withRemoteDocumentsDirectory { remoteDirectoryURL in
            let stateURL = remoteDirectoryURL.appendingPathComponent(syncStateFilename, isDirectory: false)
            let backupStateURL = remoteDirectoryURL.appendingPathComponent(syncBackupStateFilename, isDirectory: false)
            let notesDirectoryURL = remoteDirectoryURL.appendingPathComponent(notesDirectoryName, isDirectory: true)
            if let existingRemoteData = try? Data(contentsOf: stateURL),
               existingRemoteData != data {
                write(existingRemoteData, to: backupStateURL)
            }
            write(data, to: stateURL)
            syncMarkdownNotes(for: state, in: notesDirectoryURL)
        }
        if !didWriteRemote {
            syncMarkdownNotes(for: state, in: localNotesDirectoryURL)
        }
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: localKey)
        UserDefaults.standard.removeObject(forKey: localBackupKey)
        _ = withRemoteDocumentsDirectory { remoteDirectoryURL in
            let stateURL = remoteDirectoryURL.appendingPathComponent(syncStateFilename, isDirectory: false)
            let backupStateURL = remoteDirectoryURL.appendingPathComponent(syncBackupStateFilename, isDirectory: false)
            let notesDirectoryURL = remoteDirectoryURL.appendingPathComponent(notesDirectoryName, isDirectory: true)
            try? fileManager.removeItem(at: stateURL)
            try? fileManager.removeItem(at: backupStateURL)
            try? fileManager.removeItem(at: notesDirectoryURL)
        }
        try? fileManager.removeItem(at: localNotesDirectoryURL)
    }

    func loadFromCloud() -> AppState? {
        var loadedState: AppState? = nil
        _ = withRemoteDocumentsDirectory { remoteDirectoryURL in
            let stateURL = remoteDirectoryURL.appendingPathComponent(syncStateFilename, isDirectory: false)
            let backupStateURL = remoteDirectoryURL.appendingPathComponent(syncBackupStateFilename, isDirectory: false)
            let notesDirectoryURL = remoteDirectoryURL.appendingPathComponent(notesDirectoryName, isDirectory: true)
            let dataCandidates = [stateURL, backupStateURL].compactMap { try? Data(contentsOf: $0) }
            guard let stateData = dataCandidates.first(where: { decode(from: $0) != nil }),
                  var state = decode(from: stateData) else { return }
            applyMarkdownNotes(to: &state, in: notesDirectoryURL)
            loadedState = state
        }
        return loadedState
    }

    func canAccessSharedStorage() -> Bool {
        configuredSyncFolderURL() != nil || iCloudDocumentsDirectoryURL != nil
    }

    func setSyncFolder(_ folderURL: URL) -> Bool {
        let accessGranted = folderURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        // Some File Provider URLs fail with one bookmark flavor but work with another.
        let bookmarkOptions: [URL.BookmarkCreationOptions] = [.minimalBookmark, []]
        for options in bookmarkOptions {
            do {
                let bookmarkData = try folderURL.bookmarkData(
                    options: options,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(bookmarkData, forKey: syncFolderBookmarkKey)
                return true
            } catch {
                continue
            }
        }

        return false
    }

    func clearSyncFolder() {
        UserDefaults.standard.removeObject(forKey: syncFolderBookmarkKey)
    }

    func syncFolderName() -> String? {
        configuredSyncFolderURL()?.lastPathComponent
    }

    func syncFolderURL() -> URL? {
        configuredSyncFolderURL() ?? iCloudDocumentsDirectoryURL
    }

    private var iCloudDocumentsDirectoryURL: URL? {
        guard let containerURL = fileManager.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let documentsURL = containerURL.appendingPathComponent("Documents", isDirectory: true)
        try? fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        return documentsURL
    }

    private var localDocumentsDirectoryURL: URL {
        if let url = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            return url
        }
        return fileManager.temporaryDirectory
    }

    private var localNotesDirectoryURL: URL {
        localDocumentsDirectoryURL.appendingPathComponent(notesDirectoryName, isDirectory: true)
    }

    private func configuredSyncFolderURL() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: syncFolderBookmarkKey) else {
            return nil
        }
        var isStale = false
        let resolutionOptions: [URL.BookmarkResolutionOptions] = [[], .withoutUI]

        var resolvedFolderURL: URL? = nil
        for options in resolutionOptions {
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                resolvedFolderURL = url
                break
            }
        }

        guard let folderURL = resolvedFolderURL else {
            return nil
        }

        if isStale {
            let refreshOptions: [URL.BookmarkCreationOptions] = [.minimalBookmark, []]
            for options in refreshOptions {
                if let refreshed = try? folderURL.bookmarkData(
                    options: options,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(refreshed, forKey: syncFolderBookmarkKey)
                    break
                }
            }
        }
        return folderURL
    }

    private func withRemoteDocumentsDirectory(_ body: (URL) -> Void) -> Bool {
        if let configuredFolderURL = configuredSyncFolderURL() {
            let accessGranted = configuredFolderURL.startAccessingSecurityScopedResource()
            defer {
                if accessGranted {
                    configuredFolderURL.stopAccessingSecurityScopedResource()
                }
            }
            body(configuredFolderURL)
            return true
        }

        guard let iCloudDocumentsDirectoryURL else { return false }
        body(iCloudDocumentsDirectoryURL)
        return true
    }

    private func write(_ data: Data, to fileURL: URL) {
        let directoryURL = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func syncMarkdownNotes(for state: AppState, in notesDirectoryURL: URL) {
        try? fileManager.createDirectory(at: notesDirectoryURL, withIntermediateDirectories: true)
        var expectedFilenames: Set<String> = []

        for idea in state.ideas {
            syncNote(
                kind: .idea,
                id: idea.id,
                title: idea.title,
                body: idea.detail,
                notesDirectoryURL: notesDirectoryURL,
                expectedFilenames: &expectedFilenames
            )
        }

        for project in state.projects {
            syncNote(
                kind: .project,
                id: project.id,
                title: project.title,
                body: project.detail,
                notesDirectoryURL: notesDirectoryURL,
                expectedFilenames: &expectedFilenames
            )
        }

        var seenTaskIDs: Set<UUID> = []
        for task in state.tasks + state.scheduledTasks {
            guard seenTaskIDs.insert(task.id).inserted else { continue }
            syncNote(
                kind: .task,
                id: task.id,
                title: task.title,
                body: task.note,
                notesDirectoryURL: notesDirectoryURL,
                expectedFilenames: &expectedFilenames
            )
        }

        for note in state.improvementNotes {
            syncNote(
                kind: .improvement,
                id: note.id,
                title: note.title,
                body: note.detail,
                notesDirectoryURL: notesDirectoryURL,
                expectedFilenames: &expectedFilenames
            )
        }

        cleanupOrphanedNotes(in: notesDirectoryURL, expectedFilenames: expectedFilenames)
    }

    private func syncNote(
        kind: ItemNoteKind,
        id: UUID,
        title: String,
        body: String,
        notesDirectoryURL: URL,
        expectedFilenames: inout Set<String>
    ) {
        let filename = noteFilename(kind: kind, id: id)
        expectedFilenames.insert(filename)

        let fileURL = notesDirectoryURL.appendingPathComponent(filename, isDirectory: false)
        let content = markdownContent(kind: kind, id: id, title: title, body: body)

        if let existingContent = try? String(contentsOf: fileURL, encoding: .utf8),
           existingContent == content {
            return
        }
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func cleanupOrphanedNotes(in notesDirectoryURL: URL, expectedFilenames: Set<String>) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: notesDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for fileURL in files where fileURL.pathExtension.lowercased() == "md" {
            let filename = fileURL.lastPathComponent
            let hasKnownPrefix = ItemNoteKind.allCases.contains { filename.hasPrefix("\($0.filePrefix)-") }
            guard hasKnownPrefix, !expectedFilenames.contains(filename) else { continue }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func applyMarkdownNotes(to state: inout AppState, in notesDirectoryURL: URL) {
        for index in state.ideas.indices {
            guard let note = loadNote(kind: .idea, id: state.ideas[index].id, notesDirectoryURL: notesDirectoryURL) else { continue }
            if let title = note.title, !title.isEmpty {
                state.ideas[index].title = title
            }
            state.ideas[index].detail = note.body
        }

        for index in state.projects.indices {
            guard let note = loadNote(kind: .project, id: state.projects[index].id, notesDirectoryURL: notesDirectoryURL) else { continue }
            if let title = note.title, !title.isEmpty {
                state.projects[index].title = title
            }
            state.projects[index].detail = note.body
        }

        for index in state.tasks.indices {
            guard let note = loadNote(kind: .task, id: state.tasks[index].id, notesDirectoryURL: notesDirectoryURL) else { continue }
            if let title = note.title, !title.isEmpty {
                state.tasks[index].title = title
            }
            state.tasks[index].note = note.body
        }

        for index in state.scheduledTasks.indices {
            guard let note = loadNote(kind: .task, id: state.scheduledTasks[index].id, notesDirectoryURL: notesDirectoryURL) else { continue }
            if let title = note.title, !title.isEmpty {
                state.scheduledTasks[index].title = title
            }
            state.scheduledTasks[index].note = note.body
        }

        for index in state.improvementNotes.indices {
            guard let note = loadNote(kind: .improvement, id: state.improvementNotes[index].id, notesDirectoryURL: notesDirectoryURL) else { continue }
            if let title = note.title, !title.isEmpty {
                state.improvementNotes[index].title = title
            }
            state.improvementNotes[index].detail = note.body
        }
    }

    private func loadNote(kind: ItemNoteKind, id: UUID, notesDirectoryURL: URL) -> ParsedMarkdownNote? {
        let fileURL = notesDirectoryURL.appendingPathComponent(noteFilename(kind: kind, id: id), isDirectory: false)
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        return parseMarkdown(content)
    }

    private func noteFilename(kind: ItemNoteKind, id: UUID) -> String {
        "\(kind.filePrefix)-\(id.uuidString.lowercased()).md"
    }

    private func markdownContent(kind: ItemNoteKind, id: UUID, title: String, body: String) -> String {
        let sanitizedTitle = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        ---
        id: \(id.uuidString.lowercased())
        kind: \(kind.rawValue)
        ---
        # \(sanitizedTitle.isEmpty ? "Untitled" : sanitizedTitle)

        \(normalizedBody)
        """
    }

    private func parseMarkdown(_ markdown: String) -> ParsedMarkdownNote {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        if lines.first == "---" {
            index = 1
            while index < lines.count, lines[index] != "---" {
                index += 1
            }
            if index < lines.count {
                index += 1
            }
        }

        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }

        var title: String? = nil
        if index < lines.count, lines[index].hasPrefix("# ") {
            let value = String(lines[index].dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            title = value.isEmpty ? nil : value
            index += 1
        }

        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }

        let body = index < lines.count
            ? lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        return ParsedMarkdownNote(title: title, body: body)
    }

    private func encode(_ state: AppState) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(state)
    }

    private func bestLocalStateData() -> Data? {
        let candidates = [
            UserDefaults.standard.data(forKey: localKey),
            UserDefaults.standard.data(forKey: localBackupKey)
        ].compactMap { $0 }
        return candidates.first(where: { decode(from: $0) != nil })
    }

    private func decode(from data: Data) -> AppState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let state = try? decoder.decode(AppState.self, from: data) {
            return state
        }
        guard let legacyState = try? decoder.decode(LegacyAppState.self, from: data) else {
            return nil
        }
        return AppState(
            selectedTab: legacyState.selectedTab,
            ideas: legacyState.ideas,
            projects: legacyState.projects,
            tasks: legacyState.tasks,
            scheduledTasks: legacyState.scheduledTasks,
            tasksSeries: legacyState.tasksSeries
        )
    }
}

@MainActor
private final class AppStateStore: ObservableObject {
    @Published var selectedTab: AppTab = .guide
    @Published var ideas: [IdeaItem] = []
    @Published var projects: [ProjectItem] = []
    @Published var tasks: [TaskItem] = []
    @Published var completedTasksArchive: [TaskItem] = []
    @Published var scheduledTasks: [TaskItem] = []
    @Published var tasksSeries: [RecurringSeries] = []
    @Published var improvementNotes: [ImprovementNote] = []
    @Published var dailyCapacityMinutes: Int = defaultDailyCapacityMinutes
    @Published var syncFolderName: String? = nil

    private var cancellables: Set<AnyCancellable> = []
    private var cloudSyncTask: Task<Void, Never>? = nil
    private var lastModifiedAt: Date = .distantPast

    init() {
        load()
        refreshSyncFolderName()
        autosaveChanges()
        startCloudRefreshLoop()
    }

    deinit {
        cloudSyncTask?.cancel()
    }

    func snapshot() -> AppState {
        AppState(
            selectedTab: selectedTab,
            ideas: ideas,
            projects: projects,
            tasks: tasks,
            completedTasksArchive: completedTasksArchive,
            scheduledTasks: scheduledTasks,
            tasksSeries: tasksSeries,
            improvementNotes: improvementNotes,
            dailyCapacityMinutes: dailyCapacityMinutes,
            lastModifiedAt: lastModifiedAt
        )
    }

    func apply(_ state: AppState) {
        selectedTab = state.selectedTab
        ideas = state.ideas
        projects = state.projects
        tasks = state.tasks
        completedTasksArchive = state.completedTasksArchive
        scheduledTasks = state.scheduledTasks
        tasksSeries = state.tasksSeries
        improvementNotes = state.improvementNotes
        dailyCapacityMinutes = max(1, state.dailyCapacityMinutes)
        lastModifiedAt = state.lastModifiedAt
    }

    func save() {
        var state = snapshot()
        let now = Date()
        state.lastModifiedAt = max(state.lastModifiedAt, now)
        lastModifiedAt = state.lastModifiedAt
        AppStatePersistence.shared.save(state)
    }

    func selectSyncFolder(_ folderURL: URL) -> Bool {
        let didSetFolder = AppStatePersistence.shared.setSyncFolder(folderURL)
        guard didSetFolder else { return false }
        refreshSyncFolderName()
        refreshFromCloudIfNeeded()
        save()
        return true
    }

    func clearSelectedSyncFolder() {
        AppStatePersistence.shared.clearSyncFolder()
        refreshSyncFolderName()
        save()
    }

    func syncFolderURL() -> URL? {
        AppStatePersistence.shared.syncFolderURL()
    }

    func refreshFromCloudIfNeeded() {
        guard let cloudState = AppStatePersistence.shared.loadFromCloud() else {
            if AppStatePersistence.shared.canAccessSharedStorage() {
                AppStatePersistence.shared.save(snapshot())
            }
            return
        }

        let localState = snapshot()

        if cloudState.lastModifiedAt > localState.lastModifiedAt {
            if cloudState != localState {
                apply(cloudState)
            }
            return
        }

        if cloudState.lastModifiedAt < localState.lastModifiedAt {
            AppStatePersistence.shared.save(localState)
            return
        }

        if cloudState != localState {
            // Same timestamp but different data: keep local to avoid dropping recent in-memory edits.
            AppStatePersistence.shared.save(localState)
            return
        }
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

    private func refreshSyncFolderName() {
        syncFolderName = AppStatePersistence.shared.syncFolderName()
    }

    private func autosaveChanges() {
        objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.save()
            }
            .store(in: &cancellables)
    }

    private func startCloudRefreshLoop() {
        cloudSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self?.refreshFromCloudIfNeeded()
            }
        }
    }
}

@MainActor
private final class LocationActivationManager: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = LocationActivationManager()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var currentLocation: CLLocation? = nil
    @Published private(set) var lastEventAt: Date = .distantPast

    private let manager = CLLocationManager()
    private let regionPrefix = "task-geofence-"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = true
        authorizationStatus = manager.authorizationStatus
    }

    func requestAlwaysAuthorization() {
        guard CLLocationManager.locationServicesEnabled() else { return }

        switch authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            startLocationServicesIfPossible()
        case .authorizedAlways:
            startLocationServicesIfPossible()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }

        refreshCurrentLocation()
    }

    func refreshCurrentLocation() {
        guard isAuthorized else { return }
        manager.requestLocation()
    }

    func updateActivationRegions(for tasks: [TaskItem]) {
        authorizationStatus = manager.authorizationStatus
        guard CLLocationManager.locationServicesEnabled() else { return }

        let eligibleTasks = tasks
            .filter { $0.locationTrigger != nil }
            .sorted { left, right in
                let leftDate = left.scheduledDate ?? .distantFuture
                let rightDate = right.scheduledDate ?? .distantFuture
                if leftDate != rightDate {
                    return leftDate < rightDate
                }
                return left.createdAt < right.createdAt
            }

        let desiredIDs = Set(eligibleTasks.prefix(20).map { regionIdentifier(for: $0.id) })

        for region in manager.monitoredRegions where region.identifier.hasPrefix(regionPrefix) {
            guard !desiredIDs.contains(region.identifier) else { continue }
            manager.stopMonitoring(for: region)
        }

        guard isAuthorized else { return }

        for task in eligibleTasks.prefix(20) {
            guard manager.monitoredRegions.contains(where: { $0.identifier == regionIdentifier(for: task.id) }) == false else {
                continue
            }
            guard let region = circularRegion(for: task) else { continue }
            manager.startMonitoring(for: region)
        }

        startLocationServicesIfPossible()
    }

    func canActivate(_ task: TaskItem) -> Bool {
        guard let locationTrigger = task.locationTrigger else { return true }
        guard let currentLocation else { return false }
        return locationTrigger.contains(currentLocation)
    }

    private var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func startLocationServicesIfPossible() {
        guard isAuthorized else { return }

        if authorizationStatus == .authorizedAlways {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.startUpdatingLocation()
        }
    }

    private func circularRegion(for task: TaskItem) -> CLCircularRegion? {
        guard let trigger = task.locationTrigger else { return nil }
        let maxDistance = manager.maximumRegionMonitoringDistance
        let radius: CLLocationDistance
        if maxDistance > 0 {
            radius = min(trigger.monitoringRadius, maxDistance)
        } else {
            radius = trigger.monitoringRadius
        }

        let region = CLCircularRegion(
            center: trigger.center.coordinate,
            radius: radius,
            identifier: regionIdentifier(for: task.id)
        )
        region.notifyOnEntry = true
        region.notifyOnExit = false
        return region
    }

    private func regionIdentifier(for taskID: UUID) -> String {
        "\(regionPrefix)\(taskID.uuidString)"
    }

    private func registerEvent() {
        lastEventAt = Date()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if isAuthorized {
            startLocationServicesIfPossible()
            refreshCurrentLocation()
        }
        registerEvent()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        currentLocation = latest
        registerEvent()
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier.hasPrefix(regionPrefix) else { return }
        refreshCurrentLocation()
        registerEvent()
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        registerEvent()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        registerEvent()
    }
}

struct ContentView: View {
    private enum ScheduledSheetFollowUpAction {
        case editTask(TaskItem)
        case editNote(TaskItem)
    }

    @StateObject private var store = AppStateStore()
    @StateObject private var locationManager = LocationActivationManager.shared

    @State private var showingAddIdeaSheet = false
    @State private var showingAddTaskSheet = false
    @State private var showingSeriesSheet = false
    @State private var showingScheduledSheet = false
    @State private var showingImprovementNotesSheet = false
    @State private var editingIdea: IdeaItem? = nil
    @State private var editingIdeaNote: IdeaItem? = nil
    @State private var editingTask: TaskItem? = nil
    @State private var editingScheduledTask: TaskItem? = nil
    @State private var editingProjectNote: ProjectItem? = nil
    @State private var editingTaskNote: TaskItem? = nil
    @State private var showingResetAlert = false
    @State private var showingSyncFolderPicker = false
    @State private var showingSyncFolderError = false
    @State private var syncFolderErrorMessage = ""
    @State private var showingProjectCapacityAlert = false
    @State private var projectCapacityAlertMessage = ""
    @State private var scheduledSheetFollowUpAction: ScheduledSheetFollowUpAction? = nil

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    private let dailyCapacityOptions = [60, 90, 120, 180, 240, 300, 360, 480]
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private func dailyCapacityLabel(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return "\(hours) \(hours == 1 ? "hour" : "hours")/day"
        }
        return "\(minutes) minutes/day"
    }

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
                            onEditNote: { editingIdeaNote = $0 },
                            onEdit: { editingIdea = $0 },
                            onAddTapped: { showingAddIdeaSheet = true }
                        )
                    case .tasks:
                        TasksListView(
                            tasks: $store.tasks,
                            dailyCapacityMinutes: store.dailyCapacityMinutes,
                            initialMapCenter: initialMapCenter,
                            onComplete: completeTask,
                            onAddTapped: { showingAddTaskSheet = true },
                            onShowSeries: { showingSeriesSheet = true },
                            onShowScheduled: { showingScheduledSheet = true },
                            onSaveTask: updateTask,
                            onEditNote: { editingTaskNote = $0 },
                            onDelete: deleteTask
                        )
                    case .projects:
                        ProjectsView(
                            projects: $store.projects,
                            onMoveToIdeas: moveProjectToIdeas,
                            onEditNote: { editingProjectNote = $0 },
                            onComplete: completeProject,
                            onUpdateCategory: updateProjectCategory
                        )
                    case .guide:
                        GuideView(
                            tasks: $store.tasks,
                            projects: $store.projects,
                            dailyCapacityMinutes: store.dailyCapacityMinutes,
                            onCompleteTask: completeTask,
                            onCompleteSubtask: completeSubtask,
                            onMarkWorked: markTaskWorked,
                            onHoldTask: holdTask,
                            onEditNote: { editingTaskNote = $0 },
                            onMoveProjectToIdeas: moveProjectToIdeas,
                            onEditProjectNote: { editingProjectNote = $0 },
                            onCompleteProject: completeProject
                        )
                    }
                }
            }
            .navigationTitle("TwoDoList")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingImprovementNotesSheet = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("Improvement notes (\(store.improvementNotes.count))")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let syncFolderName = store.syncFolderName {
                            Label("Sync folder: \(syncFolderName)", systemImage: "folder")
                        }

                        Button {
                            showingSyncFolderPicker = true
                        } label: {
                            Label("Choose sync folder", systemImage: "folder.badge.plus")
                        }

                        Button {
                            openSyncFolder()
                        } label: {
                            Label("Open sync folder", systemImage: "folder")
                        }

                        Section("Daily capacity") {
                            Picker("Daily capacity", selection: $store.dailyCapacityMinutes) {
                                ForEach(dailyCapacityOptions, id: \.self) { option in
                                    Text(dailyCapacityLabel(option)).tag(option)
                                }
                            }
                        }

                        if store.syncFolderName != nil {
                            Button {
                                store.clearSelectedSyncFolder()
                            } label: {
                                Label("Use automatic sync", systemImage: "icloud")
                            }
                        }

                        Button {
                            showingImprovementNotesSheet = true
                        } label: {
                            Label(
                                "Improvement notes (\(store.improvementNotes.count))",
                                systemImage: "square.and.pencil"
                            )
                        }

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
                AddTaskSheet(
                    parentTasks: parentTaskCandidates,
                    dependencyOptions: taskDependencyOptions(),
                    initialMapCenter: initialMapCenter,
                    dailyCapacityMinutes: store.dailyCapacityMinutes
                ) { task, scheduleOnly in
                    addTask(task, scheduleOnly: scheduleOnly)
                }
            }
            .sheet(isPresented: $showingSeriesSheet) {
                RecurringSeriesView(
                    series: $store.tasksSeries,
                    tasks: $store.tasks,
                    scheduledTasks: $store.scheduledTasks,
                    initialMapCenter: initialMapCenter,
                    dailyCapacityMinutes: store.dailyCapacityMinutes
                )
            }
            .sheet(isPresented: $showingScheduledSheet) {
                ScheduledTasksView(
                    scheduledTasks: $store.scheduledTasks,
                    dailyCapacityMinutes: store.dailyCapacityMinutes,
                    onEdit: { queueScheduledSheetFollowUp(.editTask($0)) },
                    onEditNote: { queueScheduledSheetFollowUp(.editNote($0)) }
                )
            }
            .sheet(isPresented: $showingImprovementNotesSheet) {
                ImprovementNotesView(notes: $store.improvementNotes)
            }
            .sheet(isPresented: $showingSyncFolderPicker) {
                SyncFolderPicker(
                    onPick: { folderURL in
                        showingSyncFolderPicker = false
                        if !store.selectSyncFolder(folderURL) {
                            syncFolderErrorMessage = "Could not save this folder for sync access. Please pick another iCloud Drive folder."
                            showingSyncFolderError = true
                        }
                    },
                    onCancel: {
                        showingSyncFolderPicker = false
                    }
                )
            }
            .sheet(item: $editingIdea) { idea in
                EditIdeaSheet(idea: idea) { updated in
                    updateIdea(updated)
                }
            }
            .sheet(item: $editingIdeaNote) { idea in
                IdeaNoteEditorSheet(idea: idea) { note in
                    updateIdeaNote(for: idea, note: note)
                }
            }
            .sheet(item: $editingTask) { task in
                EditTaskSheet(
                    task: task,
                    parentTasks: parentTaskCandidates(excludingTaskID: task.id),
                    dependencyOptions: taskDependencyOptions(excludingReference: DependencyReference(taskID: task.id)),
                    initialMapCenter: initialMapCenter,
                    dailyCapacityMinutes: store.dailyCapacityMinutes
                ) { updated in
                    updateTask(updated)
                }
            }
            .sheet(item: $editingScheduledTask) { task in
                EditTaskSheet(
                    task: task,
                    parentTasks: parentTaskCandidates(excludingTaskID: task.id),
                    dependencyOptions: taskDependencyOptions(excludingReference: DependencyReference(taskID: task.id)),
                    initialMapCenter: initialMapCenter,
                    dailyCapacityMinutes: store.dailyCapacityMinutes
                ) { updated in
                    updateScheduledTask(updated)
                }
            }
            .sheet(item: $editingProjectNote) { project in
                ProjectNoteEditorSheet(project: project) { note in
                    updateProjectNote(for: project, note: note)
                }
            }
            .sheet(item: $editingTaskNote) { task in
                TaskNoteEditorSheet(task: task) { note in
                    updateTaskNote(for: task, note: note)
                }
            }
            .alert("Reset all data?", isPresented: $showingResetAlert) {
                Button("Reset", role: .destructive) {
                    store.reset()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes all tasks, ideas, work area items, recurring series, and improvement notes from this device.")
            }
            .alert("Sync folder error", isPresented: $showingSyncFolderError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(syncFolderErrorMessage)
            }
            .alert("Projects tab limit", isPresented: $showingProjectCapacityAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(projectCapacityAlertMessage)
            }
            .onAppear {
                store.refreshFromCloudIfNeeded()
                enforceProjectsTabLimits()
                NotificationManager.shared.requestAuthorization()
                NotificationManager.shared.scheduleDailyReminders()
                locationManager.requestAlwaysAuthorization()
                pruneArchivedParentTasks()
                syncDependencyHolds()
                processScheduledTasks()
                processRecurringSeries()
                updateTaskPriorities()
                resetOnHoldTasksIfNeeded()
                refreshLocationMonitoring()
            }
            .onChange(of: store.scheduledTasks) { _ in
                pruneArchivedParentTasks()
                refreshLocationMonitoring()
            }
            .onChange(of: store.projects) { _ in
                enforceProjectsTabLimits()
            }
            .onChange(of: store.tasksSeries) { _ in
                processRecurringSeries()
            }
            .onChange(of: locationManager.lastEventAt) { _ in
                processScheduledTasks()
                processRecurringSeries()
            }
            .onChange(of: showingScheduledSheet) { isPresented in
                guard !isPresented else { return }
                presentScheduledSheetFollowUpIfNeeded()
            }
            .onChange(of: scenePhase) { newValue in
                if newValue == .active {
                    store.refreshFromCloudIfNeeded()
                    enforceProjectsTabLimits()
                    locationManager.requestAlwaysAuthorization()
                    pruneArchivedParentTasks()
                    syncDependencyHolds()
                    processScheduledTasks()
                    processRecurringSeries()
                    updateTaskPriorities()
                    resetOnHoldTasksIfNeeded()
                    refreshLocationMonitoring()
                }
            }
            .onReceive(refreshTimer) { _ in
                guard scenePhase == .active else { return }
                processScheduledTasks()
                processRecurringSeries()
                resetOnHoldTasksIfNeeded()
                syncDependencyHolds()
            }
        }
    }

    private var parentTaskCandidates: [TaskItem] {
        store.tasks.sorted { left, right in
            taskSortComparator(
                left,
                right,
                dailyCapacityMinutes: store.dailyCapacityMinutes
            )
        }
    }

    private func parentTaskCandidates(excludingTaskID taskID: UUID?) -> [TaskItem] {
        guard let taskID else { return parentTaskCandidates }
        return parentTaskCandidates.filter { $0.id != taskID }
    }

    private func taskDependencyOptions(
        excludingReference: DependencyReference? = nil,
        replacingTask task: TaskItem? = nil
    ) -> [DependencyOption] {
        var tasksSnapshot = store.tasks
        if let task {
            if let index = tasksSnapshot.firstIndex(where: { $0.id == task.id }) {
                tasksSnapshot[index] = task
            } else {
                tasksSnapshot.insert(task, at: 0)
            }
        }

        return dependencyOptions(
            in: tasksSnapshot,
            dailyCapacityMinutes: store.dailyCapacityMinutes,
            excluding: excludingReference
        )
    }

    private var initialMapCenter: CLLocationCoordinate2D? {
        locationManager.currentLocation?.coordinate
    }

    private func queueScheduledSheetFollowUp(_ action: ScheduledSheetFollowUpAction) {
        scheduledSheetFollowUpAction = action
        showingScheduledSheet = false
    }

    private func presentScheduledSheetFollowUpIfNeeded() {
        guard let action = scheduledSheetFollowUpAction else { return }
        scheduledSheetFollowUpAction = nil
        DispatchQueue.main.async {
            switch action {
            case .editTask(let task):
                editingScheduledTask = task
            case .editNote(let task):
                editingTaskNote = task
            }
        }
    }

    private func dependencyStillBlocks(_ reference: DependencyReference) -> Bool {
        if let activeTask = store.tasks.first(where: { $0.id == reference.taskID }) {
            return reference.isTask || activeSubtask(at: reference.descendantIDs, in: activeTask.subtasks) != nil
        }

        if store.completedTasksArchive.contains(where: { $0.id == reference.taskID }) {
            return false
        }

        return true
    }

    private func syncDependencyHolds() {
        for index in store.tasks.indices {
            if let dependency = store.tasks[index].blockingDependency,
               dependencyStillBlocks(dependency) {
                applyStatusChange(to: &store.tasks[index], newStatus: .onHold)
            }
            syncDependencyHolds(in: &store.tasks[index].subtasks)
        }
    }

    private func syncDependencyHolds(in subtasks: inout [SubtaskItem]) {
        for index in subtasks.indices {
            if let dependency = subtasks[index].blockingDependency,
               dependencyStillBlocks(dependency) {
                subtasks[index].status = .onHold
            }
            syncDependencyHolds(in: &subtasks[index].subtasks)
        }
    }

    private func releaseDependencies(completedReference: DependencyReference) {
        for index in store.tasks.indices {
            clearDependencies(matching: completedReference, in: &store.tasks[index])
        }

        for index in store.scheduledTasks.indices {
            clearTaskDependency(matching: completedReference, in: &store.scheduledTasks[index])
        }
    }

    private func clearTaskDependency(
        matching completedReference: DependencyReference,
        in task: inout TaskItem
    ) {
        guard task.blockingDependency == completedReference else { return }
        task.blockingDependency = nil
        if task.status == .onHold, task.onHoldUntil == nil {
            applyStatusChange(to: &task, newStatus: .active)
        }
    }

    private func clearDependencies(
        matching completedReference: DependencyReference,
        in task: inout TaskItem
    ) {
        clearTaskDependency(matching: completedReference, in: &task)
        clearDependencies(matching: completedReference, in: &task.subtasks)
    }

    private func clearDependencies(
        matching completedReference: DependencyReference,
        in subtasks: inout [SubtaskItem]
    ) {
        for index in subtasks.indices {
            if subtasks[index].blockingDependency == completedReference {
                subtasks[index].blockingDependency = nil
                if subtasks[index].status == .onHold {
                    subtasks[index].status = .active
                }
            }
            clearDependencies(matching: completedReference, in: &subtasks[index].subtasks)
        }
    }

    private func refreshLocationMonitoring() {
        locationManager.updateActivationRegions(for: store.scheduledTasks)
    }

    private func addTask(_ task: TaskItem, scheduleOnly: Bool) {
        if scheduleOnly {
            store.scheduledTasks.insert(task, at: 0)
        } else {
            var unscheduledTask = task
            unscheduledTask.scheduledParentTaskID = nil
            store.tasks.insert(unscheduledTask, at: 0)
        }
        syncDependencyHolds()
        refreshLocationMonitoring()
    }

    private func makeSeriesTask(_ series: RecurringSeries, activationDate: Date) -> TaskItem {
        let dueDate = series.dueDateOffsetDays.flatMap { offset in
            Calendar.current.date(byAdding: .day, value: offset, to: activationDate)
        }
        return TaskItem(
            title: series.title,
            priority: series.priority,
            dueDate: dueDate,
            estimatedMinutes: series.estimatedMinutes,
            status: .active,
            createdAt: activationDate,
            lastPriorityBumpDate: activationDate,
            scheduledDate: series.locationTrigger == nil ? nil : activationDate,
            seriesID: series.id,
            locationTrigger: series.locationTrigger
        )
    }

    private func deleteIdeas(at offsets: IndexSet) {
        store.ideas.remove(atOffsets: offsets)
    }

    private func deleteIdea(_ idea: IdeaItem) {
        store.ideas.removeAll { $0.id == idea.id }
    }

    private func deleteTask(_ task: TaskItem) {
        store.tasks.removeAll { $0.id == task.id }
        store.completedTasksArchive.removeAll { $0.id == task.id }
        store.scheduledTasks.removeAll { $0.id == task.id }
        pruneArchivedParentTasks()
        refreshLocationMonitoring()
    }

    private func updateIdea(_ idea: IdeaItem) {
        guard let index = store.ideas.firstIndex(where: { $0.id == idea.id }) else { return }
        store.ideas[index] = idea
    }

    private func updateIdeaNote(for idea: IdeaItem, note: String) {
        guard let index = store.ideas.firstIndex(where: { $0.id == idea.id }) else { return }
        store.ideas[index].detail = note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateTask(_ task: TaskItem) {
        guard let index = store.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        if task.scheduledDate != nil {
            store.tasks.remove(at: index)
            store.scheduledTasks.insert(task, at: 0)
        } else {
            var updatedTask = task
            updatedTask.scheduledParentTaskID = nil
            store.tasks[index] = updatedTask
        }
        syncDependencyHolds()
        refreshLocationMonitoring()
    }

    private func updateScheduledTask(_ task: TaskItem) {
        guard let index = store.scheduledTasks.firstIndex(where: { $0.id == task.id }) else { return }
        if task.scheduledDate == nil {
            store.scheduledTasks.remove(at: index)
            var unscheduledTask = task
            unscheduledTask.scheduledParentTaskID = nil
            store.tasks.insert(unscheduledTask, at: 0)
        } else {
            store.scheduledTasks[index] = task
        }
        syncDependencyHolds()
        refreshLocationMonitoring()
    }

    private func updateTaskNote(for task: TaskItem, note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = store.tasks.firstIndex(where: { $0.id == task.id }) {
            store.tasks[index].note = trimmed
        }
        if let index = store.scheduledTasks.firstIndex(where: { $0.id == task.id }) {
            store.scheduledTasks[index].note = trimmed
        }
    }

    private func updateProjectNote(for project: ProjectItem, note: String) {
        guard let index = store.projects.firstIndex(where: { $0.id == project.id }) else { return }
        store.projects[index].detail = note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateProjectCategory(for project: ProjectItem, category: IdeaCategory) {
        guard let index = store.projects.firstIndex(where: { $0.id == project.id }) else { return }
        guard store.projects[index].category != category else { return }
        guard canPlaceInProjectsTab(category, excludingProjectID: project.id) else {
            presentProjectsCapacityAlert(for: category)
            return
        }
        store.projects[index].category = category
    }

    private func moveIdeaToProject(_ idea: IdeaItem) {
        guard let index = store.ideas.firstIndex(where: { $0.id == idea.id }) else { return }
        let item = store.ideas[index]
        guard canPlaceInProjectsTab(item.category) else {
            presentProjectsCapacityAlert(for: item.category)
            return
        }
        store.ideas.remove(at: index)
        store.projects.insert(
            ProjectItem(
                id: item.id,
                title: item.title,
                detail: item.detail,
                category: item.category
            ),
            at: 0
        )
    }

    private func moveProjectToIdeas(_ project: ProjectItem) {
        guard let index = store.projects.firstIndex(where: { $0.id == project.id }) else { return }
        let item = store.projects.remove(at: index)
        store.ideas.insert(
            IdeaItem(
                id: item.id,
                title: item.title,
                detail: item.detail,
                category: item.category
            ),
            at: 0
        )
    }

    private func completeTask(_ task: TaskItem) {
        guard !hasActiveDescendants(task) else { return }
        store.tasks.removeAll { $0.id == task.id }
        let hasPendingScheduledSubtasks = store.scheduledTasks.contains { $0.scheduledParentTaskID == task.id }
        if hasPendingScheduledSubtasks {
            store.completedTasksArchive.removeAll { $0.id == task.id }
            store.completedTasksArchive.insert(task, at: 0)
        }
        releaseDependencies(completedReference: DependencyReference(taskID: task.id))
        pruneArchivedParentTasks()
        syncDependencyHolds()
    }

    private func completeSubtask(_ reference: DependencyReference) {
        guard !reference.isTask else { return }
        guard let taskIndex = store.tasks.firstIndex(where: { $0.id == reference.taskID }) else { return }
        guard let candidate = activeSubtask(at: reference.descendantIDs, in: store.tasks[taskIndex].subtasks),
              !hasActiveDescendants(candidate),
              var completedSubtask = removeSubtask(in: &store.tasks[taskIndex].subtasks, at: reference.descendantIDs) else {
            return
        }
        completedSubtask.completedAt = Date()
        let parentReference = reference.parent ?? DependencyReference(taskID: reference.taskID)
        _ = appendCompletedChild(completedSubtask, to: parentReference, in: &store.tasks[taskIndex])
        releaseDependencies(completedReference: reference)
        syncDependencyHolds()
    }

    private func markTaskWorked(_ task: TaskItem) {
        guard let index = store.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let planningState = taskPlanningState(
            for: store.tasks[index],
            dailyCapacityMinutes: store.dailyCapacityMinutes
        )
        guard !planningState.mustStartNow else { return }
        store.tasks[index].lastWorkedAt = Date()
    }

    private func openSyncFolder() {
        guard let folderURL = store.syncFolderURL() else {
            syncFolderErrorMessage = "No sync folder is configured yet. Choose an iCloud Drive folder first."
            showingSyncFolderError = true
            return
        }
        openURL(folderURL) { accepted in
            guard !accepted else { return }
            syncFolderErrorMessage = "Could not open the sync folder on this device."
            showingSyncFolderError = true
        }
    }

    private func holdTask(_ task: TaskItem, timeoutUntil: Date?) {
        guard let index = store.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        if let timeoutUntil {
            applyTimedHold(to: &store.tasks[index], holdUntil: timeoutUntil)
        } else {
            applyStatusChange(to: &store.tasks[index], newStatus: .onHold)
            store.tasks[index].onHoldUntil = nil
        }
        syncDependencyHolds()
    }

    private func completeProject(_ project: ProjectItem) {
        store.projects.removeAll { $0.id == project.id }
    }

    private func canPlaceInProjectsTab(_ category: IdeaCategory, excludingProjectID: UUID? = nil) -> Bool {
        let candidateProjects = store.projects.filter { project in
            guard let excludingProjectID else { return true }
            return project.id != excludingProjectID
        }

        switch category {
        case .snack:
            return true
        case .quest:
            return !candidateProjects.contains { $0.category == .quest }
        case .project:
            return candidateProjects.filter { $0.category == .project }.count < 2
        }
    }

    private func presentProjectsCapacityAlert(for category: IdeaCategory) {
        switch category {
        case .snack:
            return
        case .quest:
            projectCapacityAlertMessage = "Projects tab can hold only one quest at a time."
        case .project:
            projectCapacityAlertMessage = "Projects tab can hold only two projects at a time."
        }
        showingProjectCapacityAlert = true
    }

    private func enforceProjectsTabLimits() {
        var questCount = 0
        var projectCount = 0
        var keptProjects: [ProjectItem] = []
        var overflowProjects: [ProjectItem] = []

        for item in store.projects {
            switch item.category {
            case .snack:
                keptProjects.append(item)
            case .quest:
                if questCount < 1 {
                    questCount += 1
                    keptProjects.append(item)
                } else {
                    overflowProjects.append(item)
                }
            case .project:
                if projectCount < 2 {
                    projectCount += 1
                    keptProjects.append(item)
                } else {
                    overflowProjects.append(item)
                }
            }
        }

        guard !overflowProjects.isEmpty else { return }
        store.projects = keptProjects
        for item in overflowProjects.reversed() {
            store.ideas.insert(
                IdeaItem(
                    id: item.id,
                    title: item.title,
                    detail: item.detail,
                    category: item.category
                ),
                at: 0
            )
        }
        projectCapacityAlertMessage = "Moved extra quest/project items back to Ideas to keep Projects tab at 1 quest and 2 projects."
        showingProjectCapacityAlert = true
    }

    private func processRecurringSeries() {
        let now = Date()
        let calendar = Calendar.current

        for index in store.tasksSeries.indices {
            let series = store.tasksSeries[index]
            guard let nextDate = nextOccurrence(for: series, calendar: calendar) else { continue }
            guard nextDate <= now else { continue }

            let hasActiveInstance = store.tasks.contains { $0.seriesID == series.id }
            let hasScheduledInstance = store.scheduledTasks.contains { $0.seriesID == series.id }
            if hasActiveInstance || hasScheduledInstance {
                NotificationManager.shared.sendSeriesPendingReminder(
                    title: series.title,
                    seriesID: series.id
                )
                continue
            }

            var item = makeSeriesTask(series, activationDate: nextDate)
            item.scheduledDate = series.locationTrigger == nil ? nil : nextDate

            if item.locationTrigger != nil, locationManager.canActivate(item) {
                item.scheduledDate = nil
                item.locationTrigger = nil
                store.tasks.insert(item, at: 0)
                NotificationManager.shared.sendLocationActivationReminder(title: item.title, taskID: item.id)
            } else if item.locationTrigger != nil {
                store.scheduledTasks.insert(item, at: 0)
            } else {
                store.tasks.insert(item, at: 0)
            }

            store.tasksSeries[index].lastGeneratedDate = now
        }

        syncDependencyHolds()
        refreshLocationMonitoring()
    }

    private func processScheduledTasks() {
        let now = Date()
        let indicesToMove = store.scheduledTasks.enumerated().compactMap { index, item -> Int? in
            guard let scheduledDate = item.scheduledDate else { return nil }
            guard scheduledDate <= now else { return nil }
            guard locationManager.canActivate(item) else { return nil }
            return index
        }

        guard !indicesToMove.isEmpty else { return }

        for index in indicesToMove.sorted(by: >) {
            var item = store.scheduledTasks.remove(at: index)
            item.scheduledDate = nil
            let activatedFromLocation = item.locationTrigger != nil
            item.locationTrigger = nil
            if let parentTaskID = item.scheduledParentTaskID {
                spawnScheduledSubtask(item, parentTaskID: parentTaskID)
            } else {
                item.scheduledParentTaskID = nil
                applyStatusChange(to: &item, newStatus: .active)
                store.tasks.insert(item, at: 0)
            }
            if activatedFromLocation {
                NotificationManager.shared.sendLocationActivationReminder(title: item.title, taskID: item.id)
            }
        }

        pruneArchivedParentTasks()
        syncDependencyHolds()
        refreshLocationMonitoring()
    }

    private func spawnScheduledSubtask(_ item: TaskItem, parentTaskID: UUID) {
        let generatedSubtask = SubtaskItem(
            title: item.title,
            status: .active,
            dueDate: item.dueDate,
            estimatedMinutes: item.estimatedMinutes,
            note: item.note,
            blockingDependency: item.blockingDependency
        )

        if let parentIndex = store.tasks.firstIndex(where: { $0.id == parentTaskID }) {
            store.tasks[parentIndex].subtasks.append(generatedSubtask)
            return
        }

        if let archivedIndex = store.completedTasksArchive.firstIndex(where: { $0.id == parentTaskID }) {
            var restoredTask = store.completedTasksArchive.remove(at: archivedIndex)
            applyStatusChange(to: &restoredTask, newStatus: .active)
            restoredTask.subtasks.append(generatedSubtask)
            store.tasks.insert(restoredTask, at: 0)
            return
        }

        // If the selected parent no longer exists, fallback to spawning a regular task.
        var unscheduledItem = item
        unscheduledItem.scheduledParentTaskID = nil
        applyStatusChange(to: &unscheduledItem, newStatus: .active)
        store.tasks.insert(unscheduledItem, at: 0)
    }

    private func pruneArchivedParentTasks() {
        let referencedParents = Set(store.scheduledTasks.compactMap { $0.scheduledParentTaskID })
        store.completedTasksArchive.removeAll { !referencedParents.contains($0.id) }
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

    private func resetOnHoldTasksIfNeeded() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: Date())
        let dueThreshold = calendar.date(byAdding: .day, value: 4, to: today) ?? today
        resetOnHoldTasks(in: &store.tasks, now: now, today: today, dueThreshold: dueThreshold, calendar: calendar)
        resetOnHoldTasks(in: &store.scheduledTasks, now: now, today: today, dueThreshold: dueThreshold, calendar: calendar)
    }

    private func resetOnHoldTasks(
        in tasks: inout [TaskItem],
        now: Date,
        today: Date,
        dueThreshold: Date,
        calendar: Calendar
    ) {
        for index in tasks.indices {
            guard tasks[index].status == .onHold else { continue }
            if let dependency = tasks[index].blockingDependency,
               dependencyStillBlocks(dependency) {
                continue
            }
            if let holdUntil = tasks[index].onHoldUntil {
                if now >= holdUntil {
                    applyStatusChange(to: &tasks[index], newStatus: .active, now: now)
                }
                continue
            }
            let dueSoon = tasks[index].dueDate.map { calendar.startOfDay(for: $0) <= dueThreshold } ?? false
            let onHoldSince = tasks[index].onHoldSince ?? today
            let normalizedOnHold = calendar.startOfDay(for: onHoldSince)
            tasks[index].onHoldSince = normalizedOnHold
            let onHoldDays = calendar.dateComponents([.day], from: normalizedOnHold, to: today).day ?? 0
            if dueSoon || onHoldDays >= 4 {
                applyStatusChange(to: &tasks[index], newStatus: .active)
            }
        }
    }

    private func nextOccurrence(for series: RecurringSeries, calendar: Calendar) -> Date? {
        func applyAppearanceTime(to date: Date) -> Date? {
            calendar.date(
                bySettingHour: series.appearanceHour,
                minute: series.appearanceMinute,
                second: 0,
                of: date
            )
        }

        switch series.frequency {
        case .everyDays:
            let interval = max(series.intervalDays, 1)
            guard let day = calendar.date(
                byAdding: .day,
                value: interval,
                to: calendar.startOfDay(for: series.lastGeneratedDate)
            ) else { return nil }
            return applyAppearanceTime(to: day)
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
            guard let nextDate else { return nil }
            return applyAppearanceTime(to: nextDate)
        case .monthly:
            let start = calendar.startOfDay(for: series.lastGeneratedDate)
            guard let day = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
            return applyAppearanceTime(to: day)
        }
    }
}

private struct IdeasListView: View {
    let ideas: [IdeaItem]
    let onMoveToProject: (IdeaItem) -> Void
    let onDelete: (IndexSet) -> Void
    let onDeleteItem: (IdeaItem) -> Void
    let onEditNote: (IdeaItem) -> Void
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
                                    onEditNote(idea)
                                } label: {
                                    Label("Notes", systemImage: "note.text")
                                }
                                .tint(.indigo)

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
    let dailyCapacityMinutes: Int
    let initialMapCenter: CLLocationCoordinate2D?
    let onComplete: (TaskItem) -> Void
    let onAddTapped: () -> Void
    let onShowSeries: () -> Void
    let onShowScheduled: () -> Void
    let onSaveTask: (TaskItem) -> Void
    let onEditNote: (TaskItem) -> Void
    let onDelete: (TaskItem) -> Void
    @State private var selectedTaskID: UUID? = nil
    @State private var isShowingTaskDetails = false

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
                    ForEach(sortedTasks) { task in
                        TaskCardRow(
                            task: task,
                            allTasksSnapshot: tasks,
                            dailyCapacityMinutes: dailyCapacityMinutes,
                            onComplete: onComplete,
                            onEditNote: onEditNote,
                            onShowDetails: { taskID in
                                selectedTaskID = taskID
                                isShowingTaskDetails = true
                            }
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Tasks")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationDestination(isPresented: $isShowingTaskDetails) {
                selectedTaskDetailsDestination
            }
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

    private var sortedTasks: [TaskItem] {
        tasks.sorted { left, right in
            taskSortComparator(
                left,
                right,
                dailyCapacityMinutes: dailyCapacityMinutes
            )
        }
    }

    private func task(for taskID: UUID) -> TaskItem? {
        tasks.first(where: { $0.id == taskID })
    }

    @ViewBuilder
    private var selectedTaskDetailsDestination: some View {
        if let selectedTaskID, let task = task(for: selectedTaskID) {
            TaskDetailsView(
                task: task,
                allTasksSnapshot: tasks,
                initialMapCenter: initialMapCenter,
                dailyCapacityMinutes: dailyCapacityMinutes,
                onSave: onSaveTask,
                onDelete: onDelete
            )
        } else if #available(iOS 17.0, *) {
            ContentUnavailableView("Task not found", systemImage: "exclamationmark.triangle")
        } else {
            UnavailableContentView(title: "Task not found", systemImage: "exclamationmark.triangle")
        }
    }
}

private struct ProjectsView: View {
    @Binding var projects: [ProjectItem]
    let onMoveToIdeas: (ProjectItem) -> Void
    let onEditNote: (ProjectItem) -> Void
    let onComplete: (ProjectItem) -> Void
    let onUpdateCategory: (ProjectItem, IdeaCategory) -> Void

    var body: some View {
        List {
            if projects.isEmpty {
                Section {
                    if #available(iOS 17.0, *) {
                        ContentUnavailableView("No project items yet", systemImage: "tray")
                    } else {
                        UnavailableContentView(title: "No project items yet", systemImage: "tray")
                    }
                }
            } else {
                if let questID = questID, let questBinding = binding(for: questID) {
                    Section("Quest") {
                        ProjectRow(
                            project: questBinding,
                            onMoveToIdeas: onMoveToIdeas,
                            onEditNote: onEditNote,
                            onComplete: onComplete,
                            onUpdateCategory: onUpdateCategory
                        )
                    }
                }

                Section("Projects") {
                    if projectIDs.isEmpty {
                        Text("No active projects in the tab.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(projectIDs, id: \.self) { projectID in
                            if let projectBinding = binding(for: projectID) {
                                ProjectRow(
                                    project: projectBinding,
                                    onMoveToIdeas: onMoveToIdeas,
                                    onEditNote: onEditNote,
                                    onComplete: onComplete,
                                    onUpdateCategory: onUpdateCategory
                                )
                            }
                        }
                    }
                }

                Section("Snacks") {
                    if snackIDs.isEmpty {
                        Text("No snacks in the tab yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snackIDs, id: \.self) { snackID in
                            if let snackBinding = binding(for: snackID) {
                                ProjectRow(
                                    project: snackBinding,
                                    onMoveToIdeas: onMoveToIdeas,
                                    onEditNote: onEditNote,
                                    onComplete: onComplete,
                                    onUpdateCategory: onUpdateCategory
                                )
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var questID: UUID? {
        projects.first(where: { $0.category == .quest })?.id
    }

    private var projectIDs: [UUID] {
        projects.filter { $0.category == .project }.map(\.id)
    }

    private var snackIDs: [UUID] {
        projects.filter { $0.category == .snack }.map(\.id)
    }

    private func binding(for projectID: UUID) -> Binding<ProjectItem>? {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        return $projects[index]
    }
}

private struct GuideView: View {
    @Binding var tasks: [TaskItem]
    @Binding var projects: [ProjectItem]
    let dailyCapacityMinutes: Int
    let onCompleteTask: (TaskItem) -> Void
    let onCompleteSubtask: (DependencyReference) -> Void
    let onMarkWorked: (TaskItem) -> Void
    let onHoldTask: (TaskItem, Date?) -> Void
    let onEditNote: (TaskItem) -> Void
    let onMoveProjectToIdeas: (ProjectItem) -> Void
    let onEditProjectNote: (ProjectItem) -> Void
    let onCompleteProject: (ProjectItem) -> Void
    @State private var guideDayAnchor = Calendar.current.startOfDay(for: Date())
    @State private var projectCycleIndex = 0
    @State private var timeoutTask: TaskItem? = nil
    @State private var timeoutUntil = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    private let dayChangedPublisher = NotificationCenter.default.publisher(for: .NSCalendarDayChanged)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let task = topTask {
                GuideTaskCard(task: task, dailyCapacityMinutes: dailyCapacityMinutes)

                HStack(spacing: 10) {
                    Button {
                        onCompleteTask(task)
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Complete")

                    if !isMustDoNow(task) {
                        Button {
                            onMarkWorked(task)
                        } label: {
                            Image(systemName: "bolt.fill")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Worked")
                    }

                    Button {
                        presentTimeoutSheet(for: task)
                    } label: {
                        Image(systemName: "pause.circle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Timeout")

                    Button {
                        onEditNote(task)
                    } label: {
                        Label("Notes", systemImage: "note.text")
                    }
                    .buttonStyle(.bordered)
                }

                if let pressingSubtask = mostPressingSubtask(for: task) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Most pressing subtask")
                            .font(.headline)
                        GuideSubtaskCard(subtask: pressingSubtask.subtask)
                        Button {
                            onCompleteSubtask(pressingSubtask.reference)
                        } label: {
                            Label("Complete subtask", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(hasActiveDescendants(pressingSubtask.subtask))
                    }
                }

                if tasksUntilProjectsUnlock > 0 {
                    Text("Projects unlock in \(tasksUntilProjectsUnlock) \(tasksUntilProjectsUnlock == 1 ? "task" : "tasks")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(.tertiarySystemBackground)))
                        .accessibilityLabel("Projects unlock in \(tasksUntilProjectsUnlock) tasks")
                }

                if task.dueDate == nil, task.priority < 5 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Projects")
                            .font(.headline)
                        if let project = guideProject {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(project.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                if !project.detail.isEmpty {
                                    Text(project.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                HStack(spacing: 8) {
                                    Button {
                                        onMoveProjectToIdeas(project)
                                    } label: {
                                        Image(systemName: "arrow.uturn.backward.circle")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityLabel("Move project item back to ideas")

                                    Button {
                                        onEditProjectNote(project)
                                    } label: {
                                        Image(systemName: "note.text")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityLabel("Edit project notes")

                                    Button {
                                        onCompleteProject(project)
                                    } label: {
                                        Image(systemName: "checkmark.circle")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityLabel("Complete project item")

                                    if projects.count > 1 {
                                        Button {
                                            cycleGuideProject()
                                        } label: {
                                            Image(systemName: "arrow.right.circle")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityLabel("Show next project")
                                    }
                                }
                            }
                        } else {
                            Text("No project items ready.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
            } else {
                if #available(iOS 17.0, *) {
                    ContentUnavailableView("No tasks ready", systemImage: "sparkles")
                } else {
                    UnavailableContentView(title: "No tasks ready", systemImage: "sparkles")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Lowest hanging fruit")
                    .font(.headline)
                if let quickTask = lowestHangingFruit {
                    GuideTaskCard(task: quickTask, dailyCapacityMinutes: dailyCapacityMinutes)

                    HStack(spacing: 10) {
                        Button {
                            onCompleteTask(quickTask)
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Complete")

                        Button {
                            presentTimeoutSheet(for: quickTask)
                        } label: {
                            Image(systemName: "pause.circle")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Timeout")

                        Button {
                            onEditNote(quickTask)
                        } label: {
                            Label("Notes", systemImage: "note.text")
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text("No tasks with a time estimate yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            guideDayAnchor = Calendar.current.startOfDay(for: Date())
            projectCycleIndex = normalizedProjectIndex(projectCycleIndex)
        }
        .onReceive(dayChangedPublisher) { _ in
            guideDayAnchor = Calendar.current.startOfDay(for: Date())
        }
        .onChange(of: projects.map(\.id)) { _ in
            projectCycleIndex = normalizedProjectIndex(projectCycleIndex)
        }
        .sheet(item: $timeoutTask) { task in
            GuideTimeoutSheet(
                task: task,
                initialTimeout: timeoutUntil,
                onSetTimeout: { timeout in
                    onHoldTask(task, timeout)
                    timeoutTask = nil
                },
                onSetOnHoldWithoutTimeout: {
                    onHoldTask(task, nil)
                    timeoutTask = nil
                }
            )
        }
    }

    private func presentTimeoutSheet(for task: TaskItem) {
        let now = Date()
        if let existingHoldUntil = task.onHoldUntil, existingHoldUntil > now {
            timeoutUntil = existingHoldUntil
        } else {
            timeoutUntil = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now
        }
        timeoutTask = task
    }

    private var topTask: TaskItem? {
        return availableTasks.sorted { left, right in
            taskSortComparator(
                left,
                right,
                dailyCapacityMinutes: dailyCapacityMinutes,
                referenceDate: guideDayAnchor
            )
        }
        .first
    }

    private var availableTasks: [TaskItem] {
        let calendar = Calendar.current
        let today = guideDayAnchor
        return tasks.filter { task in
            guard task.status == .active else { return false }
            let mustDoNow = isMustDoNow(task)
            if let workedAt = task.lastWorkedAt {
                return mustDoNow || calendar.startOfDay(for: workedAt) != today
            }
            return true
        }
    }

    private func isMustDoNow(_ task: TaskItem) -> Bool {
        taskPlanningState(
            for: task,
            referenceDate: guideDayAnchor,
            dailyCapacityMinutes: dailyCapacityMinutes
        ).mustStartNow
    }

    private var tasksUntilProjectsUnlock: Int {
        availableTasks.filter { task in
            task.dueDate != nil || task.priority >= 5
        }.count
    }

    private var lowestHangingFruit: TaskItem? {
        let estimatedTasks: [(task: TaskItem, minutes: Int)] = availableTasks.compactMap { task in
            guard let minutes = task.estimatedMinutes else { return nil }
            return (task: task, minutes: minutes)
        }

        return estimatedTasks
            .min { left, right in
                if left.minutes != right.minutes {
                    return left.minutes < right.minutes
                }
                return taskSortComparator(
                    left.task,
                    right.task,
                    dailyCapacityMinutes: dailyCapacityMinutes,
                    referenceDate: guideDayAnchor
                )
            }?
            .task
    }

    private var guideProject: ProjectItem? {
        guard !projects.isEmpty else { return nil }
        let index = normalizedProjectIndex(projectCycleIndex)
        guard projects.indices.contains(index) else { return nil }
        return projects[index]
    }

    private func cycleGuideProject() {
        guard projects.count > 1 else { return }
        projectCycleIndex = normalizedProjectIndex(projectCycleIndex + 1)
    }

    private func normalizedProjectIndex(_ index: Int) -> Int {
        guard !projects.isEmpty else { return 0 }
        let count = projects.count
        return ((index % count) + count) % count
    }

    private func mostPressingSubtask(for task: TaskItem) -> ReferencedSubtask? {
        mostPressingActiveSubtaskReference(
            in: task,
            referenceDate: guideDayAnchor,
            dailyCapacityMinutes: dailyCapacityMinutes
        )
    }
}

private struct ImprovementNotesView: View {
    @Binding var notes: [ImprovementNote]

    @Environment(\.dismiss) private var dismiss

    @State private var showingAddSheet = false
    @State private var editingNote: ImprovementNote? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if notes.isEmpty {
                        if #available(iOS 17.0, *) {
                            ContentUnavailableView("No improvement notes yet", systemImage: "square.and.pencil")
                        } else {
                            UnavailableContentView(title: "No improvement notes yet", systemImage: "square.and.pencil")
                        }
                    }

                    ForEach(sortedNotes) { note in
                        ImprovementNoteRow(note: note)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    editingNote = note
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)

                                Button(role: .destructive) {
                                    deleteNote(note)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete(perform: deleteNotes)
                } footer: {
                    Text("Capture ideas for improving the app. Entries and note files sync through your selected shared folder.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Improvement Notes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add note", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddImprovementNoteSheet { note in
                    notes.insert(note, at: 0)
                }
            }
            .sheet(item: $editingNote) { note in
                EditImprovementNoteSheet(note: note) { updated in
                    updateNote(updated)
                }
            }
        }
    }

    private var sortedNotes: [ImprovementNote] {
        notes.sorted { left, right in
            if left.createdAt != right.createdAt {
                return left.createdAt > right.createdAt
            }
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    private func deleteNote(_ note: ImprovementNote) {
        notes.removeAll { $0.id == note.id }
    }

    private func deleteNotes(at offsets: IndexSet) {
        let ids: Set<UUID> = Set(offsets.compactMap { offset in
            guard sortedNotes.indices.contains(offset) else { return nil }
            return sortedNotes[offset].id
        })
        notes.removeAll { ids.contains($0.id) }
    }

    private func updateNote(_ note: ImprovementNote) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index] = note
    }
}

private struct ImprovementNoteRow: View {
    let note: ImprovementNote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.title)
                .font(.headline)

            if !note.detail.isEmpty {
                Text(note.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Text(note.createdAt, style: .date)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
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

private struct SyncFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType.folder],
            asCopy: false
        )
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let folderURL = urls.first else {
                onCancel()
                return
            }
            onPick(folderURL)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

private struct IdeaRow: View {
    let idea: IdeaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(idea.title)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(idea.category.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(idea.category.tintColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(idea.category.tintColor.opacity(0.18)))
            }
            if !idea.detail.isEmpty {
                Text(idea.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct TaskCardRow: View {
    let task: TaskItem
    let allTasksSnapshot: [TaskItem]
    let dailyCapacityMinutes: Int
    let onComplete: (TaskItem) -> Void
    let onEditNote: (TaskItem) -> Void
    let onShowDetails: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(task.title)
                .font(.headline)

            Text(taskSummaryLine(for: task, allTasksSnapshot: allTasksSnapshot, dailyCapacityMinutes: dailyCapacityMinutes))
                .font(.caption)
                .foregroundStyle(task.status == .onHold ? .tertiary : .secondary)
                .lineLimit(2)

            if let urgencyLabel {
                Text(urgencyLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(urgencyColor)
            }

            if activeNodeCount(in: task.subtasks) > 0 || completedNodeCount(in: task.subtaskGraveyard) > 0 {
                Text("\(activeNodeCount(in: task.subtasks)) active descendants • \(completedNodeCount(in: task.subtaskGraveyard)) completed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                completeButton
                noteButton
                detailsButton
            }
        }
        .padding(12)
        .opacity(task.status == .onHold ? 0.6 : 1)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.tertiarySystemBackground)))
    }

    private var completeButton: some View {
        Button {
            onComplete(task)
        } label: {
            Image(systemName: "checkmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(hasActiveDescendants(task))
        .font(.body.weight(.semibold))
        .accessibilityLabel("Complete")
    }

    private var noteButton: some View {
        Button {
            onEditNote(task)
        } label: {
            Image(systemName: "note.text")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .font(.body.weight(.semibold))
        .accessibilityLabel("Notes")
    }

    private var detailsButton: some View {
        Button {
            onShowDetails(task.id)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .font(.body.weight(.semibold))
        .accessibilityLabel("Details")
    }

    private var planningState: TaskPlanningState {
        taskPlanningState(for: task, dailyCapacityMinutes: dailyCapacityMinutes)
    }

    private var descendantSummary: SubtaskPlanningSummary {
        subtaskPlanningSummary(for: task, dailyCapacityMinutes: dailyCapacityMinutes)
    }

    private var urgencyLabel: String? {
        if planningState.mustStartNow || descendantSummary.mustStartNow {
            return "Must start now"
        }
        if planningState.highRiskUnknown || descendantSummary.highRiskUnknown {
            return "High-risk unknown"
        }
        return nil
    }

    private var urgencyColor: Color {
        if planningState.mustStartNow || descendantSummary.mustStartNow {
            return .red
        }
        if planningState.highRiskUnknown || descendantSummary.highRiskUnknown {
            return .orange
        }
        return .secondary
    }
}

private struct TaskDetailsView: View {
    let allTasksSnapshot: [TaskItem]
    let initialMapCenter: CLLocationCoordinate2D?
    let dailyCapacityMinutes: Int
    let onSave: (TaskItem) -> Void
    let onDelete: (TaskItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var draftTask: TaskItem
    @State private var estimateUnit: TaskEstimateUnit
    @State private var showDueDatePicker = false
    @State private var showScheduledDatePicker = false
    @State private var showingLocationEditor = false
    @State private var showingAddSubtaskSheet = false

    init(
        task: TaskItem,
        allTasksSnapshot: [TaskItem],
        initialMapCenter: CLLocationCoordinate2D?,
        dailyCapacityMinutes: Int,
        onSave: @escaping (TaskItem) -> Void,
        onDelete: @escaping (TaskItem) -> Void
    ) {
        self.allTasksSnapshot = allTasksSnapshot
        self.initialMapCenter = initialMapCenter
        self.dailyCapacityMinutes = max(1, dailyCapacityMinutes)
        self.onSave = onSave
        self.onDelete = onDelete
        _draftTask = State(initialValue: task)
        _estimateUnit = State(initialValue: estimateUnitForMinutes(
            for: task.estimatedMinutes,
            dailyCapacityMinutes: max(1, dailyCapacityMinutes)
        ))
    }

    var body: some View {
        Form {
            Section("Details") {
                TextField("Title", text: $draftTask.title)
#if os(iOS)
                    .textInputAutocapitalization(.sentences)
#endif

                Picker("Status", selection: $draftTask.status) {
                    ForEach(WorkingStatus.allCases) { status in
                        Text(status.rawValue).tag(status)
                    }
                }
                .disabled(draftTask.blockingDependency != nil)

                Stepper("Priority \(draftTask.priority)", value: $draftTask.priority, in: 1...5)
                Toggle("Manual must-do now", isOn: $draftTask.isManuallyMustDoNow)

                if draftTask.estimatedMinutes == nil {
                    Text("This task had no estimate. Set one before saving.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker("Estimate unit", selection: $estimateUnit) {
                    ForEach(TaskEstimateUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Has due date", isOn: hasDueDateBinding)
                if draftTask.dueDate != nil {
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

                Toggle("Schedule for later", isOn: isScheduledBinding)
                if draftTask.scheduledDate != nil {
                    Button {
                        showScheduledDatePicker = true
                    } label: {
                        HStack {
                            Text("Scheduled time")
                            Spacer()
                            Text(scheduledDateBinding.wrappedValue.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showScheduledDatePicker) {
                        DatePicker(
                            "Scheduled time",
                            selection: scheduledDateBinding,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                            .onChange(of: scheduledDateBinding.wrappedValue) { _ in
                                showScheduledDatePicker = false
                            }
                            .padding()
                    }

                    if parentTasks.isEmpty {
                        Text("No parent task available. This will spawn as a normal task.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Parent task (optional)", selection: $draftTask.scheduledParentTaskID) {
                            Text("None").tag(UUID?.none)
                            ForEach(parentTasks) { task in
                                Text(task.title).tag(Optional(task.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }

            Section("Dependency") {
                if dependencyOptionsForTask.isEmpty, selectedDependency == nil {
                    Text("No tasks or subtasks available to block on yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Blocked until completion", selection: dependencySelection) {
                        Text("None").tag(String?.none)
                        if let missingDependencyOption {
                            Text("Missing dependency").tag(Optional(missingDependencyOption.id))
                        }
                        ForEach(dependencyOptionsForTask) { option in
                            Text(option.title).tag(Optional(option.id))
                        }
                    }
                    .pickerStyle(.menu)

                    if let selectedDependency {
                        Text("This task stays on hold until \(selectedDependency.title) is completed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if draftTask.scheduledDate != nil {
                Section("Location activation") {
                    Toggle("Activate by location", isOn: locationActivationBinding)

                    if let locationTrigger = draftTask.locationTrigger {
                        Button("Choose activation area") {
                            showingLocationEditor = true
                        }
                        Text(locationTriggerSummary(locationTrigger))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("The task activates the next time you enter this area after the scheduled time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    Text("Subtasks")
                        .font(.headline)
                    Spacer()
                    Button {
                        showingAddSubtaskSheet = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }

                if activeChildReferences.isEmpty {
                    Text("No subtasks yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activeChildReferences) { entry in
                        if let subtaskBinding = subtaskBinding(in: $draftTask, reference: entry.reference) {
                            SubtaskListRow(
                                rootTask: $draftTask,
                                subtask: subtaskBinding,
                                reference: entry.reference,
                                allTasksSnapshot: mergedTasksSnapshot,
                                dailyCapacityMinutes: dailyCapacityMinutes
                            )
                        }
                    }
                }
            }

            Section("Completed") {
                if completedChildReferences.isEmpty {
                    Text("No completed subtasks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(completedChildReferences) { entry in
                        CompletedSubtaskRow(
                            subtask: entry.subtask,
                            onRestore: { restoreCompletedChild(withID: entry.subtask.id) },
                            onDelete: { deleteCompletedChild(withID: entry.subtask.id) }
                        )
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    onDelete(draftTask)
                    dismiss()
                } label: {
                    Label("Delete task", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Task Details")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveTask()
                }
                .disabled(draftTask.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheet(isPresented: $showingLocationEditor) {
            LocationTriggerEditorSheet(
                initialTrigger: draftTask.locationTrigger,
                initialCenter: initialMapCenter
            ) { trigger in
                draftTask.locationTrigger = trigger
            }
        }
        .sheet(isPresented: $showingAddSubtaskSheet) {
            SubtaskEditorSheet(
                subtask: nil,
                dependencyOptions: dependencyOptions(
                    in: mergedTasksSnapshot,
                    dailyCapacityMinutes: dailyCapacityMinutes,
                    excluding: placeholderChildReference(for: taskReference)
                ),
                dailyCapacityMinutes: dailyCapacityMinutes
            ) { newSubtask in
                draftTask.subtasks.append(newSubtask)
            }
        }
        .onChange(of: estimateUnit) { _ in
            draftTask.estimatedMinutes = estimateInMinutes
        }
    }

    private var taskReference: DependencyReference {
        DependencyReference(taskID: draftTask.id)
    }

    private var mergedTasksSnapshot: [TaskItem] {
        mergeTasksSnapshot(allTasksSnapshot, replacing: draftTask)
    }

    private var parentTasks: [TaskItem] {
        mergedTasksSnapshot
            .filter { $0.id != draftTask.id }
            .sorted {
                taskSortComparator(
                    $0,
                    $1,
                    dailyCapacityMinutes: dailyCapacityMinutes
                )
            }
    }

    private var dependencyOptionsForTask: [DependencyOption] {
        dependencyOptions(
            in: mergedTasksSnapshot,
            dailyCapacityMinutes: dailyCapacityMinutes,
            excluding: taskReference
        )
    }

    private var missingDependencyOption: DependencyOption? {
        guard let reference = draftTask.blockingDependency,
              dependencyOptionsForTask.contains(where: { $0.id == reference.id }) == false else {
            return nil
        }

        return DependencyOption(
            reference: reference,
            title: dependencyDescription(for: reference, in: mergedTasksSnapshot),
            subtitle: "Task or subtask no longer exists"
        )
    }

    private var selectedDependency: DependencyOption? {
        guard let dependencyID = draftTask.blockingDependency?.id else { return nil }
        return dependencyOptionsForTask.first(where: { $0.id == dependencyID }) ?? missingDependencyOption
    }

    private var dependencySelection: Binding<String?> {
        Binding(
            get: { draftTask.blockingDependency?.id },
            set: { selectedID in
                if let selectedID {
                    let option = dependencyOptionsForTask.first(where: { $0.id == selectedID }) ?? missingDependencyOption
                    draftTask.blockingDependency = option?.reference
                    if draftTask.blockingDependency != nil {
                        applyStatusChange(to: &draftTask, newStatus: .onHold)
                    }
                } else {
                    draftTask.blockingDependency = nil
                }
            }
        )
    }

    private var hasDueDateBinding: Binding<Bool> {
        Binding(
            get: { draftTask.dueDate != nil },
            set: { hasDueDate in
                draftTask.dueDate = hasDueDate ? (draftTask.dueDate ?? Date()) : nil
            }
        )
    }

    private var dueDateBinding: Binding<Date> {
        Binding(
            get: { draftTask.dueDate ?? Date() },
            set: { draftTask.dueDate = $0 }
        )
    }

    private var isScheduledBinding: Binding<Bool> {
        Binding(
            get: { draftTask.scheduledDate != nil },
            set: { isScheduled in
                if isScheduled {
                    draftTask.scheduledDate = draftTask.scheduledDate ?? Date()
                } else {
                    draftTask.scheduledDate = nil
                    draftTask.scheduledParentTaskID = nil
                    draftTask.locationTrigger = nil
                }
            }
        )
    }

    private var scheduledDateBinding: Binding<Date> {
        Binding(
            get: { draftTask.scheduledDate ?? Date() },
            set: { draftTask.scheduledDate = $0 }
        )
    }

    private var locationActivationBinding: Binding<Bool> {
        Binding(
            get: { draftTask.locationTrigger != nil },
            set: { isEnabled in
                if isEnabled {
                    draftTask.locationTrigger = draftTask.locationTrigger ?? TaskLocationTrigger(
                        center: LocationCoordinate(
                            initialMapCenter
                                ?? CLLocationCoordinate2D(latitude: 47.3769, longitude: 8.5417)
                        ),
                        radiusMeters: 250
                    )
                } else {
                    draftTask.locationTrigger = nil
                }
            }
        )
    }

    private var activeChildReferences: [ReferencedSubtask] {
        directActiveSubtaskReferences(
            of: taskReference,
            in: draftTask,
            dailyCapacityMinutes: dailyCapacityMinutes
        )
    }

    private var completedChildReferences: [ReferencedSubtask] {
        directCompletedSubtaskReferences(of: taskReference, in: draftTask)
    }

    private var estimateInMinutes: Int {
        estimateMinutes(for: estimateUnit, dailyCapacityMinutes: dailyCapacityMinutes)
    }

    private func saveTask() {
        draftTask.title = draftTask.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draftTask.estimatedMinutes = estimateInMinutes
        if draftTask.blockingDependency != nil {
            applyStatusChange(to: &draftTask, newStatus: .onHold)
        }
        onSave(draftTask)
        dismiss()
    }

    private func restoreCompletedChild(withID childID: UUID) {
        guard var restoredChild = removeCompletedChild(withID: childID, from: taskReference, in: &draftTask) else { return }
        restoredChild.completedAt = nil
        _ = appendActiveChild(restoredChild, to: taskReference, in: &draftTask)
    }

    private func deleteCompletedChild(withID childID: UUID) {
        _ = removeCompletedChild(withID: childID, from: taskReference, in: &draftTask)
    }
}

private struct SubtaskListRow: View {
    @Binding var rootTask: TaskItem
    @Binding var subtask: SubtaskItem
    let reference: DependencyReference
    let allTasksSnapshot: [TaskItem]
    let dailyCapacityMinutes: Int

    @State private var showingNoteSheet = false
    @State private var isShowingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subtask.title)
                .font(.subheadline.weight(.semibold))
            Text(subtaskSummaryLine(for: subtask, allTasksSnapshot: mergedTasksSnapshot, dailyCapacityMinutes: dailyCapacityMinutes))
                .font(.caption)
                .foregroundStyle(subtask.status == .onHold ? .tertiary : .secondary)
                .lineLimit(2)

            if activeNodeCount(in: subtask.subtasks) > 0 || completedNodeCount(in: subtask.subtaskGraveyard) > 0 {
                Text("\(activeNodeCount(in: subtask.subtasks)) active descendants • \(completedNodeCount(in: subtask.subtaskGraveyard)) completed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                completeButton
                noteButton
                detailsButton
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingNoteSheet) {
            SubtaskNoteEditorSheet(title: subtask.title, note: $subtask.note)
        }
        .navigationDestination(isPresented: $isShowingDetails) {
            SubtaskDetailsView(
                rootTask: $rootTask,
                reference: reference,
                allTasksSnapshot: allTasksSnapshot,
                dailyCapacityMinutes: dailyCapacityMinutes
            )
        }
    }

    private var mergedTasksSnapshot: [TaskItem] {
        mergeTasksSnapshot(allTasksSnapshot, replacing: rootTask)
    }

    private var completeButton: some View {
        Button {
            completeCurrentSubtask()
        } label: {
            Image(systemName: "checkmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(hasActiveDescendants(subtask))
        .font(.body.weight(.semibold))
        .accessibilityLabel("Complete")
    }

    private var noteButton: some View {
        Button {
            showingNoteSheet = true
        } label: {
            Image(systemName: "note.text")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .font(.body.weight(.semibold))
        .accessibilityLabel("Notes")
    }

    private var detailsButton: some View {
        Button {
            isShowingDetails = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .font(.body.weight(.semibold))
        .accessibilityLabel("Details")
    }

    private func completeCurrentSubtask() {
        guard !hasActiveDescendants(subtask),
              var completedSubtask = removeSubtask(in: &rootTask.subtasks, at: reference.descendantIDs) else {
            return
        }
        completedSubtask.completedAt = Date()
        let parentReference = reference.parent ?? DependencyReference(taskID: rootTask.id)
        _ = appendCompletedChild(completedSubtask, to: parentReference, in: &rootTask)
        clearReleasedDependencies(matching: reference, in: &rootTask)
    }
}

private struct SubtaskDetailsView: View {
    @Binding var rootTask: TaskItem
    let reference: DependencyReference
    let allTasksSnapshot: [TaskItem]
    let dailyCapacityMinutes: Int

    @Environment(\.dismiss) private var dismiss

    @State private var estimateUnit: TaskEstimateUnit
    @State private var showDueDatePicker = false
    @State private var showingAddSubtaskSheet = false
    @State private var showingNoteSheet = false

    init(
        rootTask: Binding<TaskItem>,
        reference: DependencyReference,
        allTasksSnapshot: [TaskItem],
        dailyCapacityMinutes: Int
    ) {
        self._rootTask = rootTask
        self.reference = reference
        self.allTasksSnapshot = allTasksSnapshot
        self.dailyCapacityMinutes = max(1, dailyCapacityMinutes)
        let estimatedMinutes = activeSubtask(at: reference.descendantIDs, in: rootTask.wrappedValue.subtasks)?.estimatedMinutes
        _estimateUnit = State(initialValue: estimateUnitForMinutes(
            for: estimatedMinutes,
            dailyCapacityMinutes: max(1, dailyCapacityMinutes)
        ))
    }

    var body: some View {
        Group {
            if let currentSubtaskBinding {
                Form {
                    Section("Details") {
                        TextField("Title", text: currentSubtaskBinding.title)
#if os(iOS)
                            .textInputAutocapitalization(.sentences)
#endif

                        Picker("Status", selection: currentSubtaskBinding.status) {
                            ForEach(WorkingStatus.allCases) { status in
                                Text(status.rawValue).tag(status)
                            }
                        }
                        .disabled(currentSubtaskBinding.wrappedValue.blockingDependency != nil)

                        Toggle("Has estimate", isOn: hasEstimateBinding(for: currentSubtaskBinding))
                        if currentSubtaskBinding.wrappedValue.estimatedMinutes != nil {
                            Picker("Estimate unit", selection: $estimateUnit) {
                                ForEach(TaskEstimateUnit.allCases) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        Toggle("Has due date", isOn: hasDueDateBinding(for: currentSubtaskBinding))
                        if currentSubtaskBinding.wrappedValue.dueDate != nil {
                            Button {
                                showDueDatePicker = true
                            } label: {
                                HStack {
                                    Text("Due date")
                                    Spacer()
                                    Text(dueDateBinding(for: currentSubtaskBinding).wrappedValue, style: .date)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showDueDatePicker) {
                                DatePicker(
                                    "Due date",
                                    selection: dueDateBinding(for: currentSubtaskBinding),
                                    displayedComponents: .date
                                )
                                    .datePickerStyle(.graphical)
                                    .onChange(of: dueDateBinding(for: currentSubtaskBinding).wrappedValue) { _ in
                                        showDueDatePicker = false
                                    }
                                    .padding()
                            }
                        }
                    }

                    Section("Dependency") {
                        if dependencyOptionsForCurrent.isEmpty, selectedDependency == nil {
                            Text("No tasks or subtasks available to block on yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Blocked until completion", selection: dependencySelection(for: currentSubtaskBinding)) {
                                Text("None").tag(String?.none)
                                if let missingDependencyOption {
                                    Text("Missing dependency").tag(Optional(missingDependencyOption.id))
                                }
                                ForEach(dependencyOptionsForCurrent) { option in
                                    Text(option.title).tag(Optional(option.id))
                                }
                            }
                            .pickerStyle(.menu)

                            if let selectedDependency {
                                Text("This subtask stays on hold until \(selectedDependency.title) is completed.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("Actions") {
                        Button {
                            showingNoteSheet = true
                        } label: {
                            Label("Notes", systemImage: "note.text")
                        }

                        Button {
                            completeCurrentSubtask()
                        } label: {
                            Label("Complete", systemImage: "checkmark.circle")
                        }
                        .disabled(hasActiveDescendants(currentSubtaskBinding.wrappedValue))

                        Button(role: .destructive) {
                            deleteCurrentSubtask()
                        } label: {
                            Label("Delete subtask", systemImage: "trash")
                        }
                    }

                    Section {
                        HStack {
                            Text("Subtasks")
                                .font(.headline)
                            Spacer()
                            Button {
                                showingAddSubtaskSheet = true
                            } label: {
                                Label("Add", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                        }

                        if activeChildReferences.isEmpty {
                            Text("No subtasks yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(activeChildReferences) { entry in
                                if let childBinding = subtaskBinding(in: $rootTask, reference: entry.reference) {
                                    SubtaskListRow(
                                        rootTask: $rootTask,
                                        subtask: childBinding,
                                        reference: entry.reference,
                                        allTasksSnapshot: allTasksSnapshot,
                                        dailyCapacityMinutes: dailyCapacityMinutes
                                    )
                                }
                            }
                        }
                    }

                    Section("Completed") {
                        if completedChildReferences.isEmpty {
                            Text("No completed subtasks.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(completedChildReferences) { entry in
                                CompletedSubtaskRow(
                                    subtask: entry.subtask,
                                    onRestore: { restoreCompletedChild(withID: entry.subtask.id) },
                                    onDelete: { deleteCompletedChild(withID: entry.subtask.id) }
                                )
                            }
                        }
                    }
                }
                .navigationTitle(currentSubtaskBinding.wrappedValue.title)
                .sheet(isPresented: $showingAddSubtaskSheet) {
                    SubtaskEditorSheet(
                        subtask: nil,
                        dependencyOptions: dependencyOptions(
                            in: mergedTasksSnapshot,
                            dailyCapacityMinutes: dailyCapacityMinutes,
                            excluding: placeholderChildReference(for: reference)
                        ),
                        dailyCapacityMinutes: dailyCapacityMinutes
                    ) { newSubtask in
                        _ = appendActiveChild(newSubtask, to: reference, in: &rootTask)
                    }
                }
                .sheet(isPresented: $showingNoteSheet) {
                    SubtaskNoteEditorSheet(
                        title: currentSubtaskBinding.wrappedValue.title,
                        note: currentSubtaskBinding.note
                    )
                }
                .onChange(of: estimateUnit) { _ in
                    currentSubtaskBinding.wrappedValue.estimatedMinutes = estimateMinutes(
                        for: estimateUnit,
                        dailyCapacityMinutes: dailyCapacityMinutes
                    )
                }
                .onChange(of: currentSubtaskBinding.wrappedValue.estimatedMinutes) { _ in
                    estimateUnit = estimateUnitForMinutes(
                        for: currentSubtaskBinding.wrappedValue.estimatedMinutes,
                        dailyCapacityMinutes: dailyCapacityMinutes
                    )
                }
            } else if #available(iOS 17.0, *) {
                ContentUnavailableView("Subtask not found", systemImage: "exclamationmark.triangle")
            } else {
                UnavailableContentView(title: "Subtask not found", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private var currentSubtaskBinding: Binding<SubtaskItem>? {
        subtaskBinding(in: $rootTask, reference: reference)
    }

    private var mergedTasksSnapshot: [TaskItem] {
        mergeTasksSnapshot(allTasksSnapshot, replacing: rootTask)
    }

    private var dependencyOptionsForCurrent: [DependencyOption] {
        dependencyOptions(
            in: mergedTasksSnapshot,
            dailyCapacityMinutes: dailyCapacityMinutes,
            excluding: reference
        )
    }

    private var missingDependencyOption: DependencyOption? {
        guard let reference = currentSubtaskBinding?.wrappedValue.blockingDependency,
              dependencyOptionsForCurrent.contains(where: { $0.id == reference.id }) == false else {
            return nil
        }

        return DependencyOption(
            reference: reference,
            title: dependencyDescription(for: reference, in: mergedTasksSnapshot),
            subtitle: "Task or subtask no longer exists"
        )
    }

    private var selectedDependency: DependencyOption? {
        guard let dependencyID = currentSubtaskBinding?.wrappedValue.blockingDependency?.id else { return nil }
        return dependencyOptionsForCurrent.first(where: { $0.id == dependencyID }) ?? missingDependencyOption
    }

    private var activeChildReferences: [ReferencedSubtask] {
        directActiveSubtaskReferences(
            of: reference,
            in: rootTask,
            dailyCapacityMinutes: dailyCapacityMinutes
        )
    }

    private var completedChildReferences: [ReferencedSubtask] {
        directCompletedSubtaskReferences(of: reference, in: rootTask)
    }

    private func dependencySelection(for subtask: Binding<SubtaskItem>) -> Binding<String?> {
        Binding(
            get: { subtask.wrappedValue.blockingDependency?.id },
            set: { selectedID in
                if let selectedID {
                    let option = dependencyOptionsForCurrent.first(where: { $0.id == selectedID }) ?? missingDependencyOption
                    subtask.wrappedValue.blockingDependency = option?.reference
                    if subtask.wrappedValue.blockingDependency != nil {
                        subtask.wrappedValue.status = .onHold
                    }
                } else {
                    subtask.wrappedValue.blockingDependency = nil
                }
            }
        )
    }

    private func hasEstimateBinding(for subtask: Binding<SubtaskItem>) -> Binding<Bool> {
        Binding(
            get: { subtask.wrappedValue.estimatedMinutes != nil },
            set: { hasEstimate in
                subtask.wrappedValue.estimatedMinutes = hasEstimate
                    ? estimateMinutes(for: estimateUnit, dailyCapacityMinutes: dailyCapacityMinutes)
                    : nil
            }
        )
    }

    private func hasDueDateBinding(for subtask: Binding<SubtaskItem>) -> Binding<Bool> {
        Binding(
            get: { subtask.wrappedValue.dueDate != nil },
            set: { hasDueDate in
                subtask.wrappedValue.dueDate = hasDueDate ? (subtask.wrappedValue.dueDate ?? Date()) : nil
            }
        )
    }

    private func dueDateBinding(for subtask: Binding<SubtaskItem>) -> Binding<Date> {
        Binding(
            get: { subtask.wrappedValue.dueDate ?? Date() },
            set: { subtask.wrappedValue.dueDate = $0 }
        )
    }

    private func completeCurrentSubtask() {
        guard let currentSubtaskBinding,
              !hasActiveDescendants(currentSubtaskBinding.wrappedValue),
              var completedSubtask = removeSubtask(in: &rootTask.subtasks, at: reference.descendantIDs) else {
            return
        }

        completedSubtask.completedAt = Date()
        let parentReference = reference.parent ?? DependencyReference(taskID: rootTask.id)
        _ = appendCompletedChild(completedSubtask, to: parentReference, in: &rootTask)
        clearReleasedDependencies(matching: reference, in: &rootTask)
        dismiss()
    }

    private func deleteCurrentSubtask() {
        _ = removeSubtask(in: &rootTask.subtasks, at: reference.descendantIDs)
        dismiss()
    }

    private func restoreCompletedChild(withID childID: UUID) {
        guard var restoredChild = removeCompletedChild(withID: childID, from: reference, in: &rootTask) else { return }
        restoredChild.completedAt = nil
        _ = appendActiveChild(restoredChild, to: reference, in: &rootTask)
    }

    private func deleteCompletedChild(withID childID: UUID) {
        _ = removeCompletedChild(withID: childID, from: reference, in: &rootTask)
    }
}

private struct CompletedSubtaskRow: View {
    let subtask: SubtaskItem
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(subtask.title)
                .font(.subheadline.weight(.semibold))
            if !summaryLine.isEmpty {
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                restoreButton
                deleteButton
            }
        }
        .padding(.vertical, 4)
    }

    private var restoreButton: some View {
        Button {
            onRestore()
        } label: {
            Image(systemName: "arrow.uturn.backward.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .font(.body.weight(.semibold))
        .accessibilityLabel("Restore")
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            onDelete()
        } label: {
            Image(systemName: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .font(.body.weight(.semibold))
        .accessibilityLabel("Delete")
    }

    private var summaryLine: String {
        var parts: [String] = []
        if let completedAt = subtask.completedAt {
            parts.append("Completed \(completedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        if activeNodeCount(in: subtask.subtasks) > 0 || completedNodeCount(in: subtask.subtaskGraveyard) > 0 {
            parts.append("\(activeNodeCount(in: subtask.subtasks)) active descendants • \(completedNodeCount(in: subtask.subtaskGraveyard)) completed")
        }
        return parts.joined(separator: " • ")
    }
}

private struct SubtaskNoteEditorSheet: View {
    let title: String
    @Binding var note: String

    @Environment(\.dismiss) private var dismiss
    @State private var draftNote: String

    init(title: String, note: Binding<String>) {
        self.title = title
        self._note = note
        _draftNote = State(initialValue: note.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top, 8)

                TextEditor(text: $draftNote)
                    .scrollContentBackground(.hidden)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.bottom)
            }
            .navigationTitle("Subtask Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        note = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ProjectRow: View {
    @Binding var project: ProjectItem
    let onMoveToIdeas: (ProjectItem) -> Void
    let onEditNote: (ProjectItem) -> Void
    let onComplete: (ProjectItem) -> Void
    let onUpdateCategory: (ProjectItem, IdeaCategory) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(project.category.rawValue)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(project.category.tintColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(project.category.tintColor.opacity(0.18)))

                        Spacer(minLength: 0)
                    }

                    Text(project.title)
                        .font(.headline)
                        .foregroundStyle(project.status == .onHold ? .secondary : project.category.tintColor)
                    if !project.detail.isEmpty {
                        Text(project.detail)
                            .font(.caption)
                            .foregroundStyle(project.status == .onHold ? .tertiary : .secondary)
                    }
                }

                Spacer()

                Button {
                    onMoveToIdeas(project)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Move project item back to ideas")

                Button {
                    onEditNote(project)
                } label: {
                    Image(systemName: "note.text")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Edit project notes")

                Button {
                    onComplete(project)
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Complete project item")
            }

            Picker(
                "Category",
                selection: Binding(
                    get: { project.category },
                    set: { category in
                        onUpdateCategory(project, category)
                    }
                )
            ) {
                ForEach(IdeaCategory.allCases) { category in
                    Text(category.rawValue).tag(category)
                }
            }
            .pickerStyle(.segmented)

            Picker("Status", selection: $project.status) {
                ForEach(WorkingStatus.allCases) { status in
                    Text(status.rawValue).tag(status)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(project.category.tintColor.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(project.category.tintColor.opacity(0.35), lineWidth: 1)
        )
        .padding(.vertical, 6)
        .opacity(project.status == .onHold ? 0.6 : 1)
    }
}

private struct GuideTaskCard: View {
    let task: TaskItem
    let dailyCapacityMinutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 10) {
                Label("P\(task.priority)", systemImage: "flag.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let estimatedMinutes = task.estimatedMinutes {
                    Label(
                        estimateDescription(estimatedMinutes, dailyCapacityMinutes: dailyCapacityMinutes),
                        systemImage: "hourglass"
                    )
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
            if let latestSafeStartDay = planningState.latestSafeStartDay {
                Text("Latest safe start: \(latestSafeStartDay.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(planningState.mustStartNow ? .red : .secondary)
            }
            if planningState.mustStartNow {
                Text("Must start now")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
            } else if planningState.highRiskUnknown {
                Text("High-risk unknown")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Text(task.status.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var planningState: TaskPlanningState {
        taskPlanningState(for: task, dailyCapacityMinutes: dailyCapacityMinutes)
    }
}

private struct GuideSubtaskCard: View {
    let subtask: SubtaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(subtask.title)
                .font(.subheadline.weight(.semibold))
            Text(subtaskGuideSummary(subtask))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemBackground)))
    }

    private func subtaskGuideSummary(_ subtask: SubtaskItem) -> String {
        var parts: [String] = [subtask.status.rawValue]
        if let dueDate = subtask.dueDate {
            parts.append("Due \(dueDate.formatted(date: .abbreviated, time: .omitted))")
        }
        if let estimate = subtask.estimatedMinutes {
            parts.append(estimateDescription(estimate))
        }
        return parts.joined(separator: " • ")
    }
}

private struct GuideTimeoutSheet: View {
    let task: TaskItem
    let onSetTimeout: (Date) -> Void
    let onSetOnHoldWithoutTimeout: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var holdUntil: Date

    init(
        task: TaskItem,
        initialTimeout: Date,
        onSetTimeout: @escaping (Date) -> Void,
        onSetOnHoldWithoutTimeout: @escaping () -> Void
    ) {
        self.task = task
        self.onSetTimeout = onSetTimeout
        self.onSetOnHoldWithoutTimeout = onSetOnHoldWithoutTimeout
        let now = Date()
        let fallback = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now
        _holdUntil = State(initialValue: initialTimeout > now ? initialTimeout : fallback)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    Text(task.title)
                        .font(.headline)
                }

                Section("Timeout") {
                    DatePicker(
                        "On hold until",
                        selection: $holdUntil,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Text("Task returns to active automatically after this time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Actions") {
                    Button("Set timeout") {
                        onSetTimeout(holdUntil)
                        dismiss()
                    }

                    Button("On hold without timeout") {
                        onSetOnHoldWithoutTimeout()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Task Timeout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private enum GeofenceSelectionMode: String, CaseIterable, Identifiable {
    case radius = "Radius"
    case polygon = "Drawn Area"

    var id: String { rawValue }
}

private struct LocationTriggerEditorSheet: View {
    let initialTrigger: TaskLocationTrigger?
    let initialCenter: CLLocationCoordinate2D?
    let onSave: (TaskLocationTrigger) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectionMode: GeofenceSelectionMode
    @State private var mapRegion: MKCoordinateRegion
    @State private var circleCenter: LocationCoordinate?
    @State private var radiusMeters: Double
    @State private var polygonPoints: [LocationCoordinate]

    init(
        initialTrigger: TaskLocationTrigger?,
        initialCenter: CLLocationCoordinate2D?,
        onSave: @escaping (TaskLocationTrigger) -> Void
    ) {
        self.initialTrigger = initialTrigger
        self.initialCenter = initialCenter
        self.onSave = onSave

        let seedCoordinate = initialTrigger?.center.coordinate
            ?? initialCenter
            ?? CLLocationCoordinate2D(latitude: 47.3769, longitude: 8.5417)
        _selectionMode = State(initialValue: initialTrigger?.usesPolygon == true ? .polygon : .radius)
        _mapRegion = State(initialValue: MKCoordinateRegion(
            center: seedCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        ))
        _circleCenter = State(initialValue: initialTrigger?.center ?? LocationCoordinate(seedCoordinate))
        _radiusMeters = State(initialValue: initialTrigger?.radiusMeters ?? 250)
        _polygonPoints = State(initialValue: initialTrigger?.polygon ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Area style") {
                    Picker("Area style", selection: $selectionMode) {
                        ForEach(GeofenceSelectionMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(instructions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Map") {
                    LocationDrawingMap(
                        region: $mapRegion,
                        center: $circleCenter,
                        polygonPoints: $polygonPoints,
                        selectionMode: selectionMode,
                        radiusMeters: radiusMeters
                    )
                    .frame(minHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                if selectionMode == .radius {
                    Section("Radius") {
                        Slider(value: $radiusMeters, in: 100...2_000, step: 25)
                        Text("\(Int(radiusMeters.rounded())) meters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Drawn area") {
                        Text("\(polygonPoints.count) points")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Undo last point") {
                            guard !polygonPoints.isEmpty else { return }
                            polygonPoints.removeLast()
                        }
                        .disabled(polygonPoints.isEmpty)

                        Button("Clear area", role: .destructive) {
                            polygonPoints.removeAll()
                        }
                        .disabled(polygonPoints.isEmpty)
                    }
                }

                if let draftTrigger {
                    Section("Summary") {
                        Text(locationTriggerSummary(draftTrigger))
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Activation Area")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let draftTrigger else { return }
                        onSave(draftTrigger)
                        dismiss()
                    }
                    .disabled(draftTrigger == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var instructions: String {
        switch selectionMode {
        case .radius:
            return "Long-press the map to place the activation center, then adjust the radius."
        case .polygon:
            return "Tap the map to draw the area boundary. Long-press to move the fallback center used for background geofencing."
        }
    }

    private var draftTrigger: TaskLocationTrigger? {
        switch selectionMode {
        case .radius:
            guard let circleCenter else { return nil }
            return TaskLocationTrigger(
                center: circleCenter,
                radiusMeters: radiusMeters,
                polygon: []
            )
        case .polygon:
            guard polygonPoints.count >= 3 else { return nil }
            guard let circleCenter else {
                return derivedLocationTrigger(from: polygonPoints)
            }
            let centerLocation = CLLocation(
                latitude: circleCenter.latitude,
                longitude: circleCenter.longitude
            )
            let radiusMeters = polygonPoints
                .map {
                    CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                        .distance(from: centerLocation)
                }
                .max() ?? 100
            return TaskLocationTrigger(
                center: circleCenter,
                radiusMeters: max(radiusMeters, 100),
                polygon: polygonPoints
            )
        }
    }
}

private struct LocationDrawingMap: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    @Binding var center: LocationCoordinate?
    @Binding var polygonPoints: [LocationCoordinate]
    let selectionMode: GeofenceSelectionMode
    let radiusMeters: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.setRegion(region, animated: false)

        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        let longPressGesture = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )

        mapView.addGestureRecognizer(tapGesture)
        mapView.addGestureRecognizer(longPressGesture)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self

        if !regionMatches(lhs: mapView.region, rhs: region) {
            mapView.setRegion(region, animated: false)
        }

        mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })
        mapView.removeOverlays(mapView.overlays)

        let resolvedCenter: LocationCoordinate? = {
            if selectionMode == .polygon {
                return center ?? derivedLocationTrigger(from: polygonPoints)?.center
            }
            return center
        }()

        if let resolvedCenter {
            let annotation = MKPointAnnotation()
            annotation.coordinate = resolvedCenter.coordinate
            annotation.title = "Activation center"
            mapView.addAnnotation(annotation)
        }

        if selectionMode == .radius, let center {
            let circle = MKCircle(center: center.coordinate, radius: radiusMeters)
            mapView.addOverlay(circle)
        }

        if selectionMode == .polygon, polygonPoints.count >= 2 {
            let coordinates = polygonPoints.map(\.coordinate)
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            mapView.addOverlay(polyline)
        }

        if selectionMode == .polygon,
           let resolvedCenter,
           polygonPoints.count >= 3 {
            let coordinates = polygonPoints.map(\.coordinate)
            let polygon = MKPolygon(coordinates: coordinates, count: coordinates.count)
            mapView.addOverlay(polygon)
            let centerLocation = CLLocation(
                latitude: resolvedCenter.latitude,
                longitude: resolvedCenter.longitude
            )
            let radius = polygonPoints
                .map {
                    CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                        .distance(from: centerLocation)
                }
                .max() ?? 100
            let circle = MKCircle(center: resolvedCenter.coordinate, radius: max(radius, 100))
            mapView.addOverlay(circle)
        }
    }

    private func regionMatches(lhs: MKCoordinateRegion, rhs: MKCoordinateRegion) -> Bool {
        abs(lhs.center.latitude - rhs.center.latitude) < 0.000_1 &&
        abs(lhs.center.longitude - rhs.center.longitude) < 0.000_1 &&
        abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < 0.000_1 &&
        abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < 0.000_1
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: LocationDrawingMap

        init(parent: LocationDrawingMap) {
            self.parent = parent
        }

        @objc
        func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,
                  parent.selectionMode == .polygon,
                  let mapView = gesture.view as? MKMapView else { return }

            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            parent.polygonPoints.append(LocationCoordinate(coordinate))
        }

        @objc
        func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let mapView = gesture.view as? MKMapView else { return }

            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            parent.center = LocationCoordinate(coordinate)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.region = mapView.region
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.12)
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.65)
                renderer.lineWidth = 2
                return renderer
            }

            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = UIColor.systemGreen.withAlphaComponent(0.18)
                renderer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.8)
                renderer.lineWidth = 2
                return renderer
            }

            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.8)
                renderer.lineWidth = 2
                renderer.lineDashPattern = [4, 4]
                return renderer
            }

            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

private struct AddIdeaSheet: View {
    let onAdd: (IdeaItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var detail = ""
    @State private var category: IdeaCategory = .snack

    var body: some View {
        NavigationStack {
            Form {
                Section("Idea") {
                    TextField("Title", text: $title)
#if os(iOS)
                        .textInputAutocapitalization(.sentences)
#endif
                    TextField("Description", text: $detail, axis: .vertical)
                    Picker("Category", selection: $category) {
                        ForEach(IdeaCategory.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(category.timespanDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Idea")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onAdd(
                            IdeaItem(
                                title: trimmed,
                                detail: detail.trimmingCharacters(in: .whitespacesAndNewlines),
                                category: category
                            )
                        )
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
    @State private var category: IdeaCategory

    init(idea: IdeaItem, onSave: @escaping (IdeaItem) -> Void) {
        self.idea = idea
        self.onSave = onSave
        _title = State(initialValue: idea.title)
        _detail = State(initialValue: idea.detail)
        _category = State(initialValue: idea.category)
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
                    Picker("Category", selection: $category) {
                        ForEach(IdeaCategory.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(category.timespanDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Idea")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onSave(
                            IdeaItem(
                                id: idea.id,
                                title: trimmed,
                                detail: detail.trimmingCharacters(in: .whitespacesAndNewlines),
                                category: category
                            )
                        )
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

private struct AddImprovementNoteSheet: View {
    let onAdd: (ImprovementNote) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var detail = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Improvement") {
                    TextField("Title", text: $title)
#if os(iOS)
                        .textInputAutocapitalization(.sentences)
#endif
                    TextField("Details (optional)", text: $detail, axis: .vertical)
                }
            }
            .navigationTitle("Add Improvement")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let note = ImprovementNote(
                            title: trimmed,
                            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        onAdd(note)
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

private struct EditImprovementNoteSheet: View {
    let note: ImprovementNote
    let onSave: (ImprovementNote) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var detail: String

    init(note: ImprovementNote, onSave: @escaping (ImprovementNote) -> Void) {
        self.note = note
        self.onSave = onSave
        _title = State(initialValue: note.title)
        _detail = State(initialValue: note.detail)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Improvement") {
                    TextField("Title", text: $title)
#if os(iOS)
                        .textInputAutocapitalization(.sentences)
#endif
                    TextField("Details (optional)", text: $detail, axis: .vertical)
                }
            }
            .navigationTitle("Edit Improvement")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        var updated = note
                        updated.title = trimmed
                        updated.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
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

private struct AddTaskSheet: View {
    let parentTasks: [TaskItem]
    let dependencyOptions: [DependencyOption]
    let initialMapCenter: CLLocationCoordinate2D?
    let dailyCapacityMinutes: Int
    let onAdd: (TaskItem, Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var priority = 3
    @State private var isManuallyMustDoNow = false
    @State private var estimateUnit: TaskEstimateUnit = .hour
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var showDueDatePicker = false
    @State private var isScheduled = false
    @State private var scheduledDate = Date()
    @State private var showScheduledDatePicker = false
    @State private var selectedParentTaskID: UUID? = nil
    @State private var selectedDependencyID: String? = nil
    @State private var locationTrigger: TaskLocationTrigger? = nil
    @State private var showingLocationEditor = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
#if os(iOS)
                        .textInputAutocapitalization(.sentences)
#endif
                    Stepper("Priority \(priority)", value: $priority, in: 1...5)
                    Toggle("Manual must-do now", isOn: $isManuallyMustDoNow)
                    Picker("Estimate unit", selection: $estimateUnit) {
                        ForEach(TaskEstimateUnit.allCases) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    .pickerStyle(.menu)
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
                                Text("Scheduled time")
                                Spacer()
                                Text(scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showScheduledDatePicker) {
                            DatePicker(
                                "Scheduled time",
                                selection: $scheduledDate,
                                in: Date()...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                                .onChange(of: scheduledDate) { _ in
                                    showScheduledDatePicker = false
                                }
                                .padding()
                        }

                        if parentTasks.isEmpty {
                            Text("No parent task available. This will spawn as a normal task.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Parent task (optional)", selection: $selectedParentTaskID) {
                                Text("None").tag(UUID?.none)
                                ForEach(parentTasks) { task in
                                    Text(task.title).tag(Optional(task.id))
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }

                Section("Dependency") {
                    if dependencyOptions.isEmpty {
                        Text("No tasks or subtasks available to block on yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Blocked until completion", selection: $selectedDependencyID) {
                            Text("None").tag(String?.none)
                            ForEach(dependencyOptions) { option in
                                Text(option.title).tag(Optional(option.id))
                            }
                        }
                        .pickerStyle(.menu)

                        if let selectedDependency {
                            Text("This task stays on hold until \(selectedDependency.title) is completed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if isScheduled {
                    Section("Location activation") {
                        Toggle(
                            "Activate by location",
                            isOn: Binding(
                                get: { locationTrigger != nil },
                                set: { isEnabled in
                                    if isEnabled {
                                        locationTrigger = locationTrigger ?? TaskLocationTrigger(
                                            center: LocationCoordinate(
                                                initialMapCenter
                                                    ?? CLLocationCoordinate2D(latitude: 47.3769, longitude: 8.5417)
                                            ),
                                            radiusMeters: 250
                                        )
                                    } else {
                                        locationTrigger = nil
                                    }
                                }
                            )
                        )

                        if let locationTrigger {
                            Button("Choose activation area") {
                                showingLocationEditor = true
                            }
                            Text(locationTriggerSummary(locationTrigger))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("The task activates the next time you enter this area after the scheduled time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onChange(of: isScheduled) { newValue in
                if !newValue {
                    selectedParentTaskID = nil
                    locationTrigger = nil
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
                            estimatedMinutes: estimateInMinutes,
                            status: selectedDependency == nil ? .active : .onHold,
                            isManuallyMustDoNow: isManuallyMustDoNow,
                            createdAt: now,
                            lastPriorityBumpDate: now,
                            scheduledDate: isScheduled ? scheduledDate : nil,
                            scheduledParentTaskID: isScheduled ? selectedParentTaskID : nil,
                            blockingDependency: selectedDependency?.reference,
                            locationTrigger: isScheduled ? locationTrigger : nil
                        )
                        onAdd(task, isScheduled)
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
            .sheet(isPresented: $showingLocationEditor) {
                LocationTriggerEditorSheet(
                    initialTrigger: locationTrigger,
                    initialCenter: initialMapCenter
                ) { trigger in
                    locationTrigger = trigger
                }
            }
        }
    }

    private var selectedDependency: DependencyOption? {
        guard let selectedDependencyID else { return nil }
        return dependencyOptions.first(where: { $0.id == selectedDependencyID })
    }

    private var isAddDisabled: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
    }

    private var estimateInMinutes: Int {
        estimateMinutes(
            for: estimateUnit,
            dailyCapacityMinutes: dailyCapacityMinutes
        )
    }
}

private struct EditTaskSheet: View {
    let task: TaskItem
    let parentTasks: [TaskItem]
    let dependencyOptions: [DependencyOption]
    let initialMapCenter: CLLocationCoordinate2D?
    let dailyCapacityMinutes: Int
    let onSave: (TaskItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var priority: Int
    @State private var status: WorkingStatus
    @State private var isManuallyMustDoNow: Bool
    @State private var estimateUnit: TaskEstimateUnit
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var showDueDatePicker = false
    @State private var isScheduled: Bool
    @State private var scheduledDate: Date
    @State private var showScheduledDatePicker = false
    @State private var selectedParentTaskID: UUID?
    @State private var selectedDependencyID: String?
    @State private var locationTrigger: TaskLocationTrigger?
    @State private var showingLocationEditor = false

    init(
        task: TaskItem,
        parentTasks: [TaskItem],
        dependencyOptions: [DependencyOption],
        initialMapCenter: CLLocationCoordinate2D?,
        dailyCapacityMinutes: Int,
        onSave: @escaping (TaskItem) -> Void
    ) {
        self.task = task
        self.parentTasks = parentTasks
        self.dependencyOptions = dependencyOptions
        self.initialMapCenter = initialMapCenter
        self.dailyCapacityMinutes = max(1, dailyCapacityMinutes)
        self.onSave = onSave
        _title = State(initialValue: task.title)
        _priority = State(initialValue: task.priority)
        _status = State(initialValue: task.status)
        _isManuallyMustDoNow = State(initialValue: task.isManuallyMustDoNow)
        _estimateUnit = State(initialValue: estimateUnitForMinutes(
            for: task.estimatedMinutes,
            dailyCapacityMinutes: max(1, dailyCapacityMinutes)
        ))
        _hasDueDate = State(initialValue: task.dueDate != nil)
        _dueDate = State(initialValue: task.dueDate ?? Date())
        _isScheduled = State(initialValue: task.scheduledDate != nil)
        _scheduledDate = State(initialValue: task.scheduledDate ?? Date())
        _selectedParentTaskID = State(initialValue: task.scheduledParentTaskID)
        _selectedDependencyID = State(initialValue: task.blockingDependency?.id)
        _locationTrigger = State(initialValue: task.locationTrigger)
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
                    Toggle("Manual must-do now", isOn: $isManuallyMustDoNow)
                    if task.estimatedMinutes == nil {
                        Text("This task had no estimate. Set one before saving.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Picker("Estimate unit", selection: $estimateUnit) {
                        ForEach(TaskEstimateUnit.allCases) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    .pickerStyle(.menu)
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
                                Text("Scheduled time")
                                Spacer()
                                Text(scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showScheduledDatePicker) {
                            DatePicker(
                                "Scheduled time",
                                selection: $scheduledDate,
                                in: Date()...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                                .onChange(of: scheduledDate) { _ in
                                    showScheduledDatePicker = false
                                }
                                .padding()
                        }

                        if parentTasks.isEmpty {
                            Text("No parent task available. This will spawn as a normal task.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Parent task (optional)", selection: $selectedParentTaskID) {
                                Text("None").tag(UUID?.none)
                                if let missingParentTaskID {
                                    Text("Missing parent").tag(Optional(missingParentTaskID))
                                }
                                ForEach(parentTasks) { task in
                                    Text(task.title).tag(Optional(task.id))
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }

                Section("Dependency") {
                    if dependencyOptions.isEmpty, selectedDependency == nil {
                        Text("No tasks or subtasks available to block on yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Blocked until completion", selection: $selectedDependencyID) {
                            Text("None").tag(String?.none)
                            if let missingDependencyOption {
                                Text("Missing dependency").tag(Optional(missingDependencyOption.id))
                            }
                            ForEach(dependencyOptions) { option in
                                Text(option.title).tag(Optional(option.id))
                            }
                        }
                        .pickerStyle(.menu)

                        if let selectedDependency {
                            Text("This task stays on hold until \(selectedDependency.title) is completed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if isScheduled {
                    Section("Location activation") {
                        Toggle(
                            "Activate by location",
                            isOn: Binding(
                                get: { locationTrigger != nil },
                                set: { isEnabled in
                                    if isEnabled {
                                        locationTrigger = locationTrigger ?? TaskLocationTrigger(
                                            center: LocationCoordinate(
                                                initialMapCenter
                                                    ?? CLLocationCoordinate2D(latitude: 47.3769, longitude: 8.5417)
                                            ),
                                            radiusMeters: 250
                                        )
                                    } else {
                                        locationTrigger = nil
                                    }
                                }
                            )
                        )

                        if let locationTrigger {
                            Button("Choose activation area") {
                                showingLocationEditor = true
                            }
                            Text(locationTriggerSummary(locationTrigger))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("The task activates the next time you enter this area after the scheduled time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onChange(of: isScheduled) { newValue in
                if !newValue {
                    selectedParentTaskID = nil
                    locationTrigger = nil
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
                        if selectedDependency == nil {
                            applyStatusChange(to: &updated, newStatus: status)
                        } else {
                            applyStatusChange(to: &updated, newStatus: .onHold)
                        }
                        updated.isManuallyMustDoNow = isManuallyMustDoNow
                        updated.dueDate = hasDueDate ? dueDate : nil
                        updated.estimatedMinutes = estimateInMinutes
                        updated.scheduledDate = isScheduled ? scheduledDate : nil
                        updated.scheduledParentTaskID = isScheduled ? selectedParentTaskID : nil
                        updated.blockingDependency = selectedDependency?.reference
                        updated.locationTrigger = isScheduled ? locationTrigger : nil
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
            .sheet(isPresented: $showingLocationEditor) {
                LocationTriggerEditorSheet(
                    initialTrigger: locationTrigger,
                    initialCenter: initialMapCenter
                ) { trigger in
                    locationTrigger = trigger
                }
            }
        }
    }

    private var missingParentTaskID: UUID? {
        guard let selectedParentTaskID else { return nil }
        let parentExists = parentTasks.contains { $0.id == selectedParentTaskID }
        return parentExists ? nil : selectedParentTaskID
    }

    private var missingDependencyOption: DependencyOption? {
        guard let reference = task.blockingDependency,
              reference.id == selectedDependencyID,
              dependencyOptions.contains(where: { $0.id == reference.id }) == false else {
            return nil
        }

        return DependencyOption(
            reference: reference,
            title: dependencyDescription(for: reference, in: []),
            subtitle: "Task or subtask no longer exists"
        )
    }

    private var selectedDependency: DependencyOption? {
        guard let selectedDependencyID else { return nil }
        if let option = dependencyOptions.first(where: { $0.id == selectedDependencyID }) {
            return option
        }
        return missingDependencyOption
    }

    private var estimateInMinutes: Int {
        estimateMinutes(
            for: estimateUnit,
            dailyCapacityMinutes: dailyCapacityMinutes
        )
    }
}

private struct SubtaskEditorSheet: View {
    let subtask: SubtaskItem?
    let dependencyOptions: [DependencyOption]
    let dailyCapacityMinutes: Int
    let onSave: (SubtaskItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var status: WorkingStatus
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var showDueDatePicker = false
    @State private var hasEstimate: Bool
    @State private var estimateUnit: TaskEstimateUnit
    @State private var note: String
    @State private var selectedDependencyID: String?

    init(
        subtask: SubtaskItem?,
        dependencyOptions: [DependencyOption] = [],
        dailyCapacityMinutes: Int = defaultDailyCapacityMinutes,
        onSave: @escaping (SubtaskItem) -> Void
    ) {
        self.subtask = subtask
        self.dependencyOptions = dependencyOptions
        self.dailyCapacityMinutes = max(1, dailyCapacityMinutes)
        self.onSave = onSave
        _title = State(initialValue: subtask?.title ?? "")
        _status = State(initialValue: subtask?.status ?? .active)
        _hasDueDate = State(initialValue: subtask?.dueDate != nil)
        _dueDate = State(initialValue: subtask?.dueDate ?? Date())
        _hasEstimate = State(initialValue: subtask?.estimatedMinutes != nil)
        _estimateUnit = State(initialValue: estimateUnitForMinutes(
            for: subtask?.estimatedMinutes,
            dailyCapacityMinutes: max(1, dailyCapacityMinutes)
        ))
        _note = State(initialValue: subtask?.note ?? "")
        _selectedDependencyID = State(initialValue: subtask?.blockingDependency?.id)
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
                    Toggle("Has estimate", isOn: $hasEstimate)
                    if hasEstimate {
                        Picker("Estimate unit", selection: $estimateUnit) {
                            ForEach(TaskEstimateUnit.allCases) { unit in
                                Text(unit.rawValue).tag(unit)
                            }
                        }
                        .pickerStyle(.menu)
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
                }

                Section("Notes") {
                    TextEditor(text: $note)
                        .frame(minHeight: 120)
                }

                Section("Dependency") {
                    if dependencyOptions.isEmpty, selectedDependency == nil {
                        Text("No tasks or subtasks available to block on yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Blocked until completion", selection: $selectedDependencyID) {
                            Text("None").tag(String?.none)
                            if let missingDependencyOption {
                                Text("Missing dependency").tag(Optional(missingDependencyOption.id))
                            }
                            ForEach(dependencyOptions) { option in
                                Text(option.title).tag(Optional(option.id))
                            }
                        }
                        .pickerStyle(.menu)

                        if let selectedDependency {
                            Text("This subtask stays on hold until \(selectedDependency.title) is completed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(subtask == nil ? "Add Subtask" : "Edit Subtask")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(subtask == nil ? "Add" : "Save") {
                        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedTitle.isEmpty else { return }
                        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        var updated = subtask ?? SubtaskItem(
                            title: trimmedTitle,
                            status: selectedDependency == nil ? status : .onHold,
                            dueDate: hasDueDate ? dueDate : nil,
                            estimatedMinutes: hasEstimate ? estimateInMinutes : nil,
                            note: trimmedNote,
                            blockingDependency: selectedDependency?.reference
                        )
                        updated.title = trimmedTitle
                        updated.status = selectedDependency == nil ? status : .onHold
                        updated.dueDate = hasDueDate ? dueDate : nil
                        updated.estimatedMinutes = hasEstimate ? estimateInMinutes : nil
                        updated.note = trimmedNote
                        updated.blockingDependency = selectedDependency?.reference
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

    private var missingDependencyOption: DependencyOption? {
        guard let reference = subtask?.blockingDependency,
              reference.id == selectedDependencyID,
              dependencyOptions.contains(where: { $0.id == reference.id }) == false else {
            return nil
        }

        return DependencyOption(
            reference: reference,
            title: "Missing dependency",
            subtitle: "Task or subtask no longer exists"
        )
    }

    private var selectedDependency: DependencyOption? {
        guard let selectedDependencyID else { return nil }
        if let option = dependencyOptions.first(where: { $0.id == selectedDependencyID }) {
            return option
        }
        return missingDependencyOption
    }

    private var estimateInMinutes: Int {
        estimateMinutes(
            for: estimateUnit,
            dailyCapacityMinutes: dailyCapacityMinutes
        )
    }
}

private struct TaskNoteEditorSheet: View {
    let task: TaskItem
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note: String

    init(task: TaskItem, onSave: @escaping (String) -> Void) {
        self.task = task
        self.onSave = onSave
        _note = State(initialValue: task.note)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(task.title)
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top, 8)

                TextEditor(text: $note)
                    .scrollContentBackground(.hidden)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.bottom)
            }
            .navigationTitle("Task Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(note)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct IdeaNoteEditorSheet: View {
    let idea: IdeaItem
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note: String

    init(idea: IdeaItem, onSave: @escaping (String) -> Void) {
        self.idea = idea
        self.onSave = onSave
        _note = State(initialValue: idea.detail)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(idea.title)
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top, 8)

                TextEditor(text: $note)
                    .scrollContentBackground(.hidden)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.bottom)
            }
            .navigationTitle("Idea Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(note)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ProjectNoteEditorSheet: View {
    let project: ProjectItem
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note: String

    init(project: ProjectItem, onSave: @escaping (String) -> Void) {
        self.project = project
        self.onSave = onSave
        _note = State(initialValue: project.detail)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(project.title)
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top, 8)

                TextEditor(text: $note)
                    .scrollContentBackground(.hidden)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.bottom)
            }
            .navigationTitle("Project Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(note)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ScheduledTasksView: View {
    @Binding var scheduledTasks: [TaskItem]
    let dailyCapacityMinutes: Int
    let onEdit: (TaskItem) -> Void
    let onEditNote: (TaskItem) -> Void

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
                    ForEach(sortedScheduledTasks) { task in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(task.title)
                                .font(.headline)
                            Text(scheduledTaskSummary(task))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemBackground)))
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                onEditNote(task)
                            } label: {
                                Label("Notes", systemImage: "note.text")
                            }
                            .tint(.indigo)

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
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Scheduled Tasks")
        }
    }

    private var sortedScheduledTasks: [TaskItem] {
        scheduledTasks.sorted { left, right in
            let leftDate = left.scheduledDate ?? .distantFuture
            let rightDate = right.scheduledDate ?? .distantFuture
            if leftDate != rightDate {
                return leftDate < rightDate
            }
            return left.createdAt < right.createdAt
        }
    }

    private func scheduledTaskSummary(_ task: TaskItem) -> String {
        var parts: [String] = ["P\(task.priority)"]
        if let scheduledDate = task.scheduledDate {
            parts.append("Scheduled \(scheduledDate.formatted(date: .abbreviated, time: .shortened))")
        }
        if task.scheduledParentTaskID != nil {
            parts.append("Spawns as subtask")
        }
        if let dueDate = task.dueDate {
            parts.append("Due \(dueDate.formatted(date: .abbreviated, time: .omitted))")
        }
        if let estimate = task.estimatedMinutes {
            parts.append(estimateDescription(estimate, dailyCapacityMinutes: dailyCapacityMinutes))
        }
        if task.blockingDependency != nil {
            parts.append("Blocked by dependency")
        }
        if let locationTrigger = task.locationTrigger {
            parts.append(locationTriggerSummary(locationTrigger))
        }
        return parts.joined(separator: " • ")
    }
}

private struct RecurringSeriesView: View {
    @Binding var series: [RecurringSeries]
    @Binding var tasks: [TaskItem]
    @Binding var scheduledTasks: [TaskItem]
    let initialMapCenter: CLLocationCoordinate2D?
    let dailyCapacityMinutes: Int

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
                EditSeriesSheet(
                    series: entry,
                    initialMapCenter: initialMapCenter,
                    dailyCapacityMinutes: dailyCapacityMinutes
                ) { updated in
                    updateSeries(updated)
                }
            }
            .sheet(isPresented: $showingAddSeries) {
                AddSeriesSheet(
                    initialMapCenter: initialMapCenter,
                    dailyCapacityMinutes: dailyCapacityMinutes
                ) { newSeries in
                    series.append(newSeries)
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
            estimatedMinutes: entry.estimatedMinutes,
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
        scheduledTasks.removeAll { item in
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
                tasks[itemIndex].estimatedMinutes = updated.estimatedMinutes
            }
        }
        for itemIndex in scheduledTasks.indices {
            if scheduledTasks[itemIndex].seriesID == updated.id {
                scheduledTasks[itemIndex].title = updated.title
                scheduledTasks[itemIndex].priority = updated.priority
                scheduledTasks[itemIndex].dueDate = dueDate
                scheduledTasks[itemIndex].estimatedMinutes = updated.estimatedMinutes
                scheduledTasks[itemIndex].locationTrigger = updated.locationTrigger
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
        case .monthly:
            return "Monthly"
        }
    }

    private func seriesMeta(_ entry: RecurringSeries) -> String {
        var parts: [String] = ["P\(entry.priority)"]
        let appearanceDate = Calendar.current.date(
            bySettingHour: entry.appearanceHour,
            minute: entry.appearanceMinute,
            second: 0,
            of: Date()
        ) ?? Date()
        parts.append("At \(appearanceDate.formatted(date: .omitted, time: .shortened))")
        if let offset = entry.dueDateOffsetDays {
            parts.append("Due \(offset) days after")
        } else {
            parts.append("No due date")
        }
        if let estimate = entry.estimatedMinutes {
            parts.append(estimateDescription(estimate, dailyCapacityMinutes: dailyCapacityMinutes))
        } else {
            parts.append("No estimate")
        }
        if let locationTrigger = entry.locationTrigger {
            parts.append(locationTriggerSummary(locationTrigger))
        }
        return parts.joined(separator: " • ")
    }
}

private struct TaskPlanningState {
    let hasDueDate: Bool
    let latestSafeStartDay: Date?
    let mustStartNow: Bool
    let highRiskUnknown: Bool
    let hasKnownEstimate: Bool
    let estimateMinutes: Int?
}

private func estimateMinutes(
    for unit: TaskEstimateUnit,
    dailyCapacityMinutes: Int = defaultDailyCapacityMinutes
) -> Int {
    unit.minuteMultiplier(dailyCapacityMinutes: max(1, dailyCapacityMinutes))
}

private func estimateUnitForMinutes(
    for minutes: Int?,
    dailyCapacityMinutes: Int = defaultDailyCapacityMinutes
) -> TaskEstimateUnit {
    guard let minutes, minutes > 0 else {
        return .hour
    }

    let safeCapacity = max(1, dailyCapacityMinutes)
    let options: [(unit: TaskEstimateUnit, value: Int)] = TaskEstimateUnit.allCases.map { unit in
        (unit: unit, value: unit.minuteMultiplier(dailyCapacityMinutes: safeCapacity))
    }

    if let exact = options.first(where: { $0.value == minutes }) {
        return exact.unit
    }

    return options.min { left, right in
        let leftDistance = abs(left.value - minutes)
        let rightDistance = abs(right.value - minutes)
        if leftDistance != rightDistance {
            return leftDistance < rightDistance
        }
        return left.value < right.value
    }?.unit ?? .hour
}

private func estimateDescription(
    _ minutes: Int,
    dailyCapacityMinutes: Int = defaultDailyCapacityMinutes
) -> String {
    guard minutes > 0 else { return "Unknown" }
    return estimateUnitForMinutes(for: minutes, dailyCapacityMinutes: dailyCapacityMinutes).rawValue
}

private struct ReferencedSubtask: Identifiable {
    let reference: DependencyReference
    let subtask: SubtaskItem

    var id: String { reference.id }
}

private func mergeTasksSnapshot(_ tasks: [TaskItem], replacing task: TaskItem) -> [TaskItem] {
    var mergedTasks = tasks
    if let index = mergedTasks.firstIndex(where: { $0.id == task.id }) {
        mergedTasks[index] = task
    } else {
        mergedTasks.insert(task, at: 0)
    }
    return mergedTasks
}

private func activeSubtask(at path: [UUID], in subtasks: [SubtaskItem]) -> SubtaskItem? {
    guard let currentID = path.first,
          let currentSubtask = subtasks.first(where: { $0.id == currentID }) else {
        return nil
    }

    guard path.count > 1 else { return currentSubtask }
    return activeSubtask(at: Array(path.dropFirst()), in: currentSubtask.subtasks)
}

private func anySubtask(
    at path: [UUID],
    active subtasks: [SubtaskItem],
    graveyard: [SubtaskItem]
) -> SubtaskItem? {
    guard let currentID = path.first else { return nil }
    let currentSubtask = subtasks.first(where: { $0.id == currentID })
        ?? graveyard.first(where: { $0.id == currentID })
    guard let currentSubtask else { return nil }

    guard path.count > 1 else { return currentSubtask }
    return anySubtask(
        at: Array(path.dropFirst()),
        active: currentSubtask.subtasks,
        graveyard: currentSubtask.subtaskGraveyard
    )
}

private func subtaskTitlePath(
    at path: [UUID],
    active subtasks: [SubtaskItem],
    graveyard: [SubtaskItem]
) -> [String]? {
    guard let currentID = path.first else { return [] }
    let currentSubtask = subtasks.first(where: { $0.id == currentID })
        ?? graveyard.first(where: { $0.id == currentID })
    guard let currentSubtask else { return nil }

    guard path.count > 1 else { return [currentSubtask.title] }
    guard let childTitles = subtaskTitlePath(
        at: Array(path.dropFirst()),
        active: currentSubtask.subtasks,
        graveyard: currentSubtask.subtaskGraveyard
    ) else {
        return nil
    }

    return [currentSubtask.title] + childTitles
}

private func referencedActiveSubtasks(
    taskID: UUID,
    in subtasks: [SubtaskItem],
    prefix: [UUID] = []
) -> [ReferencedSubtask] {
    var references: [ReferencedSubtask] = []
    for subtask in subtasks {
        let reference = DependencyReference(taskID: taskID, descendantIDs: prefix + [subtask.id])
        references.append(ReferencedSubtask(reference: reference, subtask: subtask))
        references.append(contentsOf: referencedActiveSubtasks(
            taskID: taskID,
            in: subtask.subtasks,
            prefix: reference.descendantIDs
        ))
    }
    return references
}

private func activeNodeCount(in subtasks: [SubtaskItem]) -> Int {
    subtasks.reduce(0) { partialResult, subtask in
        partialResult + 1 + activeNodeCount(in: subtask.subtasks)
    }
}

private func completedNodeCount(in graveyard: [SubtaskItem]) -> Int {
    graveyard.reduce(0) { partialResult, subtask in
        partialResult + 1
            + activeNodeCount(in: subtask.subtasks)
            + completedNodeCount(in: subtask.subtaskGraveyard)
    }
}

private func hasActiveDescendants(_ task: TaskItem) -> Bool {
    !task.subtasks.isEmpty
}

private func hasActiveDescendants(_ subtask: SubtaskItem) -> Bool {
    !subtask.subtasks.isEmpty
}

private func updateSubtask(
    in subtasks: inout [SubtaskItem],
    at path: [UUID],
    update: (inout SubtaskItem) -> Void
) -> Bool {
    guard let currentID = path.first,
          let index = subtasks.firstIndex(where: { $0.id == currentID }) else {
        return false
    }

    if path.count == 1 {
        update(&subtasks[index])
        return true
    }

    return updateSubtask(
        in: &subtasks[index].subtasks,
        at: Array(path.dropFirst()),
        update: update
    )
}

private func removeSubtask(in subtasks: inout [SubtaskItem], at path: [UUID]) -> SubtaskItem? {
    guard let currentID = path.first,
          let index = subtasks.firstIndex(where: { $0.id == currentID }) else {
        return nil
    }

    if path.count == 1 {
        return subtasks.remove(at: index)
    }

    return removeSubtask(
        in: &subtasks[index].subtasks,
        at: Array(path.dropFirst())
    )
}

private func removeDirectItem(withID itemID: UUID, from subtasks: inout [SubtaskItem]) -> SubtaskItem? {
    guard let index = subtasks.firstIndex(where: { $0.id == itemID }) else { return nil }
    return subtasks.remove(at: index)
}

private func updateActiveChildren(
    of parentReference: DependencyReference,
    in task: inout TaskItem,
    update: (inout [SubtaskItem]) -> Void
) -> Bool {
    guard parentReference.taskID == task.id else { return false }
    if parentReference.isTask {
        update(&task.subtasks)
        return true
    }

    return updateSubtask(in: &task.subtasks, at: parentReference.descendantIDs) { parent in
        update(&parent.subtasks)
    }
}

private func updateCompletedChildren(
    of parentReference: DependencyReference,
    in task: inout TaskItem,
    update: (inout [SubtaskItem]) -> Void
) -> Bool {
    guard parentReference.taskID == task.id else { return false }
    if parentReference.isTask {
        update(&task.subtaskGraveyard)
        return true
    }

    return updateSubtask(in: &task.subtasks, at: parentReference.descendantIDs) { parent in
        update(&parent.subtaskGraveyard)
    }
}

private func appendActiveChild(
    _ subtask: SubtaskItem,
    to parentReference: DependencyReference,
    in task: inout TaskItem
) -> Bool {
    updateActiveChildren(of: parentReference, in: &task) { children in
        children.append(subtask)
    }
}

private func appendCompletedChild(
    _ subtask: SubtaskItem,
    to parentReference: DependencyReference,
    in task: inout TaskItem
) -> Bool {
    updateCompletedChildren(of: parentReference, in: &task) { children in
        children.append(subtask)
    }
}

private func removeCompletedChild(
    withID childID: UUID,
    from parentReference: DependencyReference,
    in task: inout TaskItem
) -> SubtaskItem? {
    var removedChild: SubtaskItem? = nil
    _ = updateCompletedChildren(of: parentReference, in: &task) { children in
        removedChild = removeDirectItem(withID: childID, from: &children)
    }
    return removedChild
}

private func clearReleasedDependencies(
    matching completedReference: DependencyReference,
    in task: inout TaskItem
) {
    if task.blockingDependency == completedReference {
        task.blockingDependency = nil
        if task.status == .onHold, task.onHoldUntil == nil {
            applyStatusChange(to: &task, newStatus: .active)
        }
    }
    clearReleasedDependencies(matching: completedReference, in: &task.subtasks)
}

private func clearReleasedDependencies(
    matching completedReference: DependencyReference,
    in subtasks: inout [SubtaskItem]
) {
    for index in subtasks.indices {
        if subtasks[index].blockingDependency == completedReference {
            subtasks[index].blockingDependency = nil
            if subtasks[index].status == .onHold {
                subtasks[index].status = .active
            }
        }
        clearReleasedDependencies(matching: completedReference, in: &subtasks[index].subtasks)
    }
}

private func subtaskBinding(
    in task: Binding<TaskItem>,
    reference: DependencyReference
) -> Binding<SubtaskItem>? {
    guard task.wrappedValue.id == reference.taskID else { return nil }
    let subtasksBinding = Binding<[SubtaskItem]>(
        get: { task.wrappedValue.subtasks },
        set: { task.wrappedValue.subtasks = $0 }
    )
    return subtaskBinding(in: subtasksBinding, path: reference.descendantIDs)
}

private func subtaskBinding(
    in subtasks: Binding<[SubtaskItem]>,
    path: [UUID]
) -> Binding<SubtaskItem>? {
    guard let currentID = path.first,
          let index = subtasks.wrappedValue.firstIndex(where: { $0.id == currentID }) else {
        return nil
    }

    let currentBinding = Binding<SubtaskItem>(
        get: { subtasks.wrappedValue[index] },
        set: { subtasks.wrappedValue[index] = $0 }
    )

    guard path.count > 1 else { return currentBinding }

    let childBinding = Binding<[SubtaskItem]>(
        get: { currentBinding.wrappedValue.subtasks },
        set: { currentBinding.wrappedValue.subtasks = $0 }
    )
    return subtaskBinding(in: childBinding, path: Array(path.dropFirst()))
}

private func isDependencyCandidateAllowed(
    _ candidate: DependencyReference,
    excluding current: DependencyReference?
) -> Bool {
    guard let current else { return true }
    if candidate == current {
        return false
    }
    if candidate.taskID != current.taskID {
        return true
    }

    return !candidate.isAncestor(of: current) && !current.isAncestor(of: candidate)
}

private func dependencyOptions(
    in tasks: [TaskItem],
    dailyCapacityMinutes: Int,
    excluding current: DependencyReference? = nil
) -> [DependencyOption] {
    let sortedTasks = tasks.sorted { left, right in
        taskSortComparator(
            left,
            right,
            dailyCapacityMinutes: dailyCapacityMinutes
        )
    }

    var options: [DependencyOption] = []
    for task in sortedTasks {
        let taskReference = DependencyReference(taskID: task.id)
        if isDependencyCandidateAllowed(taskReference, excluding: current) {
            options.append(
                DependencyOption(
                    reference: taskReference,
                    title: task.title,
                    subtitle: dependencySubtitle(for: taskReference, in: tasks)
                )
            )
        }

        for entry in referencedActiveSubtasks(taskID: task.id, in: task.subtasks) {
            guard isDependencyCandidateAllowed(entry.reference, excluding: current) else { continue }
            options.append(
                DependencyOption(
                    reference: entry.reference,
                    title: dependencyDescription(for: entry.reference, in: tasks),
                    subtitle: dependencySubtitle(for: entry.reference, in: tasks)
                )
            )
        }
    }

    return options
}

private func placeholderChildReference(for parentReference: DependencyReference) -> DependencyReference {
    parentReference.appending(UUID())
}

private func directActiveSubtaskReferences(
    of parentReference: DependencyReference,
    in task: TaskItem,
    dailyCapacityMinutes: Int,
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> [ReferencedSubtask] {
    let children: [SubtaskItem]
    if parentReference.isTask {
        children = task.subtasks
    } else {
        children = activeSubtask(at: parentReference.descendantIDs, in: task.subtasks)?.subtasks ?? []
    }

    return children
        .sorted {
            subtaskSortComparator(
                $0,
                $1,
                dailyCapacityMinutes: dailyCapacityMinutes,
                referenceDate: referenceDate,
                calendar: calendar
            )
        }
        .map { child in
            ReferencedSubtask(reference: parentReference.appending(child.id), subtask: child)
        }
}

private func directCompletedSubtaskReferences(
    of parentReference: DependencyReference,
    in task: TaskItem
) -> [ReferencedSubtask] {
    let children: [SubtaskItem]
    if parentReference.isTask {
        children = task.subtaskGraveyard
    } else {
        children = activeSubtask(at: parentReference.descendantIDs, in: task.subtasks)?.subtaskGraveyard ?? []
    }

    return children
        .sorted { left, right in
            let leftDate = left.completedAt ?? left.createdAt
            let rightDate = right.completedAt ?? right.createdAt
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
        .map { child in
            ReferencedSubtask(reference: parentReference.appending(child.id), subtask: child)
        }
}

private func taskSummaryLine(
    for task: TaskItem,
    allTasksSnapshot: [TaskItem],
    dailyCapacityMinutes: Int
) -> String {
    let planningState = taskPlanningState(for: task, dailyCapacityMinutes: dailyCapacityMinutes)
    var parts: [String] = ["P\(task.priority)", task.status.rawValue]
    if task.isManuallyMustDoNow {
        parts.append("Manual must-do")
    }
    if task.status == .onHold, let holdUntil = task.onHoldUntil {
        parts.append("Until \(holdUntil.formatted(date: .abbreviated, time: .shortened))")
    }
    if let dueDate = task.dueDate {
        parts.append("Due \(dueDate.formatted(date: .abbreviated, time: .omitted))")
        if let latestSafeStart = planningState.latestSafeStartDay {
            parts.append("Safe start \(latestSafeStart.formatted(date: .abbreviated, time: .omitted))")
        }
    }
    if let estimate = task.estimatedMinutes {
        parts.append(estimateDescription(estimate, dailyCapacityMinutes: dailyCapacityMinutes))
    }
    if let dependency = task.blockingDependency {
        parts.append("Blocked by \(dependencyDescription(for: dependency, in: allTasksSnapshot))")
    }
    return parts.joined(separator: " • ")
}

private func subtaskSummaryLine(
    for subtask: SubtaskItem,
    allTasksSnapshot: [TaskItem],
    dailyCapacityMinutes: Int
) -> String {
    var parts: [String] = [subtask.status.rawValue]
    if let dueDate = subtask.dueDate {
        parts.append("Due \(dueDate.formatted(date: .abbreviated, time: .omitted))")
    }
    if let estimate = subtask.estimatedMinutes {
        parts.append(estimateDescription(estimate, dailyCapacityMinutes: dailyCapacityMinutes))
    }
    if let dependency = subtask.blockingDependency {
        parts.append("Blocked by \(dependencyDescription(for: dependency, in: allTasksSnapshot))")
    }
    return parts.joined(separator: " • ")
}

private func polygonContains(
    _ coordinate: CLLocationCoordinate2D,
    polygon: [LocationCoordinate]
) -> Bool {
    guard polygon.count >= 3 else { return false }

    let latitude = coordinate.latitude
    let longitude = coordinate.longitude
    var contains = false
    var previousIndex = polygon.count - 1

    for index in polygon.indices {
        let current = polygon[index]
        let previous = polygon[previousIndex]

        let currentLatitude = current.latitude
        let currentLongitude = current.longitude
        let previousLatitude = previous.latitude
        let previousLongitude = previous.longitude

        let crossesLatitude = (currentLatitude > latitude) != (previousLatitude > latitude)
        if crossesLatitude {
            let denominator = previousLatitude - currentLatitude
            let safeDenominator = abs(denominator) < 0.000_000_1 ? 0.000_000_1 : denominator
            let edgeLongitude = (
                (previousLongitude - currentLongitude) * (latitude - currentLatitude) / safeDenominator
            ) + currentLongitude
            if longitude < edgeLongitude {
                contains.toggle()
            }
        }

        previousIndex = index
    }

    return contains
}

private func derivedLocationTrigger(from polygon: [LocationCoordinate]) -> TaskLocationTrigger? {
    guard polygon.count >= 3 else { return nil }

    let averageLatitude = polygon.map(\.latitude).reduce(0, +) / Double(polygon.count)
    let averageLongitude = polygon.map(\.longitude).reduce(0, +) / Double(polygon.count)
    let center = LocationCoordinate(latitude: averageLatitude, longitude: averageLongitude)
    let centerLocation = CLLocation(latitude: averageLatitude, longitude: averageLongitude)
    let radiusMeters = polygon
        .map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: centerLocation)
        }
        .max() ?? 100

    return TaskLocationTrigger(
        center: center,
        radiusMeters: max(radiusMeters, 100),
        polygon: polygon
    )
}

private func locationTriggerSummary(_ trigger: TaskLocationTrigger) -> String {
    let radius = Int(trigger.radiusMeters.rounded())
    if trigger.usesPolygon {
        return "Drawn area • \(trigger.polygon.count) points • \(radius)m fallback radius"
    }
    return "\(radius)m radius"
}

private func dependencyDescription(
    for reference: DependencyReference,
    in tasks: [TaskItem]
) -> String {
    guard let task = tasks.first(where: { $0.id == reference.taskID }) else {
        return "Missing dependency"
    }

    guard !reference.isTask else {
        return task.title
    }

    guard let titles = subtaskTitlePath(
        at: reference.descendantIDs,
        active: task.subtasks,
        graveyard: task.subtaskGraveyard
    ) else {
        return "Missing dependency"
    }

    return ([task.title] + titles).joined(separator: " / ")
}

private func dependencySubtitle(
    for reference: DependencyReference,
    in tasks: [TaskItem]
) -> String {
    guard let task = tasks.first(where: { $0.id == reference.taskID }) else {
        return "Task or subtask no longer exists"
    }

    if !reference.isTask {
        return "Subtask in \(task.title)"
    }

    return "Task"
}

private func subtaskPlanningState(
    for subtask: SubtaskItem,
    referenceDate: Date = Date(),
    dailyCapacityMinutes: Int = defaultDailyCapacityMinutes,
    calendar: Calendar = .current
) -> TaskPlanningState {
    let today = calendar.startOfDay(for: referenceDate)
    let safeCapacity = max(1, dailyCapacityMinutes)
    let normalizedEstimate: Int? = {
        guard let estimate = subtask.estimatedMinutes, estimate > 0 else { return nil }
        return estimate
    }()

    let latestSafe = subtask.dueDate.map { dueDate in
        latestSafeStartDay(
            dueDate: dueDate,
            estimatedMinutes: normalizedEstimate,
            dailyCapacityMinutes: safeCapacity,
            calendar: calendar
        )
    }

    let mustStartNow: Bool = {
        guard normalizedEstimate != nil, let latestSafe else { return false }
        return latestSafe <= today
    }()
    let highRiskUnknown: Bool = {
        guard normalizedEstimate == nil, let dueDate = subtask.dueDate else { return false }
        let dueDay = calendar.startOfDay(for: dueDate)
        let nearFutureLimit = calendar.date(byAdding: .day, value: highRiskDueWindowDays, to: today) ?? today
        return dueDay <= nearFutureLimit
    }()

    return TaskPlanningState(
        hasDueDate: subtask.dueDate != nil,
        latestSafeStartDay: latestSafe,
        mustStartNow: mustStartNow,
        highRiskUnknown: highRiskUnknown,
        hasKnownEstimate: normalizedEstimate != nil,
        estimateMinutes: normalizedEstimate
    )
}

private func allActiveSubtasks(in subtasks: [SubtaskItem]) -> [SubtaskItem] {
    subtasks.flatMap { subtask in
        [subtask] + allActiveSubtasks(in: subtask.subtasks)
    }
}

private func mostPressingActiveSubtask(
    in subtasks: [SubtaskItem],
    referenceDate: Date = Date(),
    dailyCapacityMinutes: Int = defaultDailyCapacityMinutes,
    calendar: Calendar = .current
) -> SubtaskItem? {
    let activeSubtasks = allActiveSubtasks(in: subtasks).filter { $0.status == .active }
    guard !activeSubtasks.isEmpty else { return nil }

    return activeSubtasks.min { left, right in
        subtaskSortComparator(
            left,
            right,
            dailyCapacityMinutes: dailyCapacityMinutes,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }
}

private func mostPressingActiveSubtaskReference(
    in task: TaskItem,
    referenceDate: Date = Date(),
    dailyCapacityMinutes: Int = defaultDailyCapacityMinutes,
    calendar: Calendar = .current
) -> ReferencedSubtask? {
    let activeSubtasks = referencedActiveSubtasks(taskID: task.id, in: task.subtasks)
        .filter { $0.subtask.status == .active && !hasActiveDescendants($0.subtask) }
    guard !activeSubtasks.isEmpty else { return nil }

    return activeSubtasks.min { left, right in
        subtaskSortComparator(
            left.subtask,
            right.subtask,
            dailyCapacityMinutes: dailyCapacityMinutes,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }
}

private func latestSafeStartDay(
    dueDate: Date,
    estimatedMinutes: Int?,
    dailyCapacityMinutes: Int = defaultDailyCapacityMinutes,
    calendar: Calendar = .current
) -> Date {
    let dueDay = calendar.startOfDay(for: dueDate)
    guard let estimatedMinutes, estimatedMinutes > 0 else { return dueDay }
    let safeCapacity = max(1, dailyCapacityMinutes)
    let requiredDays = max(1, Int(ceil(Double(estimatedMinutes) / Double(safeCapacity))))
    return calendar.date(byAdding: .day, value: -(requiredDays - 1), to: dueDay) ?? dueDay
}

private func taskPlanningState(
    for task: TaskItem,
    referenceDate: Date = Date(),
    dailyCapacityMinutes: Int = defaultDailyCapacityMinutes,
    calendar: Calendar = .current
) -> TaskPlanningState {
    let today = calendar.startOfDay(for: referenceDate)
    let safeCapacity = max(1, dailyCapacityMinutes)
    let normalizedEstimate: Int? = {
        guard let estimate = task.estimatedMinutes, estimate > 0 else { return nil }
        return estimate
    }()

    let latestSafe = task.dueDate.map { dueDate in
        latestSafeStartDay(
            dueDate: dueDate,
            estimatedMinutes: normalizedEstimate,
            dailyCapacityMinutes: safeCapacity,
            calendar: calendar
        )
    }

    let mustStartNowFromTiming: Bool = {
        guard normalizedEstimate != nil, let latestSafe else { return false }
        return latestSafe <= today
    }()
    let mustStartNow = task.isManuallyMustDoNow || mustStartNowFromTiming

    let highRiskUnknown: Bool = {
        guard normalizedEstimate == nil, let dueDate = task.dueDate else { return false }
        guard task.priority >= highRiskPriorityThreshold else { return false }
        let dueDay = calendar.startOfDay(for: dueDate)
        let nearFutureLimit = calendar.date(byAdding: .day, value: highRiskDueWindowDays, to: today) ?? today
        return dueDay <= nearFutureLimit
    }()

    return TaskPlanningState(
        hasDueDate: task.dueDate != nil,
        latestSafeStartDay: latestSafe,
        mustStartNow: mustStartNow,
        highRiskUnknown: highRiskUnknown,
        hasKnownEstimate: normalizedEstimate != nil,
        estimateMinutes: normalizedEstimate
    )
}

private struct SubtaskPlanningSummary {
    let hasDueDate: Bool
    let earliestSafeStartDay: Date?
    let mustStartNow: Bool
    let highRiskUnknown: Bool
    let hasKnownEstimate: Bool
    let shortestEstimateMinutes: Int?
}

private func subtaskPlanningSummary(
    in subtasks: [SubtaskItem],
    referenceDate: Date = Date(),
    dailyCapacityMinutes: Int = defaultDailyCapacityMinutes,
    calendar: Calendar = .current
) -> SubtaskPlanningSummary {
    guard let subtask = mostPressingActiveSubtask(
        in: subtasks,
        referenceDate: referenceDate,
        dailyCapacityMinutes: dailyCapacityMinutes,
        calendar: calendar
    ) else {
        return SubtaskPlanningSummary(
            hasDueDate: false,
            earliestSafeStartDay: nil,
            mustStartNow: false,
            highRiskUnknown: false,
            hasKnownEstimate: false,
            shortestEstimateMinutes: nil
        )
    }

    let planningState = subtaskPlanningState(
        for: subtask,
        referenceDate: referenceDate,
        dailyCapacityMinutes: dailyCapacityMinutes,
        calendar: calendar
    )

    return SubtaskPlanningSummary(
        hasDueDate: planningState.hasDueDate,
        earliestSafeStartDay: planningState.latestSafeStartDay,
        mustStartNow: planningState.mustStartNow,
        highRiskUnknown: planningState.highRiskUnknown,
        hasKnownEstimate: planningState.hasKnownEstimate,
        shortestEstimateMinutes: planningState.estimateMinutes
    )
}

private func subtaskPlanningSummary(
    for task: TaskItem,
    referenceDate: Date = Date(),
    dailyCapacityMinutes: Int = defaultDailyCapacityMinutes,
    calendar: Calendar = .current
) -> SubtaskPlanningSummary {
    subtaskPlanningSummary(
        in: task.subtasks,
        referenceDate: referenceDate,
        dailyCapacityMinutes: dailyCapacityMinutes,
        calendar: calendar
    )
}

private func earliestDate(_ first: Date?, _ second: Date?) -> Date? {
    switch (first, second) {
    case let (first?, second?):
        return min(first, second)
    case let (first?, nil):
        return first
    case let (nil, second?):
        return second
    case (nil, nil):
        return nil
    }
}

private func shortestEstimateMinutes(_ first: Int?, _ second: Int?) -> Int? {
    switch (first, second) {
    case let (first?, second?):
        return min(first, second)
    case let (first?, nil):
        return first
    case let (nil, second?):
        return second
    case (nil, nil):
        return nil
    }
}

private func applyStatusChange(
    to task: inout TaskItem,
    newStatus: WorkingStatus,
    now: Date = Date()
) {
    let previousStatus = task.status
    if previousStatus != newStatus {
        task.status = newStatus
    }
    switch newStatus {
    case .active:
        task.onHoldSince = nil
        task.onHoldUntil = nil
    case .onHold:
        if previousStatus != .onHold || task.onHoldSince == nil {
            task.onHoldSince = now
        }
    }
}

private func applyTimedHold(
    to task: inout TaskItem,
    holdUntil: Date,
    now: Date = Date()
) {
    applyStatusChange(to: &task, newStatus: .onHold, now: now)
    task.onHoldUntil = holdUntil
}

private func subtaskSortComparator(
    _ left: SubtaskItem,
    _ right: SubtaskItem,
    dailyCapacityMinutes: Int = defaultDailyCapacityMinutes,
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> Bool {
    let leftState = subtaskPlanningState(
        for: left,
        referenceDate: referenceDate,
        dailyCapacityMinutes: dailyCapacityMinutes,
        calendar: calendar
    )
    let rightState = subtaskPlanningState(
        for: right,
        referenceDate: referenceDate,
        dailyCapacityMinutes: dailyCapacityMinutes,
        calendar: calendar
    )
    let leftChildSummary = subtaskPlanningSummary(
        in: left.subtasks,
        referenceDate: referenceDate,
        dailyCapacityMinutes: dailyCapacityMinutes,
        calendar: calendar
    )
    let rightChildSummary = subtaskPlanningSummary(
        in: right.subtasks,
        referenceDate: referenceDate,
        dailyCapacityMinutes: dailyCapacityMinutes,
        calendar: calendar
    )

    let leftMustStartNow = leftState.mustStartNow || leftChildSummary.mustStartNow
    let rightMustStartNow = rightState.mustStartNow || rightChildSummary.mustStartNow
    if leftMustStartNow != rightMustStartNow {
        return leftMustStartNow && !rightMustStartNow
    }

    let leftHighRiskUnknown = leftState.highRiskUnknown || leftChildSummary.highRiskUnknown
    let rightHighRiskUnknown = rightState.highRiskUnknown || rightChildSummary.highRiskUnknown
    if leftHighRiskUnknown != rightHighRiskUnknown {
        return leftHighRiskUnknown && !rightHighRiskUnknown
    }

    let leftHasDueDate = leftState.hasDueDate || leftChildSummary.hasDueDate
    let rightHasDueDate = rightState.hasDueDate || rightChildSummary.hasDueDate
    if leftHasDueDate != rightHasDueDate {
        return leftHasDueDate && !rightHasDueDate
    }

    if leftHasDueDate, rightHasDueDate {
        let leftSafe = earliestDate(leftState.latestSafeStartDay, leftChildSummary.earliestSafeStartDay) ?? .distantFuture
        let rightSafe = earliestDate(rightState.latestSafeStartDay, rightChildSummary.earliestSafeStartDay) ?? .distantFuture
        if leftSafe != rightSafe {
            return leftSafe < rightSafe
        }
    }

    let leftHasKnownEstimate = leftState.hasKnownEstimate || leftChildSummary.hasKnownEstimate
    let rightHasKnownEstimate = rightState.hasKnownEstimate || rightChildSummary.hasKnownEstimate
    if leftHasKnownEstimate != rightHasKnownEstimate {
        return leftHasKnownEstimate && !rightHasKnownEstimate
    }

    if let leftEstimate = shortestEstimateMinutes(leftState.estimateMinutes, leftChildSummary.shortestEstimateMinutes),
       let rightEstimate = shortestEstimateMinutes(rightState.estimateMinutes, rightChildSummary.shortestEstimateMinutes),
       leftEstimate != rightEstimate {
        return leftEstimate < rightEstimate
    }

    if left.createdAt != right.createdAt {
        return left.createdAt < right.createdAt
    }

    let titleOrder = left.title.localizedCaseInsensitiveCompare(right.title)
    if titleOrder != .orderedSame {
        return titleOrder == .orderedAscending
    }

    return left.id.uuidString < right.id.uuidString
}

private func taskSortComparator(
    _ left: TaskItem,
    _ right: TaskItem,
    dailyCapacityMinutes: Int = defaultDailyCapacityMinutes,
    referenceDate: Date = Date(),
    calendar: Calendar = .current
) -> Bool {
    let leftState = taskPlanningState(
        for: left,
        referenceDate: referenceDate,
        dailyCapacityMinutes: dailyCapacityMinutes,
        calendar: calendar
    )
    let rightState = taskPlanningState(
        for: right,
        referenceDate: referenceDate,
        dailyCapacityMinutes: dailyCapacityMinutes,
        calendar: calendar
    )
    let leftSubtaskSummary = subtaskPlanningSummary(
        for: left,
        referenceDate: referenceDate,
        dailyCapacityMinutes: dailyCapacityMinutes,
        calendar: calendar
    )
    let rightSubtaskSummary = subtaskPlanningSummary(
        for: right,
        referenceDate: referenceDate,
        dailyCapacityMinutes: dailyCapacityMinutes,
        calendar: calendar
    )

    let leftMustStartNow = leftState.mustStartNow || leftSubtaskSummary.mustStartNow
    let rightMustStartNow = rightState.mustStartNow || rightSubtaskSummary.mustStartNow

    if leftMustStartNow != rightMustStartNow {
        return leftMustStartNow && !rightMustStartNow
    }

    let leftHighRiskUnknown = leftState.highRiskUnknown || leftSubtaskSummary.highRiskUnknown
    let rightHighRiskUnknown = rightState.highRiskUnknown || rightSubtaskSummary.highRiskUnknown
    if leftHighRiskUnknown != rightHighRiskUnknown {
        return leftHighRiskUnknown && !rightHighRiskUnknown
    }

    let leftHasDueDate = leftState.hasDueDate || leftSubtaskSummary.hasDueDate
    let rightHasDueDate = rightState.hasDueDate || rightSubtaskSummary.hasDueDate
    if leftHasDueDate != rightHasDueDate {
        return leftHasDueDate && !rightHasDueDate
    }

    if leftHasDueDate, rightHasDueDate {
        let leftSafe = earliestDate(leftState.latestSafeStartDay, leftSubtaskSummary.earliestSafeStartDay) ?? .distantFuture
        let rightSafe = earliestDate(rightState.latestSafeStartDay, rightSubtaskSummary.earliestSafeStartDay) ?? .distantFuture
        if leftSafe != rightSafe {
            return leftSafe < rightSafe
        }
    }

    if left.priority != right.priority {
        return left.priority > right.priority
    }

    let leftHasKnownEstimate = leftState.hasKnownEstimate || leftSubtaskSummary.hasKnownEstimate
    let rightHasKnownEstimate = rightState.hasKnownEstimate || rightSubtaskSummary.hasKnownEstimate
    if leftHasKnownEstimate != rightHasKnownEstimate {
        return leftHasKnownEstimate && !rightHasKnownEstimate
    }

    if let leftEstimate = shortestEstimateMinutes(leftState.estimateMinutes, leftSubtaskSummary.shortestEstimateMinutes),
       let rightEstimate = shortestEstimateMinutes(rightState.estimateMinutes, rightSubtaskSummary.shortestEstimateMinutes),
       leftEstimate != rightEstimate {
        return leftEstimate < rightEstimate
    }

    if left.createdAt != right.createdAt {
        return left.createdAt < right.createdAt
    }

    let titleOrder = left.title.localizedCaseInsensitiveCompare(right.title)
    if titleOrder != .orderedSame {
        return titleOrder == .orderedAscending
    }

    return left.id.uuidString < right.id.uuidString
}

private struct AddSeriesSheet: View {
    let initialMapCenter: CLLocationCoordinate2D?
    let dailyCapacityMinutes: Int
    let onAdd: (RecurringSeries) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var frequency: RecurrenceFrequency = .everyDays
    @State private var priority = 3
    @State private var hasDueDate = false
    @State private var dueDateOffsetDays = 1
    @State private var hasEstimate = false
    @State private var estimateUnit: TaskEstimateUnit = .hour
    @State private var intervalDays = 2
    @State private var weeklyDays: Set<Weekday> = [.monday]
    @State private var appearanceTime = Calendar.current.date(
        bySettingHour: 9,
        minute: 0,
        second: 0,
        of: Date()
    ) ?? Date()
    @State private var locationTrigger: TaskLocationTrigger? = nil
    @State private var showingLocationEditor = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    Stepper("Priority \(priority)", value: $priority, in: 1...5)
                    Toggle("Has due date", isOn: $hasDueDate)
                    if hasDueDate {
                        Stepper("Due \(dueDateOffsetDays) days after", value: $dueDateOffsetDays, in: 0...30)
                    }
                    Toggle("Has estimate", isOn: $hasEstimate)
                    if hasEstimate {
                        Picker("Estimate unit", selection: $estimateUnit) {
                            ForEach(TaskEstimateUnit.allCases) { unit in
                                Text(unit.rawValue).tag(unit)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section("Timing") {
                    DatePicker(
                        "Appears at",
                        selection: $appearanceTime,
                        displayedComponents: .hourAndMinute
                    )
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
                } else if frequency == .weekly {
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
                } else {
                    Section("Monthly") {
                        Text("Generates once every month.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Location activation") {
                    Toggle(
                        "Activate by location",
                        isOn: Binding(
                            get: { locationTrigger != nil },
                            set: { isEnabled in
                                if isEnabled {
                                    locationTrigger = locationTrigger ?? TaskLocationTrigger(
                                        center: LocationCoordinate(
                                            initialMapCenter
                                                ?? CLLocationCoordinate2D(latitude: 47.3769, longitude: 8.5417)
                                        ),
                                        radiusMeters: 250
                                    )
                                } else {
                                    locationTrigger = nil
                                }
                            }
                        )
                    )

                    if let locationTrigger {
                        Button("Choose activation area") {
                            showingLocationEditor = true
                        }
                        Text(locationTriggerSummary(locationTrigger))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        series.estimatedMinutes = hasEstimate ? estimateInMinutes : nil
                        let components = Calendar.current.dateComponents([.hour, .minute], from: appearanceTime)
                        series.appearanceHour = components.hour ?? 9
                        series.appearanceMinute = components.minute ?? 0
                        series.locationTrigger = locationTrigger
                        if frequency == .everyDays {
                            series.intervalDays = intervalDays
                            series.weeklyDays = []
                        } else if frequency == .weekly {
                            series.weeklyDays = weeklyDays
                        } else {
                            series.weeklyDays = []
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
            .sheet(isPresented: $showingLocationEditor) {
                LocationTriggerEditorSheet(
                    initialTrigger: locationTrigger,
                    initialCenter: initialMapCenter
                ) { trigger in
                    locationTrigger = trigger
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

    private var estimateInMinutes: Int {
        estimateMinutes(
            for: estimateUnit,
            dailyCapacityMinutes: dailyCapacityMinutes
        )
    }
}

private struct EditSeriesSheet: View {
    let series: RecurringSeries
    let initialMapCenter: CLLocationCoordinate2D?
    let dailyCapacityMinutes: Int
    let onSave: (RecurringSeries) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var frequency: RecurrenceFrequency
    @State private var priority: Int
    @State private var hasDueDate: Bool
    @State private var dueDateOffsetDays: Int
    @State private var hasEstimate: Bool
    @State private var estimateUnit: TaskEstimateUnit
    @State private var intervalDays: Int
    @State private var weeklyDays: Set<Weekday>
    @State private var appearanceTime: Date
    @State private var locationTrigger: TaskLocationTrigger?
    @State private var showingLocationEditor = false

    init(
        series: RecurringSeries,
        initialMapCenter: CLLocationCoordinate2D?,
        dailyCapacityMinutes: Int,
        onSave: @escaping (RecurringSeries) -> Void
    ) {
        self.series = series
        self.initialMapCenter = initialMapCenter
        self.dailyCapacityMinutes = max(1, dailyCapacityMinutes)
        self.onSave = onSave
        _title = State(initialValue: series.title)
        _frequency = State(initialValue: series.frequency)
        _priority = State(initialValue: series.priority)
        _hasDueDate = State(initialValue: series.dueDateOffsetDays != nil)
        _dueDateOffsetDays = State(initialValue: series.dueDateOffsetDays ?? 1)
        _hasEstimate = State(initialValue: series.estimatedMinutes != nil)
        _estimateUnit = State(initialValue: estimateUnitForMinutes(
            for: series.estimatedMinutes,
            dailyCapacityMinutes: max(1, dailyCapacityMinutes)
        ))
        _intervalDays = State(initialValue: series.intervalDays)
        _weeklyDays = State(initialValue: series.weeklyDays)
        _appearanceTime = State(initialValue: Calendar.current.date(
            bySettingHour: series.appearanceHour,
            minute: series.appearanceMinute,
            second: 0,
            of: Date()
        ) ?? Date())
        _locationTrigger = State(initialValue: series.locationTrigger)
    }

    var body: some View {
        Form {
            Section("Details") {
                Stepper("Priority \(priority)", value: $priority, in: 1...5)
                Toggle("Has due date", isOn: $hasDueDate)
                if hasDueDate {
                    Stepper("Due \(dueDateOffsetDays) days after", value: $dueDateOffsetDays, in: 0...30)
                }
                Toggle("Has estimate", isOn: $hasEstimate)
                if hasEstimate {
                    Picker("Estimate unit", selection: $estimateUnit) {
                        ForEach(TaskEstimateUnit.allCases) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Section("Timing") {
                DatePicker(
                    "Appears at",
                    selection: $appearanceTime,
                    displayedComponents: .hourAndMinute
                )
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
            } else if frequency == .weekly {
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
            } else {
                Section("Monthly") {
                    Text("Generates once every month.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Location activation") {
                Toggle(
                    "Activate by location",
                    isOn: Binding(
                        get: { locationTrigger != nil },
                        set: { isEnabled in
                            if isEnabled {
                                locationTrigger = locationTrigger ?? TaskLocationTrigger(
                                    center: LocationCoordinate(
                                        initialMapCenter
                                            ?? CLLocationCoordinate2D(latitude: 47.3769, longitude: 8.5417)
                                    ),
                                    radiusMeters: 250
                                )
                            } else {
                                locationTrigger = nil
                            }
                        }
                    )
                )

                if let locationTrigger {
                    Button("Choose activation area") {
                        showingLocationEditor = true
                    }
                    Text(locationTriggerSummary(locationTrigger))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    updated.estimatedMinutes = hasEstimate ? estimateInMinutes : nil
                    let components = Calendar.current.dateComponents([.hour, .minute], from: appearanceTime)
                    updated.appearanceHour = components.hour ?? 9
                    updated.appearanceMinute = components.minute ?? 0
                    updated.locationTrigger = locationTrigger
                    if frequency == .everyDays {
                        updated.intervalDays = intervalDays
                        updated.weeklyDays = []
                    } else if frequency == .weekly {
                        updated.weeklyDays = weeklyDays
                    } else {
                        updated.weeklyDays = []
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
        .sheet(isPresented: $showingLocationEditor) {
            LocationTriggerEditorSheet(
                initialTrigger: locationTrigger,
                initialCenter: initialMapCenter
            ) { trigger in
                locationTrigger = trigger
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

    private var estimateInMinutes: Int {
        estimateMinutes(
            for: estimateUnit,
            dailyCapacityMinutes: dailyCapacityMinutes
        )
    }
}

private final class NotificationManager {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let seriesReminderThrottleInterval: TimeInterval = 6 * 60 * 60

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
        let throttleKey = "series-pending-reminder-\(seriesID.uuidString)"
        let now = Date().timeIntervalSince1970
        let lastSentAt = defaults.double(forKey: throttleKey)
        guard now - lastSentAt >= seriesReminderThrottleInterval else { return }

        let content = UNMutableNotificationContent()
        content.title = "Recurring task still active"
        content.body = "\(title) is still in your tasks list. Complete it before the next scheduled entry."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "series-pending-\(seriesID.uuidString)", content: content, trigger: trigger)
        center.add(request)
        defaults.set(now, forKey: throttleKey)
    }

    func sendLocationActivationReminder(title: String, taskID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "Task activated"
        content.body = "\(title) is now active because you reached its activation area."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "location-activation-\(taskID.uuidString)",
            content: content,
            trigger: trigger
        )
        center.add(request)
    }
}

#Preview {
    ContentView()
}
