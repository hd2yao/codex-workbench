import Foundation

public struct AutomationUpdateEvidence: Equatable, Sendable {
    public let sourceThread: CodexThreadMetadata
    public let targetThreadID: String?
    public let previousSnapshot: WorkflowSemanticSnapshot?
    public let currentSnapshot: WorkflowSemanticSnapshot
    public let directChanges: [EventChange]
    public let evidencePath: String

    public init(
        sourceThread: CodexThreadMetadata,
        targetThreadID: String?,
        previousSnapshot: WorkflowSemanticSnapshot?,
        currentSnapshot: WorkflowSemanticSnapshot,
        directChanges: [EventChange] = [],
        evidencePath: String
    ) {
        self.sourceThread = sourceThread
        self.targetThreadID = targetThreadID
        self.previousSnapshot = previousSnapshot
        self.currentSnapshot = currentSnapshot
        self.directChanges = directChanges
        self.evidencePath = evidencePath
    }
}

public struct AutomationSessionEvidenceCollector: Sendable {
    public let correlationWindow: TimeInterval

    public init(correlationWindow: TimeInterval = 3) {
        self.correlationWindow = correlationWindow
    }

    public func evidence(
        automationID: String,
        occurredAt: Date,
        catalog: CodexMetadataCatalog,
        rolloutCache: WorkflowRolloutTextCache = WorkflowRolloutTextCache()
    ) -> [AutomationUpdateEvidence] {
        catalog.records.compactMap { thread in
            guard
                thread.createdAt <= occurredAt.addingTimeInterval(correlationWindow),
                thread.updatedAt >= occurredAt.addingTimeInterval(-60),
                thread.updatedAt <= occurredAt.addingTimeInterval(86_400),
                let rolloutPath = thread.rolloutPath
            else {
                return nil
            }
            return evidence(
                automationID: automationID,
                occurredAt: occurredAt,
                thread: thread,
                rolloutURL: URL(fileURLWithPath: rolloutPath),
                rolloutCache: rolloutCache
            )
        }
    }

    private func evidence(
        automationID: String,
        occurredAt: Date,
        thread: CodexThreadMetadata,
        rolloutURL: URL,
        rolloutCache: WorkflowRolloutTextCache
    ) -> AutomationUpdateEvidence? {
        guard let text = rolloutCache.text(at: rolloutURL.path) else { return nil }
        var previousSnapshot: WorkflowSemanticSnapshot?
        var matches: [(Date, String, WorkflowSemanticSnapshot?)] = []

        for rawLine in text.split(separator: "\n") {
            guard
                let data = String(rawLine).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let timestampText = object["timestamp"] as? String,
                let timestamp = Self.date(from: timestampText),
                let payload = object["payload"] as? [String: Any],
                let payloadType = payload["type"] as? String
            else {
                continue
            }

            if payloadType == "custom_tool_call_output", timestamp <= occurredAt {
                for candidate in Self.strings(in: payload["output"]) where
                    candidate.contains("id = \"\(automationID)\"") && candidate.contains("prompt =")
                {
                    previousSnapshot = WorkflowSemanticSnapshot.automation(content: candidate)
                }
                continue
            }

            guard
                payloadType == "custom_tool_call",
                abs(timestamp.timeIntervalSince(occurredAt)) <= correlationWindow,
                let input = payload["input"] as? String,
                input.contains("codex_app__automation_update"),
                Self.matchesAutomationID(automationID, in: input),
                Self.quotedValue(for: "mode", in: input) == "update"
            else {
                continue
            }
            matches.append((timestamp, input, previousSnapshot))
        }

        guard matches.count == 1, let match = matches.first else { return nil }
        let input = match.1
        let previous = match.2
        let prompt = Self.templateLiteral(named: "prompt", in: input)
            ?? Self.quotedValue(for: "prompt", in: input)
        let targetThreadID = Self.quotedValue(for: "targetThreadId", in: input)
            ?? previous?.targetThreadID
        let snapshot = WorkflowSemanticSnapshot(
            name: Self.quotedValue(for: "name", in: input) ?? previous?.name,
            status: Self.quotedValue(for: "status", in: input) ?? previous?.status,
            schedule: Self.quotedValue(for: "rrule", in: input) ?? previous?.schedule,
            targetThreadID: targetThreadID,
            capabilities: prompt.map(AutomationCapabilityClassifier.labels(in:))
                ?? previous?.capabilities
                ?? []
        )
        return AutomationUpdateEvidence(
            sourceThread: thread,
            targetThreadID: targetThreadID,
            previousSnapshot: previous,
            currentSnapshot: snapshot,
            directChanges: AutomationUpdateChangeAnalyzer.changes(in: input),
            evidencePath: rolloutURL.path
        )
    }

