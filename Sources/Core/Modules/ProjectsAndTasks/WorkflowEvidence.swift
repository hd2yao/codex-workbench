import Foundation

public enum WorkflowFileKind: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case rule
    case skill
    case hook
    case automation
    case plugin
    case configuration

    public var title: String {
        switch self {
        case .rule: "规则"
        case .skill: "Skills"
        case .hook: "Hooks"
        case .automation: "自动化"
        case .plugin, .configuration: "扩展"
        }
    }
}

public struct WorkflowFileDescriptor: Equatable, Sendable {
    public let kind: WorkflowFileKind
    public let label: String

    public init(kind: WorkflowFileKind, label: String) {
        self.kind = kind
        self.label = label
    }
}

public enum WorkflowFileClassifier {
    public static func classify(path: String) -> WorkflowFileDescriptor? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let lowercased = standardized.lowercased()
        let url = URL(fileURLWithPath: standardized)
        let name = url.lastPathComponent

        guard
            !lowercased.contains("/__pycache__/"),
            !lowercased.hasSuffix(".pyc"),
            !lowercased.contains("/operation-ledger/"),
            !lowercased.contains("/auth.json"),
            !lowercased.contains("token"),
            !lowercased.contains("secret"),
            !lowercased.contains("cookie"),
            !lowercased.contains(".bak")
        else {
            return nil
        }

        if name == "AGENTS.md" {
            return WorkflowFileDescriptor(kind: .rule, label: "Codex 全局规则")
        }
        if (lowercased.contains("/skills/")
            || lowercased.contains("/codex-workflow-skills/")),
           name == "SKILL.md" {
            return WorkflowFileDescriptor(kind: .skill, label: url.deletingLastPathComponent().lastPathComponent)
        }
        if lowercased.contains("/hooks/"), url.pathExtension == "py" || name == "hooks.json" {
            return WorkflowFileDescriptor(kind: .hook, label: url.deletingPathExtension().lastPathComponent)
        }
        if lowercased.contains("/automations/"), name == "automation.toml" {
            return WorkflowFileDescriptor(kind: .automation, label: url.deletingLastPathComponent().lastPathComponent)
        }
        if lowercased.contains("/plugins/"),
           ["json", "toml", "yaml", "yml"].contains(url.pathExtension.lowercased()) {
            return WorkflowFileDescriptor(kind: .plugin, label: url.deletingPathExtension().lastPathComponent)
        }
        if name == "config.toml" || name == "hooks.json" {
            return WorkflowFileDescriptor(kind: .configuration, label: name)
        }
        return nil
    }
}

public struct WorkflowFileFingerprint: Codable, Equatable, Sendable {
    public let path: String
    public let kind: WorkflowFileKind
    public let label: String
    public let modifiedAt: Date
    public let fingerprint: String
    public let semanticSnapshot: WorkflowSemanticSnapshot?

    public init(
        path: String,
        kind: WorkflowFileKind,
        label: String,
        modifiedAt: Date,
        fingerprint: String,
        semanticSnapshot: WorkflowSemanticSnapshot? = nil
    ) {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.kind = kind
        self.label = label
        self.modifiedAt = modifiedAt
        self.fingerprint = fingerprint
        self.semanticSnapshot = semanticSnapshot
    }
}

public struct WorkflowSemanticSnapshot: Codable, Equatable, Sendable {
    public let name: String?
    public let status: String?
    public let schedule: String?
    public let targetThreadID: String?
    public let purpose: String?
    public let interfaces: [String]
    public let capabilities: [String]
    public let statements: [String]

