import Foundation

public struct ObservationState: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let updatedAt: Date
    public let projectPaths: Set<String>
    public let threadIDs: Set<String>
    public let workflowFiles: [String: WorkflowFileFingerprint]
    public let quotaByProfile: [String: QuotaObservation]
    public let accountErrorFingerprint: String?

    public init(
        schemaVersion: Int = 1,
        updatedAt: Date,
        projectPaths: Set<String>,
        threadIDs: Set<String>,
        workflowFiles: [String: WorkflowFileFingerprint],
        quotaByProfile: [String: QuotaObservation],
        accountErrorFingerprint: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.projectPaths = projectPaths
        self.threadIDs = threadIDs
        self.workflowFiles = workflowFiles
        self.quotaByProfile = quotaByProfile
        self.accountErrorFingerprint = accountErrorFingerprint
    }
}

public struct ObservationStateStore: Sendable {
    public init() {}

    public func load(from fileURL: URL) -> ObservationState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? LedgerRepository.decoder().decode(ObservationState.self, from: data)
    }

    @discardableResult
    public func save(_ state: ObservationState, to fileURL: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = LedgerWriter.encoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(state).write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}

public struct ObservationReconciliation: Equatable, Sendable {
    public let events: [OperationEvent]
    public let state: ObservationState

    public init(events: [OperationEvent], state: ObservationState) {
        self.events = events
        self.state = state
    }
}

public struct ObservationStateReconciler: Sendable {
    public init() {}

    public func reconcile(
        previous: ObservationState?,
        evidence: EvidenceSnapshot,
        accountPayload: AccountDashboardPayload?,
        accountError: String? = nil,
        existingEvents: [OperationEvent],
        observedAt: Date
    ) -> ObservationReconciliation {
        var events: [OperationEvent] = []

        events += ProjectSpaceEventFactory().events(
            previousProjectPaths: previous?.projectPaths,
            current: evidence.threadCatalog,
            observedAt: observedAt
        )
        events += ThreadContinuationEventFactory().events(
            previousThreadIDs: previous?.threadIDs,
            current: evidence.threadCatalog,
            observedAt: observedAt
        )
        events += WorkflowChangeEventFactory().events(
            previous: previous?.workflowFiles,
            current: evidence.workflowFiles,
            observedAt: observedAt
        )

        var quotaByProfile = previous?.quotaByProfile ?? [:]
        if let accountPayload {
            for observation in Self.quotaObservations(from: accountPayload) {
                if let old = quotaByProfile[observation.profile] {
                    events += QuotaEventFactory().events(
                        previous: old,
                        current: observation,
                        localResetEvents: existingEvents
                    )
                }
                quotaByProfile[observation.profile] = observation
            }
        }

        let currentErrorFingerprint = accountError.map {
            StableEventID.make(parts: ["account-data-source-error", $0])
        }
        if let previous {
            events += Self.accountDataSourceEvents(
                previousFingerprint: previous.accountErrorFingerprint,
                currentFingerprint: currentErrorFingerprint,
                hasCurrentPayload: accountPayload != nil,
                observedAt: observedAt
            )
        }

        let nextErrorFingerprint: String?
        if accountPayload != nil {
            nextErrorFingerprint = nil
        } else if currentErrorFingerprint != nil {
            nextErrorFingerprint = currentErrorFingerprint
        } else {
            nextErrorFingerprint = previous?.accountErrorFingerprint
        }

        let hasThreadSnapshot = !evidence.threadCatalog.records.isEmpty
        let hasWorkflowSnapshot = !evidence.workflowFiles.isEmpty
        let state = ObservationState(
            updatedAt: observedAt,
            projectPaths: hasThreadSnapshot
                ? evidence.threadCatalog.projectPaths
                : (previous?.projectPaths ?? []),
            threadIDs: hasThreadSnapshot
                ? evidence.threadCatalog.threadIDs
                : (previous?.threadIDs ?? []),
            workflowFiles: hasWorkflowSnapshot
                ? Dictionary(uniqueKeysWithValues: evidence.workflowFiles.map { ($0.path, $0) })
                : (previous?.workflowFiles ?? [:]),
            quotaByProfile: quotaByProfile,
            accountErrorFingerprint: nextErrorFingerprint
        )
        return ObservationReconciliation(
            events: events.sorted { $0.occurredAt > $1.occurredAt },
            state: state
        )
    }

    public static func quotaObservations(
        from payload: AccountDashboardPayload
    ) -> [QuotaObservation] {
        payload.profiles.compactMap { profile in
            let remaining = profile.rateLimits.primary?.remainingPercent
            let resetsAt = profile.rateLimits.primary?.resetsAtDate
            let resetCredits = profile.resetCreditDetails?.availableCount
                ?? profile.rateLimits.resetCredits?.availableCount
            let reachedType = profile.rateLimits.reachedType
            guard
                remaining != nil
                    || resetsAt != nil
                    || resetCredits != nil
                    || reachedType != nil
            else {
                return nil
            }
            return QuotaObservation(
                profile: profile.name,
                observedAt: payload.generatedAt,
                remainingPercent: remaining,
                resetsAt: resetsAt,
                resetCredits: resetCredits,
                reachedType: reachedType
            )
        }
    }

    private static func accountDataSourceEvents(
        previousFingerprint: String?,
        currentFingerprint: String?,
        hasCurrentPayload: Bool,
        observedAt: Date
    ) -> [OperationEvent] {
        let action: String
        let title: String
        let summary: String
        let status: EventStatus
        if let currentFingerprint, currentFingerprint != previousFingerprint {
            action = "account_data_source_failed"
            title = "账号数据源读取失败"
            summary = "Codex 工作台未能读取账号状态；已保留上一次成功数据。"
            status = .failure
        } else if previousFingerprint != nil, currentFingerprint == nil, hasCurrentPayload {
            action = "account_data_source_recovered"
            title = "账号数据源已恢复"
            summary = "Codex 工作台已重新读取账号与额度状态。"
            status = .success
        } else {
            return []
        }

        return [OperationEvent(
            schemaVersion: 1,
            id: StableEventID.make(parts: [
                "account-data-source",
                action,
                String(format: "%.6f", observedAt.timeIntervalSince1970),
            ]),
            occurredAt: observedAt,
            recordedAt: observedAt,
            category: .system,
            action: action,
            title: title,
            summary: summary,
            status: status,
            importance: .important,
            certainty: .confirmed,
            actor: EventActor(type: .app, id: "codex-observatory", label: "Codex 工作台"),
            sourceChain: [
                EventActor(type: .app, id: "account-gateway", label: "账号数据适配器"),
            ],
            before: .object(["source_state": .string(previousFingerprint == nil ? "healthy" : "failed")]),
            after: .object(["source_state": .string(status == .failure ? "failed" : "healthy")]),
            evidence: [
                EventEvidence(kind: "data_source_transition", label: "脱敏的数据源状态变化"),
            ]
        )]
    }
}
