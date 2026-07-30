import Foundation

public struct WorkflowPatchEvidence: Equatable, Sendable {
    public let sourceThread: CodexThreadMetadata
    public let changes: [EventChange]
    public let evidencePath: String

    public init(sourceThread: CodexThreadMetadata, changes: [EventChange], evidencePath: String) {
        self.sourceThread = sourceThread
        self.changes = changes
        self.evidencePath = evidencePath
    }
}

public struct WorkflowSessionPatchEvidenceCollector: Sendable {
    public let lookback: TimeInterval
    public let lookahead: TimeInterval

    public init(lookback: TimeInterval = 300, lookahead: TimeInterval = 10) {
        self.lookback = lookback
        self.lookahead = lookahead
    }

    public func evidence(
        kind: WorkflowFileKind,
        label: String,
        path: String,
        occurredAt: Date,
        catalog: CodexMetadataCatalog,
        rolloutCache: WorkflowRolloutTextCache = WorkflowRolloutTextCache()
    ) -> [WorkflowPatchEvidence] {
        catalog.records.compactMap { thread in
            guard
                thread.createdAt <= occurredAt.addingTimeInterval(lookahead),
                thread.updatedAt >= occurredAt.addingTimeInterval(-lookback),
                let rolloutPath = thread.rolloutPath,
                let text = rolloutCache.text(at: rolloutPath)
            else {
                return nil
            }

            var matchedCallChanges: [[EventChange]] = []
            for rawLine in text.split(separator: "\n") {
                guard
                    let data = String(rawLine).data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let timestampText = object["timestamp"] as? String,
                    let timestamp = Self.date(from: timestampText),
                    timestamp >= occurredAt.addingTimeInterval(-lookback),
                    timestamp <= occurredAt.addingTimeInterval(lookahead),
                    let payload = object["payload"] as? [String: Any],
                    payload["type"] as? String == "custom_tool_call",
                    let input = payload["input"] as? String,
                    let patch = Self.decodedPatch(in: input)
                else {
                    continue
                }
                let blocks = Self.blocks(in: patch).filter {
                    Self.matches(path: $0.path, expectedPath: path, kind: kind, label: label)
                }
                guard !blocks.isEmpty else { continue }
                let removed = blocks.flatMap(\.removed)
                let added = blocks.flatMap(\.added)
                let changes = WorkflowPatchChangeAnalyzer.changes(
                    kind: kind,
                    label: label,
                    removed: removed,
                    added: added
                )
                guard !changes.isEmpty else { continue }
                matchedCallChanges.append(Self.uniqued(changes))
            }
            let semanticGroups = Dictionary(grouping: matchedCallChanges, by: Self.changeSignature)
            guard semanticGroups.count == 1, let matchedChanges = semanticGroups.values.first?.first else {
                return nil
            }
            return WorkflowPatchEvidence(
                sourceThread: thread,
                changes: matchedChanges,
                evidencePath: rolloutPath
            )
        }
    }

    private struct PatchBlock {
        let path: String
        let removed: [String]
        let added: [String]
    }

    private static func decodedPatch(in input: String) -> String? {
        let pattern = #"\b(?:const|let|var)\s+patch\s*=\s*(\"(?:\\.|[^\"\\])*\")"#
        if
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
            let range = Range(match.range(at: 1), in: input),
            let data = String(input[range]).data(using: .utf8),
            let decoded = try? JSONDecoder().decode(String.self, from: data),
            decoded.contains("*** Begin Patch")
        {
            return decoded
        }
        return input.contains("*** Begin Patch") && input.contains("\n") ? input : nil
    }