    private static func matchesAutomationID(_ automationID: String, in input: String) -> Bool {
        if quotedValue(for: "id", in: input) == automationID {
            return true
        }
        let escapedID = NSRegularExpression.escapedPattern(for: automationID)
        let hasConfigReference = input.range(
            of: #"\bid\s*:\s*cfg\.id\b"#,
            options: .regularExpression
        ) != nil
        let hasExactConfigPath = input.range(
            of: #"\.codex/automations/"# + escapedID + #"/automation\.toml"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        return hasConfigReference && hasExactConfigPath
    }

    private static func strings(in value: Any?) -> [String] {
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.flatMap(strings(in:)) }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.flatMap(strings(in:))
        }
        return []
    }

    private static func quotedValue(for key: String, in text: String) -> String? {
        guard let rawValue = capture(
            pattern: #"\b"#
                + NSRegularExpression.escapedPattern(for: key)
                + #"\s*:\s*"((?:\\.|[^"\\])*)""#,
            in: text
        ) else {
            return nil
        }
        let encodedLiteral = "\"\(rawValue)\""
        guard let data = encodedLiteral.data(using: .utf8) else { return rawValue }
        return (try? JSONDecoder().decode(String.self, from: data)) ?? rawValue
    }

    private static func templateLiteral(named name: String, in text: String) -> String? {
        capture(
            pattern: #"\b(?:const|let|var)\s+"#
                + NSRegularExpression.escapedPattern(for: name)
                + #"\s*=\s*`([\s\S]*?)`;"#,
            in: text
        )
    }

    private static func capture(pattern: String, in text: String) -> String? {
        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[range])
    }

    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ?? standard.date(from: value)
    }
}

enum AutomationUpdateChangeAnalyzer {
    static func changes(in input: String) -> [EventChange] {
        guard let replacement = replacementOperands(in: input) else { return [] }
        let before = replacement.before
        let after = replacement.after
        var result: [EventChange] = []

        if let oldLimit = listThreadsLimit(in: before),
           let newLimit = listThreadsLimit(in: after),
           oldLimit != newLimit {
            result.append(EventChange(
                label: "任务扫描范围",
                summary: "对话候选扫描上限由 \(oldLimit) 调整为 \(newLimit)",
                before: oldLimit,
                after: newLimit
            ))
        }

        if isActivityCleanupMovedAfterRead(before: before, after: after) {
            result.append(EventChange(
                label: "活动记录重建顺序",
                summary: "改为先完成候选任务读取，再清空并重建活动记录；读取失败时保留现有记录"
            ))
        }

        let oldCapabilities = Set(AutomationCapabilityClassifier.labels(in: before))
        let newCapabilities = Set(AutomationCapabilityClassifier.labels(in: after))
        for capability in newCapabilities.subtracting(oldCapabilities).sorted() {
            result.append(EventChange(label: "新增能力", summary: capability, after: capability))
        }
        for capability in oldCapabilities.subtracting(newCapabilities).sorted() {
            result.append(EventChange(label: "移除能力", summary: capability, before: capability))
        }
        if result.isEmpty {
            result.append(EventChange(
                label: "指令段落",
                summary: "Automation 的一段执行指令已替换；未识别到可安全概括的结构变化"
            ))
        }
        return result
    }

    private static func replacementOperands(in input: String) -> (before: String, after: String)? {
        if let values = captures(
            pattern: #"\.replace\(\s*\"((?:\\.|[^\"\\])*)\"\s*,\s*\"((?:\\.|[^\"\\])*)\"\s*\)"#,
            in: input,
            groups: 2
        ) {
            return (decodeJSONString(values[0]), decodeJSONString(values[1]))
        }
        guard let names = captures(
            pattern: #"\.replace\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)"#,
            in: input,
            groups: 2
        ) else {
            return nil
        }
        let literals = namedLiterals(in: input)
        guard let before = literals[names[0]], let after = literals[names[1]] else { return nil }
        return (before, after)
    }