    public init(
        name: String? = nil,
        status: String? = nil,
        schedule: String? = nil,
        targetThreadID: String? = nil,
        purpose: String? = nil,
        interfaces: [String] = [],
        capabilities: [String] = [],
        statements: [String] = []
    ) {
        self.name = name
        self.status = status
        self.schedule = schedule
        self.targetThreadID = targetThreadID
        self.purpose = purpose
        self.interfaces = Array(Set(interfaces)).sorted()
        self.capabilities = Array(Set(capabilities)).sorted()
        self.statements = Array(Set(statements)).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case status
        case schedule
        case targetThreadID
        case purpose
        case interfaces
        case capabilities
        case statements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name),
            status: try container.decodeIfPresent(String.self, forKey: .status),
            schedule: try container.decodeIfPresent(String.self, forKey: .schedule),
            targetThreadID: try container.decodeIfPresent(String.self, forKey: .targetThreadID),
            purpose: try container.decodeIfPresent(String.self, forKey: .purpose),
            interfaces: try container.decodeIfPresent([String].self, forKey: .interfaces) ?? [],
            capabilities: try container.decodeIfPresent([String].self, forKey: .capabilities) ?? [],
            statements: try container.decodeIfPresent([String].self, forKey: .statements) ?? []
        )
    }

    public static func automation(content: String) -> Self {
        let prompt = TOMLScalarReader.string(for: "prompt", in: content) ?? ""
        return Self(
            name: TOMLScalarReader.string(for: "name", in: content),
            status: TOMLScalarReader.string(for: "status", in: content),
            schedule: TOMLScalarReader.string(for: "rrule", in: content),
            targetThreadID: TOMLScalarReader.string(for: "target_thread_id", in: content),
            capabilities: AutomationCapabilityClassifier.labels(in: prompt)
        )
    }

    public static func skill(content: String) -> Self {
        Self(
            purpose: WorkflowTextSummaryReader.skillDescription(in: content),
            interfaces: WorkflowTextSummaryReader.skillSections(in: content),
            capabilities: AutomationCapabilityClassifier.labels(in: content)
        )
    }

    public static func hook(content: String) -> Self {
        Self(
            purpose: WorkflowTextSummaryReader.pythonModuleDocstring(in: content),
            capabilities: AutomationCapabilityClassifier.labels(in: content)
        )
    }

    public static func rule(content: String) -> Self {
        Self(
            interfaces: WorkflowTextSummaryReader.markdownSections(in: content),
            capabilities: AutomationCapabilityClassifier.labels(in: content),
            statements: WorkflowTextSummaryReader.markdownDirectives(in: content)
        )
    }

    public static func configuration(content: String) -> Self {
        Self(
            interfaces: SafeWorkflowManifestReader.tomlSections(in: content),
            statements: SafeWorkflowManifestReader.configurationStatements(in: content)
        )
    }

    public static func plugin(content: String) -> Self {
        let manifest = SafeWorkflowManifestReader.pluginManifest(in: content)
        return Self(
            name: manifest.name,
            purpose: manifest.description,
            capabilities: AutomationCapabilityClassifier.labels(in: content),
            statements: manifest.statements
        )
    }
}

enum AutomationCapabilityClassifier {
    private static let rules: [(label: String, markers: [String])] = [
        ("每日摘要生成", ["DailyDigest"]),
        ("前一日工作采集", ["clear-activity", "record-activity", "previous_day_activities"]),
        ("周期任务健康审计", ["recurring-task-audit", "recurring_task_audit", ".codex/continuity.json"]),
        ("任务台账管理", ["task-ledger.py"]),
        ("上下文压缩摘要", ["PreCompact", "pre_compact"]),
        ("动态仓库操作预算", ["repository-action-budget.py"]),
        ("已合并工作区清理", ["git worktree remove"]),
        ("未集成提交远端保护", ["codex/preserve/"]),
        ("PR 自动集成", ["gh pr merge"]),
        ("临时图片安全清理", ["临时截图", "codex-clipboard"]),
        ("运行指标记录", ["--duration-seconds", "--unsafe-actions"]),
        ("周一工作流复盘", ["retrospect_workflows.py"]),
        ("仓库收尾审计", ["repository-closure-audit.py"]),
        ("远端状态刷新", ["--refresh-remotes"]),
        ("提交等价性判定", ["patch_equivalent", "tree_equivalent", "patch-id"]),
        ("默认分支与上游分离判断", ["upstream_ahead", "default_ahead"]),
        ("等待条件与续作监控", ["track-follow-up", "track_follow_up", "follow_ups", "续作监控"]),
        ("安全并行轨道", ["parallel_action", "并行前端轨道", "安全并行"]),
        ("自动恢复动作", ["resume_action", "resume_mode", "自动续作"]),
    ]