    private static func blocks(in patch: String) -> [PatchBlock] {
        var result: [PatchBlock] = []
        var currentPath: String?
        var removed: [String] = []
        var added: [String] = []

        func flush() {
            guard let currentPath else { return }
            result.append(PatchBlock(path: currentPath, removed: removed, added: added))
        }

        for rawLine in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let path = filePath(from: line) {
                flush()
                currentPath = path
                removed = []
                added = []
                continue
            }
            if line == "*** End Patch" {
                flush()
                currentPath = nil
                removed = []
                added = []
                continue
            }
            guard currentPath != nil else { continue }
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                added.append(String(line.dropFirst()))
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                removed.append(String(line.dropFirst()))
            }
        }
        flush()
        return result
    }

    private static func filePath(from line: String) -> String? {
        for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func matches(
        path candidatePath: String,
        expectedPath: String,
        kind: WorkflowFileKind,
        label: String
    ) -> Bool {
        let candidate = URL(fileURLWithPath: candidatePath).standardizedFileURL
        let expected = URL(fileURLWithPath: expectedPath).standardizedFileURL
        if candidate.path == expected.path { return true }
        switch kind {
        case .rule, .configuration:
            return false
        case .skill:
            return candidate.lastPathComponent == "SKILL.md"
                && candidate.deletingLastPathComponent().lastPathComponent == label
        case .hook:
            return candidate.deletingPathExtension().lastPathComponent == label
        case .automation:
            return candidate.lastPathComponent == "automation.toml"
                && candidate.deletingLastPathComponent().lastPathComponent == label
        case .plugin:
            return candidate.deletingPathExtension().lastPathComponent == label
        }
    }

    private static func uniqued(_ changes: [EventChange]) -> [EventChange] {
        var seen: Set<String> = []
        return changes.filter {
            seen.insert([$0.label, $0.summary, $0.before ?? "", $0.after ?? ""].joined(separator: "\u{1F}"))
                .inserted
        }
    }

    private static func changeSignature(_ changes: [EventChange]) -> String {
        changes.map {
            [$0.label, $0.summary, $0.before ?? "", $0.after ?? ""].joined(separator: "\u{1F}")
        }.sorted().joined(separator: "\u{1E}")
    }

    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ?? standard.date(from: value)
    }
}

enum WorkflowPatchChangeAnalyzer {
    static func changes(
        kind: WorkflowFileKind,
        label: String,
        removed: [String],
        added: [String]
    ) -> [EventChange] {
        var result: [EventChange] = []
        if kind == .rule {
            appendRuleChanges(removed: removed, added: added, to: &result)
        }
        if kind == .skill {
            appendSkillPurposeChange(removed: removed, added: added, to: &result)
        }
        if kind == .configuration || kind == .plugin {
            appendSettingChanges(removed: removed, added: added, to: &result)
        }
        appendCapabilityChanges(removed: removed, added: added, to: &result)
        if kind == .hook || kind == .plugin {
            appendFunctionChanges(removed: removed, added: added, to: &result)
        }
        if result.isEmpty, kind == .skill {
            appendMarkdownChanges(removed: removed, added: added, to: &result)
        }
        return Array(uniqued(result).prefix(8))
    }

    private static func appendRuleChanges(
        removed: [String],
        added: [String],
        to result: inout [EventChange]
    ) {
        let oldRules = removed.compactMap(markdownDirective)
        let newRules = added.compactMap(markdownDirective)
        for rule in newRules where !oldRules.contains(rule) {
            result.append(EventChange(label: "新增规则", summary: rule, after: rule))
        }
        for rule in oldRules where !newRules.contains(rule) {
            result.append(EventChange(label: "移除规则", summary: rule, before: rule))
        }
    }

    private static func appendSkillPurposeChange(
        removed: [String],
        added: [String],
        to result: inout [EventChange]
    ) {
        let before = removed.compactMap(skillDescription).last
        let after = added.compactMap(skillDescription).last
        guard before != after, before != nil || after != nil else { return }
        let summary = after.map { "用途说明已调整：\($0)" } ?? "用途说明已移除"
        result.append(EventChange(label: "用途调整", summary: summary, before: before, after: after))
    }

