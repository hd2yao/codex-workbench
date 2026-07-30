import Foundation

public enum EventCategory: String, Codable, CaseIterable, Sendable {
    case account
    case automation
    case context
    case hook
    case plugin
    case quota
    case skill
    case system
    case thread
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

public enum EventStatus: String, Codable, CaseIterable, Sendable {
    case failure
    case inProgress = "in_progress"
    case skipped
    case success
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

public enum EventImportance: String, Codable, CaseIterable, Sendable {
    case critical
    case diagnostic
    case important
    case routine

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .important
    }
}

public enum EventCertainty: String, Codable, CaseIterable, Sendable {
    case confirmed
    case inferred
    case unverified

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unverified
    }
}

public enum EventActorType: String, Codable, CaseIterable, Sendable {
    case agent
    case app
    case automation
    case hook
    case plugin
    case skill
    case system
    case user
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

public enum EventThreadRelation: String, Codable, CaseIterable, Sendable {
    case activeAtTime = "active_at_time"
    case source
    case target
    case triggeredBy = "triggered_by"
    case unrelated
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

public struct EventActor: Codable, Equatable, Sendable {
    public let type: EventActorType
    public let id: String
    public let label: String

    public init(type: EventActorType, id: String, label: String) {
        self.type = type
        self.id = id
        self.label = label
    }
}

public struct EventThread: Codable, Equatable, Sendable {
    public let id: String?
    public let title: String?
    public let relation: EventThreadRelation

    public init(id: String?, title: String?, relation: EventThreadRelation) {
        self.id = id
        self.title = title
        self.relation = relation
    }
}

public struct EventProject: Codable, Equatable, Sendable {
    public let name: String?
    public let path: String?

    public init(name: String? = nil, path: String? = nil) {
        self.name = name
        self.path = path
    }
}

public struct EventAccount: Codable, Equatable, Sendable {
    public let profile: String?
    public let label: String?

    public init(profile: String? = nil, label: String? = nil) {
        self.profile = profile
        self.label = label
    }
}

public enum EventScope: String, Codable, Equatable, Sendable {
    case account
    case device
    case globalWorkflow = "global_workflow"
    case project
    case thread
}

public struct EventChange: Codable, Equatable, Sendable {
    public let label: String
    public let summary: String
    public let before: String?
    public let after: String?

    public init(
        label: String,
        summary: String,
        before: String? = nil,
        after: String? = nil
    ) {
        self.label = label
        self.summary = summary
        self.before = before
        self.after = after
    }
}

public enum EventRelatedThreadRole: String, Codable, Equatable, Sendable {
    case deliveryTarget = "delivery_target"
    case modificationSource = "modification_source"
}

public struct EventRelatedThread: Codable, Equatable, Sendable {
    public let role: EventRelatedThreadRole
    public let id: String
    public let title: String?
    public let projectName: String?
    public let projectPath: String?

    public init(
        role: EventRelatedThreadRole,
        id: String,
        title: String? = nil,
        projectName: String? = nil,
        projectPath: String? = nil
    ) {
        self.role = role
        self.id = id
        self.title = title
        self.projectName = projectName
        self.projectPath = projectPath
    }
}

public struct EventEvidence: Codable, Equatable, Sendable {
    public let kind: String
    public let label: String
    public let path: String?

    public init(kind: String, label: String, path: String? = nil) {
        self.kind = kind
        self.label = label
        self.path = path
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case array([JSONValue])
    case bool(Bool)
    case null
    case number(Double)
    case object([String: JSONValue])
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .array(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .number(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

public struct OperationEvent: Codable, Identifiable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let occurredAt: Date
    public let recordedAt: Date
    public let category: EventCategory
    public let action: String
    public let title: String
    public let summary: String
    public let status: EventStatus
    public let importance: EventImportance
    public let certainty: EventCertainty
    public let actor: EventActor
    public let thread: EventThread?
    public let project: EventProject?
    public let account: EventAccount?
    public let scope: EventScope?
    public let changes: [EventChange]?
    public let relatedThreads: [EventRelatedThread]?
    public let sourceChain: [EventActor]
    public let before: JSONValue?
    public let after: JSONValue?
    public let evidence: [EventEvidence]

    public init(
        schemaVersion: Int,
        id: String,
        occurredAt: Date,
        recordedAt: Date,
        category: EventCategory,
        action: String,
        title: String,
        summary: String,
        status: EventStatus,
        importance: EventImportance,
        certainty: EventCertainty,
        actor: EventActor,
        thread: EventThread? = nil,
        project: EventProject? = nil,
        account: EventAccount? = nil,
        scope: EventScope? = nil,
        changes: [EventChange]? = nil,
        relatedThreads: [EventRelatedThread]? = nil,
        sourceChain: [EventActor] = [],
        before: JSONValue? = nil,
        after: JSONValue? = nil,
        evidence: [EventEvidence] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.category = category
        self.action = action
        self.title = title
        self.summary = summary
        self.status = status
        self.importance = importance
        self.certainty = certainty
        self.actor = actor
        self.thread = thread
        self.project = project
        self.account = account
        self.scope = scope
        self.changes = changes
        self.relatedThreads = relatedThreads
        self.sourceChain = sourceChain
        self.before = before
        self.after = after
        self.evidence = evidence
    }
}