    static func labels(in prompt: String) -> [String] {
        rules.compactMap { rule in
            rule.markers.contains { prompt.localizedCaseInsensitiveContains($0) }
                ? rule.label
                : nil
        }
    }
}

enum WorkflowTextSummaryReader {
    private static let genericSkillSections: Set<String> = [
        "何时使用", "核心原则", "使用方式", "安全约束", "资源", "输入", "输出",
    ]

    static func skillDescription(in content: String) -> String? {
        guard content.hasPrefix("---") else { return nil }
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "---" { break }
            guard line.hasPrefix("description:") else { continue }
            return normalized(String(line.dropFirst("description:".count)))
        }
        return nil
    }

    static func skillSections(in content: String) -> [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("## "), !line.hasPrefix("### ") else { return nil }
            let section = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            guard !section.isEmpty, !genericSkillSections.contains(section) else { return nil }
            return section
        }
    }

    static func markdownSections(in content: String) -> [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("## "), !line.hasPrefix("### ") else { return nil }
            return normalized(String(line.dropFirst(3)))
        }
    }

    static func markdownDirectives(in content: String) -> [String] {
        Array(content.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = String(rawLine)
            guard line.hasPrefix("- ") else { return nil }
            return SafeWorkflowText.normalized(String(line.dropFirst(2)), limit: 360)
        }.prefix(96))
    }

    static func pythonModuleDocstring(in content: String) -> String? {
        var candidate = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("#!"), let newline = candidate.firstIndex(of: "\n") {
            candidate = String(candidate[candidate.index(after: newline)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for delimiter in ["\"\"\"", "'''"] where candidate.hasPrefix(delimiter) {
            let start = candidate.index(candidate.startIndex, offsetBy: delimiter.count)
            guard let end = candidate.range(of: delimiter, range: start..<candidate.endIndex)?.lowerBound else {
                return nil
            }
            return normalized(String(candidate[start..<end]))
        }
        return nil
    }

    private static func normalized(_ value: String) -> String? {
        let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: " \\t\\r\\n\\\"'"))
        let compact = unquoted.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard !compact.isEmpty else { return nil }
        return compact.count <= 180 ? compact : String(compact.prefix(177)) + "…"
    }
}

enum SafeWorkflowText {
    static func normalized(_ value: String, limit: Int = 240) -> String? {
        let compact = value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard !compact.isEmpty, !containsSensitiveValue(compact) else { return nil }
        return compact.count <= limit ? compact : String(compact.prefix(max(0, limit - 1))) + "…"
    }

    static func containsSensitiveValue(_ value: String) -> Bool {
        let normalized = value.lowercased()
        if normalized.contains("bearer ") { return true }
        if normalized.range(
            of: #"(?:^|[^a-z0-9])sk-[a-z0-9_-]{12,}"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        let sensitiveKeys = ["api_key", "apikey", "token", "password", "secret", "cookie"]
        return sensitiveKeys.contains { key in
            normalized.range(
                of: #"\b"# + NSRegularExpression.escapedPattern(for: key) + #"\s*[:=]\s*[^\s]+"#,
                options: .regularExpression
            ) != nil
        }
    }
}

enum SafeWorkflowManifestReader {
    struct PluginManifest {
        let name: String?
        let description: String?
        let statements: [String]
    }

    static func tomlSections(in content: String) -> [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("["), line.hasSuffix("]"), !line.hasPrefix("[[") else { return nil }
            return SafeWorkflowText.normalized(String(line.dropFirst().dropLast()), limit: 120)
        }
    }