    private static func appendSettingChanges(
        removed: [String],
        added: [String],
        to result: inout [EventChange]
    ) {
        var oldSettings: [String: String] = [:]
        var newSettings: [String: String] = [:]
        for (key, value) in removed.compactMap(setting) { oldSettings[key] = value }
        for (key, value) in added.compactMap(setting) { newSettings[key] = value }
        for key in Set(oldSettings.keys).union(newSettings.keys).sorted() where oldSettings[key] != newSettings[key] {
            let before = oldSettings[key]
            let after = newSettings[key]
            let summary = after.map { "\(key) 设置为 \($0)" } ?? "移除设置 \(key)"
            result.append(EventChange(label: "设置调整", summary: summary, before: before, after: after))
        }
    }

    private static func appendCapabilityChanges(
        removed: [String],
        added: [String],
        to result: inout [EventChange]
    ) {
        let oldCapabilities = Set(AutomationCapabilityClassifier.labels(in: removed.joined(separator: "\n")))
        let newCapabilities = Set(AutomationCapabilityClassifier.labels(in: added.joined(separator: "\n")))
        for capability in newCapabilities.subtracting(oldCapabilities).sorted() {
            result.append(EventChange(label: "新增能力", summary: capability, after: capability))
        }
        for capability in oldCapabilities.subtracting(newCapabilities).sorted() {
            result.append(EventChange(label: "移除能力", summary: capability, before: capability))
        }
    }

    private static func appendFunctionChanges(
        removed: [String],
        added: [String],
        to result: inout [EventChange]
    ) {
        let oldFunctions = Set(removed.compactMap(functionName))
        let newFunctions = Set(added.compactMap(functionName))
        for function in newFunctions.subtracting(oldFunctions).sorted() {
            let description = functionDescription(function)
            result.append(EventChange(
                label: "新增入口",
                summary: "\(description)（\(function)）",
                after: function
            ))
        }
        for function in oldFunctions.subtracting(newFunctions).sorted() {
            result.append(EventChange(label: "移除入口", summary: function, before: function))
        }
    }

    private static func appendMarkdownChanges(
        removed: [String],
        added: [String],
        to result: inout [EventChange]
    ) {
        let oldItems = removed.compactMap(markdownDirective)
        let newItems = added.compactMap(markdownDirective)
        for item in newItems where !oldItems.contains(item) {
            result.append(EventChange(label: "新增说明", summary: item, after: item))
        }
        for item in oldItems where !newItems.contains(item) {
            result.append(EventChange(label: "移除说明", summary: item, before: item))
        }
    }

    private static func markdownDirective(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") else { return nil }
        return SafeWorkflowText.normalized(String(trimmed.dropFirst(2)), limit: 360)
    }

    private static func skillDescription(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("description:") else { return nil }
        return SafeWorkflowText.normalized(String(trimmed.dropFirst("description:".count)), limit: 360)
    }

    private static func setting(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return nil }
        let key = String(trimmed[..<separator]).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        let rawValue = String(trimmed[trimmed.index(after: separator)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t,\"'"))
        guard
            let safeKey = SafeWorkflowText.normalized(key, limit: 100),
            let safeValue = SafeWorkflowText.normalized(rawValue, limit: 180),
            !SafeWorkflowText.containsSensitiveValue("\(safeKey) = \(safeValue)")
        else {
            return nil
        }
        return (safeKey, safeValue)
    }

    private static func functionName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(?:async\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#
        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
            let range = Range(match.range(at: 1), in: trimmed)
        else {
            return nil
        }
        return String(trimmed[range])
    }

    private static func functionDescription(_ function: String) -> String {
        let known = [
            "track_follow_up": "等待目标登记",
            "update_follow_up": "续作状态更新",
            "list_follow_ups": "续作监控查询",
            "validate_zoned_datetime": "带时区检查时间校验",
        ]
        return known[function] ?? "功能入口"
    }

    private static func uniqued(_ changes: [EventChange]) -> [EventChange] {
        var seen: Set<String> = []
        return changes.filter {
            seen.insert([$0.label, $0.summary].joined(separator: "\u{1F}")).inserted
        }
    }
}