    private static func namedLiterals(in input: String) -> [String: String] {
        var result: [String: String] = [:]
        if let expression = try? NSRegularExpression(
            pattern: #"\b(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*`([\s\S]*?)`;"#
        ) {
            for match in expression.matches(in: input, range: NSRange(input.startIndex..., in: input)) {
                guard
                    let nameRange = Range(match.range(at: 1), in: input),
                    let valueRange = Range(match.range(at: 2), in: input)
                else { continue }
                result[String(input[nameRange])] = String(input[valueRange])
            }
        }
        return result
    }

    private static func listThreadsLimit(in value: String) -> String? {
        captures(
            pattern: #"list_threads\s*\(\s*limit\s*=\s*(\d+)\s*\)"#,
            in: value,
            groups: 1
        )?.first
    }

    private static func isActivityCleanupMovedAfterRead(before: String, after: String) -> Bool {
        guard
            let oldClear = before.range(of: "clear-activity")?.lowerBound,
            let oldRead = before.range(of: "list_threads")?.lowerBound,
            let newClear = after.range(of: "clear-activity")?.lowerBound,
            let newRead = after.range(of: "list_threads")?.lowerBound
        else {
            return false
        }
        return oldClear < oldRead
            && newRead < newClear
            && after.contains("读取失败时保留")
    }

    private static func captures(
        pattern: String,
        in text: String,
        groups: Int
    ) -> [String]? {
        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else {
            return nil
        }
        var result: [String] = []
        for index in 1...groups {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            result.append(String(text[range]))
        }
        return result
    }

    private static func decodeJSONString(_ value: String) -> String {
        let literal = "\"\(value)\""
        guard let data = literal.data(using: .utf8) else { return value }
        return (try? JSONDecoder().decode(String.self, from: data)) ?? value
    }
}

public struct WorkflowEventHistoryEnricher: Sendable {
    public init() {}

    public func revisions(
        events: [OperationEvent],
        catalog: CodexMetadataCatalog,
        currentWorkflowFiles: [WorkflowFileFingerprint] = [],
        workflowSourceRoots: [URL] = WorkflowGitHistoryEvidenceCollector.standardSourceRoots,
        recordedAt: Date
    ) -> [OperationEvent] {
        let currentByPath = Dictionary(uniqueKeysWithValues: currentWorkflowFiles.map { ($0.path, $0) })
        let rolloutCache = WorkflowRolloutTextCache()
        return events.compactMap { event in
            if let revision = automationRevision(
                event: event,
                catalog: catalog,
                rolloutCache: rolloutCache,
                recordedAt: recordedAt
            ) {
                return revision
            }
            if let revision = patchRevision(
                event: event,
                catalog: catalog,
                rolloutCache: rolloutCache,
                recordedAt: recordedAt
            ) {
                return revision
            }
            if let revision = gitHistoryRevision(
                event: event,
                sourceRoots: workflowSourceRoots,
                recordedAt: recordedAt
            ) {
                return revision
            }
            return currentSnapshotRevision(
                event: event,
                currentByPath: currentByPath,
                recordedAt: recordedAt
            )
        }
    }