    static func tomlStatements(in content: String) -> [String] {
        var section: String?
        var result: [String] = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }
            guard
                !line.isEmpty,
                !line.hasPrefix("#"),
                let separator = line.firstIndex(of: "=")
            else {
                continue
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            let qualifiedKey = section.map { "\($0).\(key)" } ?? key
            guard let statement = SafeWorkflowText.normalized("\(qualifiedKey) = \(value)") else { continue }
            result.append(statement)
            if result.count == 96 { break }
        }
        return result
    }

    static func configurationStatements(in content: String) -> [String] {
        if let hookStatements = hookStatements(in: content) {
            return hookStatements
        }
        return tomlStatements(in: content)
    }

    private static func hookStatements(in content: String) -> [String]? {
        guard
            let data = content.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = root["hooks"] as? [String: Any]
        else {
            return nil
        }
        var result: [String] = []
        for trigger in hooks.keys.sorted() {
            guard let registrations = hooks[trigger] as? [[String: Any]] else { continue }
            for registration in registrations {
                let matcher = SafeWorkflowText.normalized(
                    registration["matcher"] as? String ?? "*",
                    limit: 80
                ) ?? "*"
                guard let commands = registration["hooks"] as? [[String: Any]] else { continue }
                for command in commands where command["type"] as? String == "command" {
                    guard
                        let rawPath = command["command"] as? String,
                        let commandName = SafeWorkflowText.normalized(
                            URL(fileURLWithPath: rawPath).lastPathComponent,
                            limit: 160
                        ),
                        let statement = SafeWorkflowText.normalized(
                            "\(trigger)：\(commandName)（匹配 \(matcher)）",
                            limit: 280
                        )
                    else {
                        continue
                    }
                    result.append(statement)
                    if result.count == 96 { return result }
                }
            }
        }
        return result
    }

    static func pluginManifest(in content: String) -> PluginManifest {
        if
            let data = content.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let name = SafeWorkflowText.normalized(object["name"] as? String ?? "", limit: 160)
            let description = SafeWorkflowText.normalized(object["description"] as? String ?? "", limit: 360)
            let statements = ["version", "kind", "status"].compactMap { key -> String? in
                guard let value = object[key] else { return nil }
                return SafeWorkflowText.normalized("\(key) = \(value)", limit: 200)
            }
            return PluginManifest(name: name, description: description, statements: statements)
        }
        let name = TOMLScalarReader.string(for: "name", in: content)
            .flatMap { SafeWorkflowText.normalized($0, limit: 160) }
        let description = TOMLScalarReader.string(for: "description", in: content)
            .flatMap { SafeWorkflowText.normalized($0, limit: 360) }
        return PluginManifest(
            name: name,
            description: description,
            statements: tomlStatements(in: content).filter {
                $0.hasPrefix("version =") || $0.hasPrefix("kind =") || $0.hasPrefix("status =")
            }
        )
    }
}

enum TOMLScalarReader {
    static func string(for key: String, in content: String) -> String? {
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("\(key) =") else { continue }
            let rawValue = line.dropFirst(key.count + 2)
                .trimmingCharacters(in: .whitespaces)
            guard !rawValue.isEmpty else { return nil }
            if rawValue.first == "\"",
               let data = rawValue.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data) {
                return decoded
            }
            return rawValue
        }
        return nil
    }
}

public struct WorkflowFileCollector: Sendable {
    public init() {}

    public func collect(roots: [URL]) -> [WorkflowFileFingerprint] {
        var fingerprints: [String: WorkflowFileFingerprint] = [:]
        for root in roots {
            if let fingerprint = fingerprint(at: root) {
                fingerprints[fingerprint.path] = fingerprint
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let url as URL in enumerator {
                if let fingerprint = fingerprint(at: url) {
                    fingerprints[fingerprint.path] = fingerprint
                }
            }
        }
        return fingerprints.values.sorted { $0.path < $1.path }
    }

    private func fingerprint(at url: URL) -> WorkflowFileFingerprint? {
        guard
            let descriptor = WorkflowFileClassifier.classify(path: url.path),
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
            values.isRegularFile == true,
            let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else {
            return nil
        }
        let content = String(decoding: data, as: UTF8.self)
        let semanticSnapshot: WorkflowSemanticSnapshot?
        switch descriptor.kind {
        case .automation:
            semanticSnapshot = .automation(content: content)
        case .skill:
            semanticSnapshot = .skill(content: content)
        case .hook:
            semanticSnapshot = .hook(content: content)
        case .configuration:
            semanticSnapshot = .configuration(content: content)
        case .plugin:
            semanticSnapshot = .plugin(content: content)
        case .rule:
            semanticSnapshot = .rule(content: content)
        }
        return WorkflowFileFingerprint(
            path: url.path,
            kind: descriptor.kind,
            label: descriptor.label,
            modifiedAt: values.contentModificationDate ?? .distantPast,
            fingerprint: StableEventID.make(parts: ["workflow-file", data.base64EncodedString()]),
            semanticSnapshot: semanticSnapshot
        )
    }
}

public struct WorkflowChangeEventFactory: Sendable {
    public init() {}

