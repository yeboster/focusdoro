import CoreData
import Foundation

public enum SessionStoreError: Error, Equatable {
    case storeUnavailable(String)
    case notFound(UUID)

    public var userMessage: String {
        switch self {
        case .storeUnavailable(let detail):
            return "Local history is unavailable: \(detail). Focus sessions will not be saved until this is fixed."
        case .notFound:
            return "That session is no longer in local history."
        }
    }
}

public protocol SessionStoring: AnyObject {
    func insertSession(_ record: SessionRecord) throws
    func updateSession(_ record: SessionRecord) throws
    func session(id: UUID) throws -> SessionRecord?
    func markCommentStatus(sessionID: UUID, status: CommentStatus, commentID: String?) throws
    func todaySummary(now: Date, calendar: Calendar) throws -> TodaySummary
    func recentSessions(limit: Int) throws -> [SessionRecord]
    func sessionsNeedingCommentRetry() throws -> [SessionRecord]
}

/// Core Data stack with a programmatic `NSManagedObjectModel` so the schema is
/// versioned in code and testable without an Xcode-compiled `.momd`.
public final class SessionStore: SessionStoring, @unchecked Sendable {
    public static let modelVersion = 1
    private let container: NSPersistentContainer
    private let context: NSManagedObjectContext

    public init(inMemory: Bool = false, storeURL: URL? = nil) throws {
        let container = NSPersistentContainer(name: "Focusdoro", managedObjectModel: Self.makeModel(uniqueByID: !inMemory))
        let description: NSPersistentStoreDescription
        if inMemory {
            description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
        } else {
            let url = try storeURL ?? Self.defaultStoreURL()
            description = NSPersistentStoreDescription(url: url)
            description.type = NSSQLiteStoreType
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            throw SessionStoreError.storeUnavailable(loadError.localizedDescription)
        }

        self.container = container
        self.context = container.viewContext
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.automaticallyMergesChangesFromParent = true
    }