    private func patchRevision(
        event: OperationEvent,
        catalog: CodexMetadataCatalog,
        rolloutCache: WorkflowRolloutTextCache,
        recordedAt: Date
    ) -> OperationEvent? {
        guard
            needsCurrentSnapshotExplanation(event),
            let rawPath = event.evidence.first(where: { $0.kind == "file_fingerprint" })?.path,
            let kind = workflowKind(for: event)
        else {
            return nil
        }
        let matches = WorkflowSessionPatchEvidenceCollector().evidence(
            kind: kind,
            label: event.actor.label,
            path: rawPath,
            occurredAt: event.occurredAt,
            catalog: catalog,
            rolloutCache: rolloutCache
        )
        guard matches.count == 1, let match = matches.first, !match.changes.isEmpty else { return nil }

        let source = match.sourceThread
        var relatedThreads = event.relatedThreads ?? []
        if !relatedThreads.contains(where: { $0.role == .modificationSource && $0.id == source.id }) {
            relatedThreads.insert(EventRelatedThread(
                role: .modificationSource,
                id: source.id,
                title: source.title,
                projectName: source.projectName,
                projectPath: source.projectPath
            ), at: 0)
        }
        var sourceChain = event.sourceChain
        if !sourceChain.contains(where: { $0.id == "structured-workflow-patch" }) {
            sourceChain.append(EventActor(
                type: .system,
                id: "structured-workflow-patch",
                label: "工作流结构化修改"
            ))
        }
        var evidence = event.evidence.filter { $0.kind != "current_workflow_snapshot" }
        if !evidence.contains(where: {
            $0.kind == "structured_workflow_patch" && $0.path == match.evidencePath
        }) {
            evidence.append(EventEvidence(
                kind: "structured_workflow_patch",
                label: "结构化工作流修改调用",
                path: match.evidencePath
            ))
        }
        let revision = OperationEvent(
            schemaVersion: event.schemaVersion,
            id: event.id,
            occurredAt: event.occurredAt,
            recordedAt: recordedAt,
            category: event.category,
            action: event.action,
            title: event.title,
            summary: listSummary(label: event.actor.label, changes: match.changes),
            status: event.status,
            importance: event.importance,
            certainty: .confirmed,
            actor: event.actor,
            thread: EventThread(id: source.id, title: source.title, relation: .triggeredBy),
            project: EventProject(name: source.projectName, path: source.projectPath),
            account: event.account,
            scope: event.scope ?? .globalWorkflow,
            changes: match.changes,
            relatedThreads: relatedThreads,
            sourceChain: sourceChain,
            before: event.before,
            after: event.after,
            evidence: evidence
        )
        return isSemanticallyEquivalent(revision, to: event) ? nil : revision
    }

    private func gitHistoryRevision(
        event: OperationEvent,
        sourceRoots: [URL],
        recordedAt: Date
    ) -> OperationEvent? {
        guard
            needsCurrentSnapshotExplanation(event),
            let rawPath = event.evidence.first(where: { $0.kind == "file_fingerprint" })?.path,
            let afterFingerprint = fingerprint(in: event.after),
            let kind = workflowKind(for: event)
        else {
            return nil
        }
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let label = event.actor.label
        guard let history = WorkflowGitHistoryEvidenceCollector().evidence(
            kind: kind,
            label: label,
            afterFingerprint: afterFingerprint,
            sourceRoots: sourceRoots
        ) else {
            return nil
        }
        let current = WorkflowFileFingerprint(
            path: path,
            kind: kind,
            label: label,
            modifiedAt: event.occurredAt,
            fingerprint: afterFingerprint,
            semanticSnapshot: history.currentSnapshot
        )
        let previous: [String: WorkflowFileFingerprint]
        if event.action.hasSuffix("_added") {
            previous = [:]
        } else {
            let old = WorkflowFileFingerprint(
                path: path,
                kind: kind,
                label: label,
                modifiedAt: event.occurredAt,
                fingerprint: fingerprint(in: event.before) ?? "legacy-before",
                semanticSnapshot: history.previousSnapshot
            )
            previous = [path: old]
        }
        guard let semantic = WorkflowChangeEventFactory().events(
            previous: previous,
            current: [current],
            observedAt: recordedAt
        ).first else {
            return nil
        }
        var evidence = event.evidence.filter { $0.kind != "current_workflow_snapshot" }
        if !evidence.contains(where: { $0.kind == "git_workflow_history" }) {
            evidence.append(EventEvidence(
                kind: "git_workflow_history",
                label: "Git 前后版本 · \(history.commit)",
                path: history.sourcePath
            ))
        }
        let revision = OperationEvent(
            schemaVersion: event.schemaVersion,
            id: event.id,
            occurredAt: event.occurredAt,
            recordedAt: recordedAt,
            category: event.category,
            action: event.action,
            title: event.title,
            summary: semantic.summary,
            status: event.status,
            importance: event.importance,
            certainty: .confirmed,
            actor: event.actor,
            thread: event.thread,
            project: event.project,
            account: event.account,
            scope: event.scope ?? .globalWorkflow,
            changes: semantic.changes,
            relatedThreads: event.relatedThreads,
            sourceChain: event.sourceChain,
            before: event.before,
            after: event.after,
            evidence: evidence
        )
        return isSemanticallyEquivalent(revision, to: event) ? nil : revision
    }