    public func events(
        previous: [String: WorkflowFileFingerprint]?,
        current: [WorkflowFileFingerprint],
        observedAt: Date
    ) -> [OperationEvent] {
        guard let previous else { return [] }
        let currentByPath = Dictionary(uniqueKeysWithValues: current.map { ($0.path, $0) })
        var result: [OperationEvent] = []

        for fingerprint in current {
            if let old = previous[fingerprint.path] {
                guard old.fingerprint != fingerprint.fingerprint else { continue }
                result.append(makeEvent(
                    change: "updated",
                    fingerprint: fingerprint,
                    occurredAt: fingerprint.modifiedAt,
                    recordedAt: observedAt,
                    before: old.fingerprint,
                    after: fingerprint.fingerprint,
                    previousSemanticSnapshot: old.semanticSnapshot
                ))
            } else {
                result.append(makeEvent(
                    change: "added",
                    fingerprint: fingerprint,
                    occurredAt: fingerprint.modifiedAt,
                    recordedAt: observedAt,
                    before: nil,
                    after: fingerprint.fingerprint,
                    previousSemanticSnapshot: nil
                ))
            }
        }

        for (path, old) in previous where currentByPath[path] == nil {
            result.append(makeEvent(
                change: "deleted",
                fingerprint: old,
                occurredAt: observedAt,
                recordedAt: observedAt,
                before: old.fingerprint,
                after: nil,
                previousSemanticSnapshot: old.semanticSnapshot
            ))
        }
        return result.sorted { $0.occurredAt > $1.occurredAt }
    }

    private func makeEvent(
        change: String,
        fingerprint: WorkflowFileFingerprint,
        occurredAt: Date,
        recordedAt: Date,
        before: String?,
        after: String?,
        previousSemanticSnapshot: WorkflowSemanticSnapshot?
    ) -> OperationEvent {
        let noun = noun(for: fingerprint.kind)
        let verb = verb(for: change)
        let eventChanges = changes(
            change: change,
            noun: noun,
            label: fingerprint.label,
            previous: previousSemanticSnapshot,
            current: fingerprint.semanticSnapshot
        )
        let targetThreads = (fingerprint.semanticSnapshot ?? previousSemanticSnapshot)?.targetThreadID.map {
            [EventRelatedThread(role: .deliveryTarget, id: $0)]
        }
        return OperationEvent(
            schemaVersion: 1,
            id: StableEventID.make(parts: [
                "workflow-file",
                fingerprint.path,
                change,
                after ?? String(format: "%.6f", occurredAt.timeIntervalSince1970),
            ]),
            occurredAt: occurredAt,
            recordedAt: recordedAt,
            category: category(for: fingerprint.kind),
            action: "\(actionPrefix(for: fingerprint.kind))_\(change)",
            title: "\(noun)已\(verb)",
            summary: summary(label: fingerprint.label, verb: verb, changes: eventChanges),
            status: .success,
            importance: .important,
            certainty: .confirmed,
            actor: EventActor(
                type: actorType(for: fingerprint.kind),
                id: "workflow-file-monitor",
                label: fingerprint.label
            ),
            scope: .globalWorkflow,
            changes: eventChanges,
            relatedThreads: targetThreads,
            sourceChain: [
                EventActor(type: .system, id: "workflow-file-monitor", label: "工作流文件监视器"),
            ],
            before: before.map { .object(["fingerprint": .string($0)]) },
            after: after.map { .object(["fingerprint": .string($0)]) },
            evidence: [
                EventEvidence(kind: "file_fingerprint", label: "受控工作流文件指纹", path: fingerprint.path),
            ]
        )
    }