    public static func defaultStoreURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Focusdoro", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("Focusdoro.sqlite")
    }

    // MARK: - Schema

    /// `NSInMemoryStoreType` rejects uniqueness constraints, so the SQLite store
    /// gets the store-level guard and both paths keep the fetch-before-insert guard.
    static func makeModel(uniqueByID: Bool = true) -> NSManagedObjectModel {
        let entity = NSEntityDescription()
        entity.name = "FocusSession"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)

        func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = optional
            return attribute
        }

        let id = attribute("id", .UUIDAttributeType)
        entity.properties = [
            id,
            attribute("taskID", .stringAttributeType),
            attribute("taskTitleSnapshot", .stringAttributeType),
            attribute("startedAt", .dateAttributeType),
            attribute("endedAt", .dateAttributeType, optional: true),
            attribute("plannedDurationSeconds", .integer32AttributeType),
            attribute("elapsedDurationSeconds", .integer32AttributeType),
            attribute("kind", .stringAttributeType),
            attribute("status", .stringAttributeType),
            attribute("todoistCommentStatus", .stringAttributeType),
            attribute("todoistCommentID", .stringAttributeType, optional: true),
            attribute("createdAt", .dateAttributeType),
        ]
        // Store-level uniqueness makes duplicate session inserts impossible.
        if uniqueByID { entity.uniquenessConstraints = [[id]] }

        let model = NSManagedObjectModel()
        model.entities = [entity]
        model.versionIdentifiers = [String(modelVersion)]
        return model
    }

    // MARK: - Writes

    public func insertSession(_ record: SessionRecord) throws {
        var thrown: Error?
        context.performAndWait {
            do {
                if let existing = try fetchObject(id: record.id) {
                    apply(record, to: existing)
                } else {
                    let object = NSEntityDescription.insertNewObject(forEntityName: "FocusSession", into: context)
                    apply(record, to: object)
                }
                try context.save()
            } catch {
                context.rollback()
                thrown = error
            }
        }
        if let thrown { throw thrown }
    }

    /// Same semantics as insert: session id is the idempotency key.
    public func updateSession(_ record: SessionRecord) throws {
        try insertSession(record)
    }

    public func markCommentStatus(sessionID: UUID, status: CommentStatus, commentID: String?) throws {
        var thrown: Error?
        context.performAndWait {
            do {
                guard let object = try fetchObject(id: sessionID) else {
                    thrown = SessionStoreError.notFound(sessionID)
                    return
                }
                object.setValue(status.rawValue, forKey: "todoistCommentStatus")
                if let commentID { object.setValue(commentID, forKey: "todoistCommentID") }
                try context.save()
            } catch {
                context.rollback()
                thrown = error
            }
        }
        if let thrown { throw thrown }
    }

    // MARK: - Reads

    public func session(id: UUID) throws -> SessionRecord? {
        var result: SessionRecord?
        var thrown: Error?
        context.performAndWait {
            do { result = try fetchObject(id: id).map(record(from:)) } catch { thrown = error }
        }
        if let thrown { throw thrown }
        return result
    }

    public func recentSessions(limit: Int) throws -> [SessionRecord] {
        try fetchRecords(limit: limit) { request in
            request.predicate = NSPredicate(format: "endedAt != nil")
            request.sortDescriptors = [NSSortDescriptor(key: "endedAt", ascending: false)]
        }
    }

    public func sessionsNeedingCommentRetry() throws -> [SessionRecord] {
        try fetchRecords(limit: 0) { request in
            request.predicate = NSPredicate(
                format: "todoistCommentStatus IN %@", [CommentStatus.failed.rawValue, CommentStatus.pending.rawValue]
            )
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        }
    }

    /// Local calendar day boundaries; no network round trip (acceptance criterion 10).
    public func todaySummary(now: Date, calendar: Calendar) throws -> TodaySummary {
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return TodaySummary()
        }

        let todays = try fetchRecords(limit: 0) { request in
            request.predicate = NSPredicate(
                format: "kind == %@ AND status == %@ AND endedAt >= %@ AND endedAt < %@",
                TimerPhase.focus.rawValue, SessionStatus.completed.rawValue, start as NSDate, end as NSDate
            )
        }

        let seconds = todays.reduce(0) { $0 + Int($1.elapsedDurationSeconds) }

        // Stopped sessions are reported separately: the time was invested, but it is
        // neither a completed session nor streak-worthy.
        let abandonedToday = try fetchRecords(limit: 0) { request in
            request.predicate = NSPredicate(
                format: "kind == %@ AND status == %@ AND endedAt >= %@ AND endedAt < %@",
                TimerPhase.focus.rawValue, SessionStatus.abandoned.rawValue, start as NSDate, end as NSDate
            )
        }
        let partialSeconds = abandonedToday.reduce(0) { $0 + Int($1.elapsedDurationSeconds) }

        // Streak: consecutive days back from today with at least one completed focus.
        let completed = try fetchRecords(limit: 0) { request in
            request.predicate = NSPredicate(
                format: "kind == %@ AND status == %@ AND endedAt != nil",
                TimerPhase.focus.rawValue, SessionStatus.completed.rawValue
            )
            request.sortDescriptors = [NSSortDescriptor(key: "endedAt", ascending: false)]
        }
        let days = Set(completed.compactMap { $0.endedAt.map { calendar.startOfDay(for: $0) } })

        var streak = 0
        var cursor = start
        // A streak that ended yesterday still counts until today's first session.
        if !days.contains(cursor), let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        return TodaySummary(
            focusedSeconds: seconds,
            partialSeconds: partialSeconds,
            completedFocusSessions: todays.count,
            abandonedFocusSessions: abandonedToday.count,
            streakDays: streak
        )
    }

    // MARK: - Helpers

    private func fetchRecords(limit: Int, configure: (NSFetchRequest<NSManagedObject>) -> Void) throws -> [SessionRecord] {
        var results: [SessionRecord] = []
        var thrown: Error?
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "FocusSession")
            if limit > 0 { request.fetchLimit = limit }
            configure(request)
            do {
                results = try context.fetch(request).map(record(from:))
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
        return results
    }

    private func fetchObject(id: UUID) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "FocusSession")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func apply(_ record: SessionRecord, to object: NSManagedObject) {
        object.setValue(record.id, forKey: "id")
        object.setValue(record.taskID, forKey: "taskID")
        object.setValue(record.taskTitleSnapshot, forKey: "taskTitleSnapshot")
        object.setValue(record.startedAt, forKey: "startedAt")
        object.setValue(record.endedAt, forKey: "endedAt")
        object.setValue(record.plannedDurationSeconds, forKey: "plannedDurationSeconds")
        object.setValue(record.elapsedDurationSeconds, forKey: "elapsedDurationSeconds")
        object.setValue(record.kind.rawValue, forKey: "kind")
        object.setValue(record.status.rawValue, forKey: "status")
        object.setValue(record.todoistCommentStatus.rawValue, forKey: "todoistCommentStatus")
        object.setValue(record.todoistCommentID, forKey: "todoistCommentID")
        object.setValue(record.createdAt, forKey: "createdAt")
    }

    private func record(from object: NSManagedObject) -> SessionRecord {
        SessionRecord(
            id: object.value(forKey: "id") as? UUID ?? UUID(),
            taskID: object.value(forKey: "taskID") as? String ?? "",
            taskTitleSnapshot: object.value(forKey: "taskTitleSnapshot") as? String ?? "",
            startedAt: object.value(forKey: "startedAt") as? Date ?? .distantPast,
            endedAt: object.value(forKey: "endedAt") as? Date,
            plannedDurationSeconds: object.value(forKey: "plannedDurationSeconds") as? Int32 ?? 0,
            elapsedDurationSeconds: object.value(forKey: "elapsedDurationSeconds") as? Int32 ?? 0,
            kind: TimerPhase(rawValue: object.value(forKey: "kind") as? String ?? "") ?? .focus,
            status: SessionStatus(rawValue: object.value(forKey: "status") as? String ?? "") ?? .interrupted,
            todoistCommentStatus: CommentStatus(rawValue: object.value(forKey: "todoistCommentStatus") as? String ?? "") ?? .notApplicable,
            todoistCommentID: object.value(forKey: "todoistCommentID") as? String,
            createdAt: object.value(forKey: "createdAt") as? Date ?? .distantPast
        )
    }
}