    private func automationRevision(
        event: OperationEvent,
        catalog: CodexMetadataCatalog,
        rolloutCache: WorkflowRolloutTextCache,
        recordedAt: Date
    ) -> OperationEvent? {
        guard
            event.action == "automation_updated",
            let automationID = automationID(from: event),
            let path = event.evidence.first(where: { $0.kind == "file_fingerprint" })?.path
        else {
            return nil
        }
            let matches = AutomationSessionEvidenceCollector().evidence(
                automationID: automationID,
                occurredAt: event.occurredAt,
                catalog: catalog,
                rolloutCache: rolloutCache
            )
            guard matches.count == 1, let match = matches.first else { return nil }

            let oldFingerprint = fingerprint(in: event.before) ?? "legacy-before"
            let newFingerprint = fingerprint(in: event.after) ?? "legacy-after"
            let old = WorkflowFileFingerprint(
                path: path,
                kind: .automation,
                label: automationID,
                modifiedAt: event.occurredAt,
                fingerprint: oldFingerprint,
                semanticSnapshot: match.previousSnapshot
            )
            let current = WorkflowFileFingerprint(
                path: path,
                kind: .automation,
                label: automationID,
                modifiedAt: event.occurredAt,
                fingerprint: newFingerprint,
                semanticSnapshot: match.currentSnapshot
            )
            guard let semantic = WorkflowChangeEventFactory().events(
                previous: [path: old],
                current: [current],
                observedAt: recordedAt
            ).first else {
                return nil
            }
            let changes = match.directChanges.isEmpty ? (semantic.changes ?? []) : match.directChanges
            let summary = listSummary(label: automationID, changes: changes)

            let source = match.sourceThread
            var related = [EventRelatedThread(
                role: .modificationSource,
                id: source.id,
                title: source.title,
                projectName: source.projectName,
                projectPath: source.projectPath
            )]
            if let targetID = match.targetThreadID {
                let target = catalog.thread(id: targetID)
                related.append(EventRelatedThread(
                    role: .deliveryTarget,
                    id: targetID,
                    title: target?.title,
                    projectName: target?.projectName,
                    projectPath: target?.projectPath
                ))
            }
            var sourceChain = event.sourceChain
            if !sourceChain.contains(where: { $0.id == "structured-automation-update" }) {
                sourceChain.append(EventActor(
                    type: .system,
                    id: "structured-automation-update",
                    label: "Automation 更新调用"
                ))
            }
            var evidence = event.evidence
            if !evidence.contains(where: {
                $0.kind == "structured_automation_update" && $0.path == match.evidencePath
            }) {
                evidence.append(EventEvidence(
                    kind: "structured_automation_update",
                    label: "结构化 Automation 更新调用",
                    path: match.evidencePath
                ))
            }
            let revision = OperationEvent(
                schemaVersion: event.schemaVersion,
                id: event.id,
                occurredAt: event.occurredAt,
                recordedAt: recordedAt,
                category: event.category,
                action: event.action,
                title: event.title,
                summary: summary,
                status: event.status,
                importance: event.importance,
                certainty: .confirmed,
                actor: event.actor,
                thread: EventThread(id: source.id, title: source.title, relation: .triggeredBy),
                project: EventProject(name: source.projectName, path: source.projectPath),
                account: event.account,
                scope: .globalWorkflow,
                changes: changes,
                relatedThreads: related,
                sourceChain: sourceChain,
                before: event.before,
                after: event.after,
                evidence: evidence
            )
            guard !hasGenericExplanation(revision) else { return nil }
            return isSemanticallyEquivalent(revision, to: event) ? nil : revision
        }