    private func changes(
        change: String,
        noun: String,
        label: String,
        previous: WorkflowSemanticSnapshot?,
        current: WorkflowSemanticSnapshot?
    ) -> [EventChange] {
        if change == "added" {
            return presenceChanges(prefix: "", snapshot: current) ?? [
                EventChange(label: "工作流定义", summary: "\(noun)「\(label)」已新增"),
            ]
        }
        if change == "deleted" {
            return presenceChanges(prefix: "移除", snapshot: previous) ?? [
                EventChange(label: "工作流定义", summary: "\(noun)「\(label)」已删除"),
            ]
        }
        guard let previous, let current else {
            let snapshot = current ?? previous
            var result = presenceChanges(prefix: "更新后", snapshot: snapshot) ?? [
                EventChange(label: "工作流定义", summary: "\(noun)「\(label)」内容已调整"),
            ]
            result.append(EventChange(
                label: "证据边界",
                summary: "未保留更新前语义快照，无法确认以上职责是否均由本次更新新增"
            ))
            return result
        }
        var result: [EventChange] = []
        appendFieldChange(label: "名称", before: previous.name, after: current.name, to: &result)
        appendFieldChange(label: "状态", before: previous.status, after: current.status, to: &result)
        appendFieldChange(label: "执行计划", before: previous.schedule, after: current.schedule, to: &result)
        appendFieldChange(label: "投递目标", before: previous.targetThreadID, after: current.targetThreadID, to: &result)

        let oldCapabilities = Set(previous.capabilities)
        let newCapabilities = Set(current.capabilities)
        for capability in newCapabilities.subtracting(oldCapabilities).sorted() {
            result.append(EventChange(label: "新增能力", summary: capability, after: capability))
        }
        for capability in oldCapabilities.subtracting(newCapabilities).sorted() {
            result.append(EventChange(label: "移除能力", summary: capability, before: capability))
        }
        if previous.purpose != current.purpose {
            let summary = current.purpose.map { "用途说明已调整：\($0)" } ?? "用途说明已移除"
            result.append(EventChange(
                label: "用途调整",
                summary: summary,
                before: previous.purpose,
                after: current.purpose
            ))
        }
        let oldInterfaces = Set(previous.interfaces)
        let newInterfaces = Set(current.interfaces)
        for item in newInterfaces.subtracting(oldInterfaces).sorted() {
            result.append(EventChange(label: "新增模块", summary: item, after: item))
        }
        for item in oldInterfaces.subtracting(newInterfaces).sorted() {
            result.append(EventChange(label: "移除模块", summary: item, before: item))
        }
        let oldStatements = Set(previous.statements)
        let newStatements = Set(current.statements)
        let statementLabels = statementChangeLabels(noun: noun)
        for item in newStatements.subtracting(oldStatements).sorted() {
            result.append(EventChange(label: statementLabels.added, summary: item, after: item))
        }
        for item in oldStatements.subtracting(newStatements).sorted() {
            result.append(EventChange(label: statementLabels.removed, summary: item, before: item))
        }
        if result.isEmpty {
            result.append(EventChange(
                label: "实现细节",
                summary: "\(noun)「\(label)」实现内容已调整；用途与可识别能力未变化"
            ))
        }
        return result
    }

    private func presenceChanges(
        prefix: String,
        snapshot: WorkflowSemanticSnapshot?
    ) -> [EventChange]? {
        guard let snapshot else { return nil }
        var result: [EventChange] = []
        if let purpose = snapshot.purpose {
            let label = prefix.isEmpty ? "用途" : "\(prefix)职责"
            result.append(EventChange(label: label, summary: purpose, after: purpose))
        }
        let capabilityLabel = prefix.isEmpty ? "主要能力" : "\(prefix)包含"
        for capability in snapshot.capabilities.prefix(5) {
            result.append(EventChange(label: capabilityLabel, summary: capability, after: capability))
        }
        let interfaceLabel = prefix.isEmpty ? "包含模块" : "\(prefix)包含"
        for item in snapshot.interfaces.prefix(max(0, 5 - snapshot.capabilities.count)) {
            result.append(EventChange(label: interfaceLabel, summary: item, after: item))
        }
        let statementLabel = prefix.isEmpty ? "主要内容" : "\(prefix)包含"
        for item in snapshot.statements.prefix(max(0, 5 - result.count)) {
            result.append(EventChange(label: statementLabel, summary: item, after: item))
        }
        return result.isEmpty ? nil : result
    }

