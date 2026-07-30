import Foundation

public struct ContextCardSummary: Equatable, Sendable {
    public let topic: String?
    public let recentUserRequest: String?
    public let recentAssistantProgress: [String]

    public init(
        topic: String? = nil,
        recentUserRequest: String? = nil,
        recentAssistantProgress: [String] = []
    ) {
        self.topic = topic
        self.recentUserRequest = recentUserRequest
        self.recentAssistantProgress = recentAssistantProgress
    }

    fileprivate static func parse(markdown: String) -> Self {
        var currentSection: String?
        var sections: [String: [String]] = [:]
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("## ") {
                currentSection = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let currentSection, line.hasPrefix("- ") else { continue }
            sections[currentSection, default: []].append(String(line.dropFirst(2)))
        }

        let topics = (sections["当前主题"] ?? []).compactMap(normalizedContent)
        let userRequests = (sections["最近用户请求"] ?? []).compactMap(normalizedContent)
        let assistantProgress = (sections["最近助手进展"] ?? []).compactMap(normalizedContent)
        return Self(
            topic: topics.reversed().first(where: isMeaningful),
            recentUserRequest: userRequests.reversed().first(where: isMeaningful),
            recentAssistantProgress: Array(assistantProgress.suffix(2))
        )
    }

    private static func normalizedContent(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        for role in ["**用户**:", "**助手**:"] {
            if let range = value.range(of: role) {
                value = String(value[range.upperBound...])
                break
            }
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("# files mentioned by the user:") {
            guard let requestRange = value.range(
                of: "## My request for Codex:",
                options: [.caseInsensitive]
            ) else {
                return nil
            }
            value = String(value[requestRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let compact = value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard !compact.isEmpty, !isInjectedPreview(compact) else { return nil }
        return compact.count <= 360 ? compact : String(compact.prefix(357)) + "…"
    }

    static func isInjectedPreview(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "<recommended_plugins", "<codex_internal_context", "<heartbeat",
            "<automation_id", "<current_time_iso", "<instructions>", "<codex_delegation",
            "# files mentioned by the user:", "# agents.md instructions",
        ].contains { normalized.hasPrefix($0) }
    }

    private static func isMeaningful(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: CharacterSet(charactersIn: " 。！？!?，,"))
            .lowercased()
        let acknowledgements: Set<String> = [
            "嗯", "嗯可以", "可以", "好的", "好", "行", "ok", "okay", "继续",
            "那你做迭代更新吧", "做迭代更新吧",
        ]
        return normalized.count >= 6 && !acknowledgements.contains(normalized)
    }
}

public struct ContextCardEvidence: Equatable, Sendable {
    public let generatedAt: Date
    public let trigger: String
    public let threadID: String
    public let projectPath: String?
    public let sourcePath: String
    public let summary: ContextCardSummary

    public init(
        generatedAt: Date,
        trigger: String,
        threadID: String,
        projectPath: String?,
        sourcePath: String,
        summary: ContextCardSummary = ContextCardSummary()
    ) {
        self.generatedAt = generatedAt
        self.trigger = trigger
        self.threadID = threadID
        self.projectPath = projectPath
        self.sourcePath = sourcePath
        self.summary = summary
    }

    public static func parse(markdown: String, sourcePath: String) -> ContextCardEvidence? {
        var values: [String: String] = [:]
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            guard text.hasPrefix("- "), let separator = text.firstIndex(of: ":") else { continue }
            let key = String(text[text.index(text.startIndex, offsetBy: 2)..<separator])
                .trimmingCharacters(in: .whitespaces)
            let rawValue = String(text[text.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            values[key] = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        }

        guard
            let generated = values["生成时间"],
            let generatedAt = EvidenceDateParser.date(from: generated),
            let trigger = values["触发事件"],
            let threadID = values["会话 ID"],
            !threadID.isEmpty
        else {
            return nil
        }

        return ContextCardEvidence(
            generatedAt: generatedAt,
            trigger: trigger,
            threadID: threadID,
            projectPath: values["项目路径"],
            sourcePath: sourcePath,
            summary: ContextCardSummary.parse(markdown: markdown)
        )
    }
}

public struct AutomaticResetEvidence: Equatable, Sendable {
    public let profile: String
    public let reason: String
    public let expiresAt: Date
    public let attemptedAt: Date
    public let outcome: String
    public let producer: String?

    public init(
        profile: String,
        reason: String,
        expiresAt: Date,
        attemptedAt: Date,
        outcome: String,
        producer: String? = nil
    ) {
        self.profile = profile
        self.reason = reason
        self.expiresAt = expiresAt
        self.attemptedAt = attemptedAt
        self.outcome = outcome
        self.producer = producer
    }

    public static func parse(preferences: [String: JSONValue]) -> [AutomaticResetEvidence] {
        let outcomePrefix = "automatic-reset.outcome."
        let attemptPrefix = "automatic-reset.last-attempt."
        let actorPrefix = "automatic-reset.actor."

        return preferences.compactMap { key, value in
            guard key.hasPrefix(outcomePrefix), case .string(let outcome) = value else { return nil }
            let suffix = String(key.dropFirst(outcomePrefix.count))
            let components = suffix.split(separator: ".").map(String.init)
            guard
                components.count >= 3,
                let expirySeconds = TimeInterval(components.last ?? "")
            else {
                return nil
            }
            let reason = components[components.count - 2]
            let profile = components.dropLast(2).joined(separator: ".")
            let attemptKey = attemptPrefix + suffix
            guard
                let attemptValue = preferences[attemptKey],
                case .number(let attemptSeconds) = attemptValue,
                !profile.isEmpty
            else {
                return nil
            }
            let producer: String?
            if
                let actorValue = preferences[actorPrefix + suffix],
                case .string(let actor) = actorValue
            {
                producer = actor
            } else {
                producer = nil
            }
            return AutomaticResetEvidence(
                profile: profile,
                reason: reason,
                expiresAt: Date(timeIntervalSince1970: expirySeconds),
                attemptedAt: Date(timeIntervalSince1970: attemptSeconds),
                outcome: outcome,
                producer: producer
            )
        }
        .sorted { $0.attemptedAt > $1.attemptedAt }
    }
}

public enum LifecycleKind: String, Sendable {
    case task
    case work
}

public struct LifecycleItem: Equatable, Sendable {
    public let id: String
    public let title: String
    public let status: String?
    public let projectName: String?
    public let projectPath: String?
    public let threadID: String?

    public init(
        id: String,
        title: String,
        status: String?,
        projectName: String?,
        projectPath: String?,
        threadID: String?
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.projectName = projectName
        self.projectPath = projectPath
        self.threadID = threadID
    }
}

public struct LifecycleLedgerRecord: Equatable, Sendable {
    public let at: Date
    public let event: String
    public let kind: LifecycleKind
    public let item: LifecycleItem

    public init(at: Date, event: String, kind: LifecycleKind, item: LifecycleItem) {
        self.at = at
        self.event = event
        self.kind = kind
        self.item = item
    }

    public static func parse(line: String, kind: LifecycleKind) -> LifecycleLedgerRecord? {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let atString = object["at"] as? String,
            let at = EvidenceDateParser.date(from: atString),
            let event = object["event"] as? String,
            let payload = object[kind.rawValue] as? [String: Any],
            let id = payload["id"] as? String,
            let title = payload["title"] as? String
        else {
            return nil
        }
        let project = payload["project"] as? [String: Any]
        let source = payload["source"] as? [String: Any]
        return LifecycleLedgerRecord(
            at: at,
            event: event,
            kind: kind,
            item: LifecycleItem(
                id: id,
                title: title,
                status: payload["status"] as? String,
                projectName: project?["name"] as? String,
                projectPath: project?["path"] as? String,
                threadID: source?["thread_id"] as? String
            )
        )
    }
}

public struct EvidenceSnapshot: Equatable, Sendable {
    public let contextCards: [ContextCardEvidence]
    public let automaticResets: [AutomaticResetEvidence]
    public let lifecycleRecords: [LifecycleLedgerRecord]
    public let threadCatalog: CodexMetadataCatalog
    public let dailyDigests: [DailyDigestEvidence]
    public let workflowFiles: [WorkflowFileFingerprint]
    public let warnings: [String]

    public init(
        contextCards: [ContextCardEvidence] = [],
        automaticResets: [AutomaticResetEvidence] = [],
        lifecycleRecords: [LifecycleLedgerRecord] = [],
        threadCatalog: CodexMetadataCatalog = CodexMetadataCatalog(),
        dailyDigests: [DailyDigestEvidence] = [],
        workflowFiles: [WorkflowFileFingerprint] = [],
        warnings: [String] = []
    ) {
        self.contextCards = contextCards
        self.automaticResets = automaticResets
        self.lifecycleRecords = lifecycleRecords
        self.threadCatalog = threadCatalog
        self.dailyDigests = dailyDigests
        self.workflowFiles = workflowFiles
        self.warnings = warnings
    }
}

public struct LocalEvidencePaths: Equatable, Sendable {
    public let contextCardsDirectory: URL
    public let taskLedgerURL: URL
    public let workLedgerURL: URL
    public let profileSwitcherDefaultsDomain: String
    public let stateDatabaseURL: URL?
    public let dailyDigestDirectory: URL?
    public let workflowWatchRoots: [URL]

    public init(
        contextCardsDirectory: URL,
        taskLedgerURL: URL,
        workLedgerURL: URL,
        profileSwitcherDefaultsDomain: String = "com.hd2yao.codex-profile-switcher",
        stateDatabaseURL: URL? = nil,
        dailyDigestDirectory: URL? = nil,
        workflowWatchRoots: [URL] = []
    ) {
        self.contextCardsDirectory = contextCardsDirectory
        self.taskLedgerURL = taskLedgerURL
        self.workLedgerURL = workLedgerURL
        self.profileSwitcherDefaultsDomain = profileSwitcherDefaultsDomain
        self.stateDatabaseURL = stateDatabaseURL
        self.dailyDigestDirectory = dailyDigestDirectory
        self.workflowWatchRoots = workflowWatchRoots
    }

    public static func standard(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        let codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        return Self(
            contextCardsDirectory: codexHome.appendingPathComponent("context-cards", isDirectory: true),
            taskLedgerURL: codexHome.appendingPathComponent("task-ledger/tasks.jsonl"),
            workLedgerURL: codexHome.appendingPathComponent("work-ledger/work.jsonl"),
            stateDatabaseURL: codexHome.appendingPathComponent("state_5.sqlite"),
            dailyDigestDirectory: codexHome.appendingPathComponent("task-ledger/digests/daily", isDirectory: true),
            workflowWatchRoots: [
                codexHome.appendingPathComponent("AGENTS.md"),
                codexHome.appendingPathComponent("config.toml"),
                codexHome.appendingPathComponent("hooks.json"),
                codexHome.appendingPathComponent("hooks", isDirectory: true),
                codexHome.appendingPathComponent("automations", isDirectory: true),
                codexHome.appendingPathComponent("skills", isDirectory: true),
                codexHome.appendingPathComponent("plugins/personal", isDirectory: true),
                homeDirectory.appendingPathComponent("program/codex-workflow-skills", isDirectory: true),
            ]
        )
    }
}

public struct LocalEvidenceReader {
    public init() {}

    public func read(
        paths: LocalEvidencePaths = .standard(),
        resetPreferences: [String: JSONValue]? = nil
    ) -> EvidenceSnapshot {
        var cards: [ContextCardEvidence] = []
        var records: [LifecycleLedgerRecord] = []
        var warnings: [String] = []
        var threadCatalog = CodexMetadataCatalog()

        let cardURLs = (try? FileManager.default.contentsOfDirectory(
            at: paths.contextCardsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in cardURLs where url.pathExtension.lowercased() == "md" {
            guard let markdown = try? String(contentsOf: url, encoding: .utf8) else {
                warnings.append("无法读取上下文摘要卡片。")
                continue
            }
            if let card = ContextCardEvidence.parse(markdown: markdown, sourcePath: url.path) {
                cards.append(card)
            }
        }

        records += readLifecycleLedger(at: paths.taskLedgerURL, kind: .task, warnings: &warnings)
        records += readLifecycleLedger(at: paths.workLedgerURL, kind: .work, warnings: &warnings)

        if let stateDatabaseURL = paths.stateDatabaseURL {
            let metadata = CodexMetadataCatalogReader().read(databaseURL: stateDatabaseURL)
            threadCatalog = metadata.catalog
            warnings += metadata.warnings
        }

        var preferenceValues = resetPreferences ?? [:]
        if resetPreferences == nil, let defaults = UserDefaults(suiteName: paths.profileSwitcherDefaultsDomain) {
            for (key, value) in defaults.dictionaryRepresentation() {
                if let string = value as? String {
                    preferenceValues[key] = .string(string)
                } else if let number = value as? NSNumber {
                    preferenceValues[key] = .number(number.doubleValue)
                }
            }
        }

        return EvidenceSnapshot(
            contextCards: cards.sorted { $0.generatedAt > $1.generatedAt },
            automaticResets: AutomaticResetEvidence.parse(preferences: preferenceValues),
            lifecycleRecords: records.sorted { $0.at > $1.at },
            threadCatalog: threadCatalog,
            dailyDigests: readDailyDigests(directory: paths.dailyDigestDirectory),
            workflowFiles: WorkflowFileCollector().collect(roots: paths.workflowWatchRoots),
            warnings: warnings
        )
    }

    private func readLifecycleLedger(
        at url: URL,
        kind: LifecycleKind,
        warnings: inout [String]
    ) -> [LifecycleLedgerRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            warnings.append("无法读取\(kind == .task ? "任务" : "成果")台账。")
            return []
        }
        return text.split(separator: "\n").compactMap {
            LifecycleLedgerRecord.parse(line: String($0), kind: kind)
        }
    }

    private func readDailyDigests(directory: URL?) -> [DailyDigestEvidence] {
        guard let directory else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            let day = url.deletingPathExtension().lastPathComponent
            guard
                url.pathExtension.lowercased() == "md",
                day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                let modifiedAt = values.contentModificationDate
            else {
                return nil
            }
            return DailyDigestEvidence(day: day, generatedAt: modifiedAt, sourcePath: url.path)
        }
        .sorted { $0.generatedAt > $1.generatedAt }
    }
}

enum EvidenceDateParser {
    static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ?? standard.date(from: value)
    }
}