    private func currentSnapshotRevision(
        event: OperationEvent,
        currentByPath: [String: WorkflowFileFingerprint],
        recordedAt: Date
    ) -> OperationEvent? {
        guard
            needsCurrentSnapshotExplanation(event),
            let rawPath = event.evidence.first(where: { $0.kind == "file_fingerprint" })?.path
        else {
            return nil
        }
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        guard let current = currentByPath[path], current.semanticSnapshot != nil else { return nil }
        let previous: [String: WorkflowFileFingerprint]
        if event.action.hasSuffix("_added") {
            previous = [:]
        } else {
            let old = WorkflowFileFingerprint(
                path: path,
                kind: current.kind,
                label: current.label,
                modifiedAt: event.occurredAt,
                fingerprint: fingerprint(in: event.before) ?? "legacy-before",
                semanticSnapshot: nil
            )
            previous = [path: old]
        }
        guard let semantic = WorkflowChangeEventFactory().events(
            previous: previous,
            current: [current],
            observedAt: recordedAt
        ).first else {
            return nil
        }
        var evidence = event.evidence
        if !evidence.contains(where: { $0.kind == "current_workflow_snapshot" && $0.path == path }) {
            evidence.append(EventEvidence(
                kind: "current_workflow_snapshot",
                label: "当前工作流安全语义快照",
                path: path
            ))
        }
        let revision = OperationEvent(
            schemaVersion: event.schemaVersion,
            id: event.id,
            occurredAt: event.occurredAt,
            recordedAt: recordedAt,
            category: event.category,
            action: event.action,
            title: event.title,
            summary: semantic.summary,
            status: event.status,
            importance: event.importance,
            certainty: event.certainty,
            actor: event.actor,
            thread: event.thread,
            project: event.project,
            account: event.account,
            scope: event.scope ?? .globalWorkflow,
            changes: semantic.changes,
            relatedThreads: event.relatedThreads,
            sourceChain: event.sourceChain,
            before: event.before,
            after: event.after,
            evidence: evidence
        )
        return isSemanticallyEquivalent(revision, to: event) ? nil : revision
    }

    private func needsCurrentSnapshotExplanation(_ event: OperationEvent) -> Bool {
        let supported = [
            "automation_added", "automation_updated",
            "workflow_config_added", "workflow_config_updated",
            "workflow_rule_added", "workflow_rule_updated",
            "hook_added", "hook_updated",
            "plugin_added", "plugin_updated",
            "skill_added", "skill_updated",
        ].contains(event.action)
        guard supported else { return false }
        if workflowKind(for: event) == .rule,
           event.changes?.contains(where: { ["新增规则", "移除规则"].contains($0.label) }) != true {
            return true
        }
        return event.changes?.isEmpty != false
            || event.summary.contains("全局工作流定义已更新")
            || event.summary.contains("内容已调整")
            || event.summary.contains("实现内容已调整")
            || event.changes?.contains {
                ["工作流定义", "实现细节", "指令段落", "证据边界"].contains($0.label)
            } == true
            || event.evidence.contains { $0.kind == "current_workflow_snapshot" }
    }

    private func hasGenericExplanation(_ event: OperationEvent) -> Bool {
        event.summary.contains("全局工作流定义已更新")
            || event.summary.contains("内容已调整")
            || event.summary.contains("实现内容已调整")
            || event.changes?.contains {
                ["工作流定义", "实现细节"].contains($0.label)
            } == true
    }

    private func workflowKind(for event: OperationEvent) -> WorkflowFileKind? {
        if event.action.hasPrefix("workflow_rule_") { return .rule }
        if event.action.hasPrefix("workflow_config_") { return .configuration }
        if event.action.hasPrefix("plugin_") { return .plugin }
        if event.action.hasPrefix("skill_") { return .skill }
        if event.action.hasPrefix("hook_") { return .hook }
        if event.action.hasPrefix("automation_") { return .automation }
        switch event.category {
        case .skill:
            return .skill
        case .hook:
            return .hook
        case .automation:
            return .automation
        default:
            return nil
        }
    }

    private func listSummary(label: String, changes: [EventChange]) -> String {
        let readable = changes.prefix(3).map(\.summary).joined(separator: "；")
        return readable.isEmpty ? "\(label) 的全局工作流定义已更新。" : "\(label)：\(readable)。"
    }

    private func isSemanticallyEquivalent(_ lhs: OperationEvent, to rhs: OperationEvent) -> Bool {
        lhs.summary == rhs.summary
            && lhs.certainty == rhs.certainty
            && lhs.thread == rhs.thread
            && lhs.project == rhs.project
            && lhs.scope == rhs.scope
            && lhs.changes == rhs.changes
            && lhs.relatedThreads == rhs.relatedThreads
            && lhs.sourceChain == rhs.sourceChain
            && lhs.evidence == rhs.evidence
    }

    private func automationID(from event: OperationEvent) -> String? {
        if !event.actor.label.isEmpty { return event.actor.label }
        return event.evidence.first?.path.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent
        }
    }

    private func fingerprint(in value: JSONValue?) -> String? {
        guard case .object(let object) = value, case .string(let fingerprint) = object["fingerprint"] else {
            return nil
        }
        return fingerprint
    }
}