    private func statementChangeLabels(noun: String) -> (added: String, removed: String) {
        switch noun {
        case "全局规则": ("新增规则", "移除规则")
        case "Codex 配置": ("新增设置", "移除设置")
        case "Plugin": ("新增声明", "移除声明")
        default: ("新增说明", "移除说明")
        }
    }

    private func appendFieldChange(
        label: String,
        before: String?,
        after: String?,
        to result: inout [EventChange]
    ) {
        guard before != after else { return }
        let summary: String
        if let before, let after {
            summary = "\(label)由「\(before)」改为「\(after)」"
        } else if let after {
            summary = "设置\(label)为「\(after)」"
        } else {
            summary = "移除\(label)「\(before ?? "未知")」"
        }
        result.append(EventChange(label: label, summary: summary, before: before, after: after))
    }

    private func summary(label: String, verb: String, changes: [EventChange]) -> String {
        let readable = changes.prefix(3).map {
            $0.summary.trimmingCharacters(in: CharacterSet(charactersIn: " \\t\\r\\n。；;"))
        }.joined(separator: "；")
        return readable.isEmpty
            ? "\(label) 的全局工作流定义已\(verb)。"
            : "\(label)：\(readable)。"
    }

    private func actionPrefix(for kind: WorkflowFileKind) -> String {
        switch kind {
        case .rule: "workflow_rule"
        case .configuration: "workflow_config"
        case .skill: "skill"
        case .hook: "hook"
        case .plugin: "plugin"
        case .automation: "automation"
        }
    }

    private func noun(for kind: WorkflowFileKind) -> String {
        switch kind {
        case .rule: "全局规则"
        case .configuration: "Codex 配置"
        case .skill: "Skill"
        case .hook: "Hook"
        case .plugin: "Plugin"
        case .automation: "Automation"
        }
    }

    private func verb(for change: String) -> String {
        switch change {
        case "added": "新增"
        case "deleted": "删除"
        default: "更新"
        }
    }

    private func actorType(for kind: WorkflowFileKind) -> EventActorType {
        switch kind {
        case .skill: .skill
        case .hook: .hook
        case .plugin: .plugin
        case .automation: .automation
        case .rule, .configuration: .system
        }
    }

    private func category(for kind: WorkflowFileKind) -> EventCategory {
        switch kind {
        case .skill: .skill
        case .hook: .hook
        case .plugin: .plugin
        case .automation: .automation
        case .rule, .configuration: .system
        }
    }
}

public struct DailyDigestEvidence: Codable, Equatable, Sendable {
    public let day: String
    public let generatedAt: Date
    public let sourcePath: String

    public init(day: String, generatedAt: Date, sourcePath: String) {
        self.day = day
        self.generatedAt = generatedAt
        self.sourcePath = sourcePath
    }
}

public struct DailyDigestEventFactory: Sendable {
    public init() {}

    public func event(from evidence: DailyDigestEvidence, recordedAt: Date) -> OperationEvent {
        OperationEvent(
            schemaVersion: 1,
            id: StableEventID.make(parts: ["daily-digest", evidence.day]),
            occurredAt: evidence.generatedAt,
            recordedAt: recordedAt,
            category: .automation,
            action: "daily_digest_generated",
            title: "每日摘要已生成",
            summary: "\(evidence.day) 的 Codex 每日摘要已更新。",
            status: .success,
            importance: .important,
            certainty: .confirmed,
            actor: EventActor(type: .automation, id: "daily-digest", label: "DailyDigest"),
            sourceChain: [
                EventActor(type: .automation, id: "daily-digest", label: "DailyDigest"),
                EventActor(type: .hook, id: "task-ledger", label: "任务台账"),
            ],
            evidence: [
                EventEvidence(kind: "daily_digest", label: "每日摘要文件", path: evidence.sourcePath),
            ]
        )
    }
}
