import Foundation

public struct ActivityFilter: Equatable, Sendable {
    public var query: String
    public var importances: Set<EventImportance>
    public var actorTypes: Set<EventActorType>
    public var statuses: Set<EventStatus>

    public init(
        query: String = "",
        importances: Set<EventImportance> = [],
        actorTypes: Set<EventActorType> = [],
        statuses: Set<EventStatus> = []
    ) {
        self.query = query
        self.importances = importances
        self.actorTypes = actorTypes
        self.statuses = statuses
    }

    public func matches(_ event: OperationEvent) -> Bool {
        guard importances.isEmpty || importances.contains(event.importance) else { return false }
        guard actorTypes.isEmpty || actorTypes.contains(event.actor.type) else { return false }
        guard statuses.isEmpty || statuses.contains(event.status) else { return false }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return true }

        let searchable = [
            event.title,
            event.summary,
            event.action,
            event.category.rawValue,
            event.actor.id,
            event.actor.label,
            event.thread?.id,
            event.thread?.title,
            event.project?.name,
            event.project?.path,
            event.account?.profile,
            event.account?.label,
        ]
        .compactMap { $0 }
        + event.sourceChain.flatMap { [$0.id, $0.label] }
        + (event.changes ?? []).flatMap { [$0.label, $0.summary, $0.before, $0.after].compactMap { $0 } }
        + (event.relatedThreads ?? []).flatMap {
            [$0.id, $0.title, $0.projectName, $0.projectPath].compactMap { $0 }
        }

        return searchable.contains {
            $0.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }
}

public struct ActivityDaySection: Identifiable, Equatable, Sendable {
    public let day: Date
    public let events: [OperationEvent]

    public var id: Date { day }

    public init(day: Date, events: [OperationEvent]) {
        self.day = day
        self.events = events
    }
}

public enum ActivityGrouper {
    public static func sections(
        for events: [OperationEvent],
        calendar: Calendar = .current
    ) -> [ActivityDaySection] {
        let grouped = Dictionary(grouping: events) {
            calendar.startOfDay(for: $0.occurredAt)
        }
        return grouped
            .map { day, dayEvents in
                ActivityDaySection(
                    day: day,
                    events: dayEvents.sorted { $0.occurredAt > $1.occurredAt }
                )
            }
            .sorted { $0.day > $1.day }
    }
}

public enum ActivityInsights {
    public static func requiresAttention(_ event: OperationEvent) -> Bool {
        if event.status == .failure || event.certainty != .confirmed {
            return true
        }

        return event.importance == .critical
            && [.quota, .account, .automation].contains(event.category)
    }
}
