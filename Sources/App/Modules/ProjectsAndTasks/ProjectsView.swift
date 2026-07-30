import CodexWorkbenchCore
import SwiftUI

struct ProjectsView: View {
    @ObservedObject var model: WorkbenchAppModel

    private var insights: WorkspaceInsightsPresentation {
        AccountPresentationBuilder.workspaceInsights(payload: model.accountPayload)
    }

    private var totalTokens: Int {
        insights.projects.reduce(0) { $0 + $1.tokensUsed }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                PageHeader(
                    eyebrow: "Projects",
                    title: "项目与任务",
                    description: "按真实工作区查看项目统计、最近任务、上下文摘要与接续关系。",
                    trailing: AnyView(
                        Button("刷新") { Task { await model.refreshAll() } }
                            .disabled(model.isRefreshing)
                    )
                )

                if let error = model.accountError {
                    InsightsNotice(message: error)
                }

                threadAttributionContent

                if insights.projectsAvailable {
                    projectContent
                } else if model.isRefreshing && model.accountPayload == nil {
                    InsightsLoadingState(message: "正在读取项目历史…")
                } else {
                    InsightsUnavailableState(
                        systemImage: "externaldrive.badge.questionmark",
                        title: "项目数据源不可用",
                        message: "工作台尚未从本地 Codex 历史库读取到项目排行；这不代表项目数量为 0。"
                    )
                }

                recentTasksContent
            }
            .padding(.horizontal, WorkbenchSpacing.lg)
            .padding(.vertical, WorkbenchSpacing.lg)
            .frame(maxWidth: 1_180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("projects-page")
    }

    @ViewBuilder
    private var threadAttributionContent: some View {
        if let summary = model.accountPayload?.threadAttribution {
            ThreadAttributionPanel(summary: summary)
        } else {
            InsightsUnavailableState(
                systemImage: "arrow.triangle.branch",
                title: "线程归因数据不可用",
                message: "当前 payload 没有提供本机 rollout 归因；不会把旧的本地 token 合计冒充为父子拆分。"
            )
        }
    }

    @ViewBuilder
    private var recentTasksContent: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(
                "最近任务",
                detail: "\(model.workspaceCatalog.recentThreads.count) 个任务 · \(model.workspaceCatalog.contextSummaryCount) 个有摘要"
            )
            if model.workspaceCatalog.projects.isEmpty {
                SurfaceCard {
                    QuietEmptyState(
                        systemImage: "bubble.left.and.bubble.right",
                        title: "还没有任务目录",
                        message: "当前 metadata 目录中没有可展示的真实任务；不会用操作日志推断任务数量。"
                    )
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(model.workspaceCatalog.projects.prefix(8), id: \.path) { project in
                    SurfaceCard(padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(project.path)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text("\(project.threads.count) 个任务")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, WorkbenchSpacing.md)
                            .padding(.vertical, WorkbenchSpacing.sm)
                            Divider()
                            ForEach(Array(project.threads.prefix(6).enumerated()), id: \.element.id) { index, thread in
                                WorkspaceThreadRow(thread: thread) {
                                    CodexIntegrationService.openThread(thread.id)
                                }
                                if index < min(project.threads.count, 6) - 1 {
                                    Divider().padding(.leading, 48)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var projectContent: some View {
        if insights.projects.isEmpty {
            SurfaceCard {
                QuietEmptyState(
                    systemImage: "folder",
                    title: "还没有项目活动",
                    message: "数据源可用，但本地历史中暂时没有带工作目录的任务。"
                )
                .frame(maxWidth: .infinity)
            }
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: WorkbenchSpacing.sm)],
                spacing: WorkbenchSpacing.sm
            ) {
                InsightSummaryTile(
                    title: "项目",
                    value: "\(insights.projects.count)",
                    detail: "有本地活动记录",
                    systemImage: "folder"
                )
                InsightSummaryTile(
                    title: "对话",
                    value: "\(insights.projects.reduce(0) { $0 + $1.threadCount })",
                    detail: "跨项目累计",
                    systemImage: "bubble.left.and.bubble.right"
                )
                InsightSummaryTile(
                    title: "Tokens",
                    value: TokenCountFormatter.chinese(totalTokens),
                    detail: "本地任务历史累计",
                    systemImage: "number"
                )
                .help(TokenCountFormatter.accessibility(totalTokens))
                .accessibilityLabel("Tokens")
                .accessibilityValue(TokenCountFormatter.accessibility(totalTokens))
            }

            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                SectionTitle("项目排行", detail: "按 Tokens 从高到低")
                SurfaceCard(padding: 0) {
                    ForEach(Array(insights.projects.enumerated()), id: \.element.path) { index, project in
                        ProjectRankingRow(rank: index + 1, project: project)
                        if index < insights.projects.count - 1 {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
            }
        }
    }
}

private struct ThreadAttributionPanel: View {
    let summary: AccountThreadAttributionSummary
    @State private var expandedThreadIDs: Set<String> = []

    var body: some View {
        SurfaceCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionTitle(
                            "线程归因",
                            detail: "\(summary.topLevelTaskCount) 个顶层任务 · \(summary.rolloutCount) 个 rollout"
                        )
                        Spacer(minLength: WorkbenchSpacing.sm)
                        StatusChip(summary.scopeLabel, color: .secondary)
                    }
                    Text("以下均为本机 rollout 统计，不是官方账单，也不是实时配额。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, WorkbenchSpacing.md)
                .padding(.vertical, WorkbenchSpacing.sm)
                Divider()

                if summary.tasks.isEmpty {
                    QuietEmptyState(
                        systemImage: "tray",
                        title: "没有可归因的 rollout",
                        message: "本机历史暂未提供可解析的线程 token 统计。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    ForEach(Array(summary.tasks.enumerated()), id: \.element.id) { index, task in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedThreadIDs.contains(task.id) },
                                set: { isExpanded in
                                    if isExpanded {
                                        expandedThreadIDs.insert(task.id)
                                    } else {
                                        expandedThreadIDs.remove(task.id)
                                    }
                                }
                            )
                        ) {
                            ThreadAttributionDetails(task: task)
                                .padding(.top, WorkbenchSpacing.xs)
                        } label: {
                            ThreadAttributionTaskRow(task: task)
                        }
                        .padding(.horizontal, WorkbenchSpacing.md)
                        .padding(.vertical, WorkbenchSpacing.sm)
                        if index < summary.tasks.count - 1 {
                            Divider().padding(.leading, WorkbenchSpacing.md)
                        }
                    }
                }

                if summary.badLineCount > 0
                    || summary.metadataMissingCount > 0
                    || summary.metadataMalformedCount > 0
                {
                    Divider()
                    Label(
                        "部分 session metadata 或 JSON 行不完整，异常记录被单独保留；未展示聊天正文。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, WorkbenchSpacing.md)
                    .padding(.vertical, WorkbenchSpacing.sm)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ThreadAttributionTaskRow: View {
    let task: AccountThreadAttributionTask

    var body: some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
            Image(systemName: task.childTaskCount > 0 ? "arrow.triangle.branch" : "bubble.left")
                .foregroundStyle(task.childShareAbnormal ? .orange : Color.accentColor)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: WorkbenchSpacing.xs) {
                    Text(shortThreadID(task.threadID))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    if task.status != "top_level" {
                        StatusChip(task.statusLabel, color: .orange)
                    }
                    if task.childShareAbnormal || task.fullContextForkRisk {
                        StatusChip("需展开查看", color: .orange, systemImage: "exclamationmark.triangle")
                    }
                }
                Text(summaryLine)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: WorkbenchSpacing.sm)
            VStack(alignment: .trailing, spacing: 3) {
                Text(TokenCountFormatter.chinese(task.mergedTokens.totalTokens))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Text("合并总量")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shortThreadID(task.threadID))，\(summaryLine)，合并总量 \(TokenCountFormatter.accessibility(task.mergedTokens.totalTokens))")
    }

    private var summaryLine: String {
        var parts = [
            "子任务 \(task.childTaskCount)",
            "fork \(task.forkChildCount)",
        ]
        if task.childTaskCount > 0 {
            parts.append("子任务占比 \(Int((task.childShare * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
    }
}

private struct ThreadAttributionDetails: View {
    let task: AccountThreadAttributionTask

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            ThreadTokenBreakdown(title: "父任务自身", usage: task.ownTokens)
            ThreadTokenBreakdown(title: "归属子任务", usage: task.childTokens)
            ThreadTokenBreakdown(title: "合并总量", usage: task.mergedTokens)

            if !task.children.isEmpty {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    Text("子任务明细")
                        .font(.system(size: 10, weight: .semibold))
                    ForEach(task.children) { child in
                        HStack(spacing: WorkbenchSpacing.xs) {
                            Image(systemName: child.relation == "fork" ? "arrow.triangle.branch" : "arrow.turn.down.right")
                                .foregroundStyle(child.relation == "fork" ? .orange : .secondary)
                                .frame(width: 16)
                            Text(shortThreadID(child.threadID))
                                .font(.system(size: 10, design: .monospaced))
                            Text(child.relation == "fork" ? "fork" : "子任务")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text("深度 \(child.depth)")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: WorkbenchSpacing.xs)
                            Text(TokenCountFormatter.chinese(child.tokens.totalTokens))
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .lineLimit(1)
                    }
                }
            }

            if !task.riskMessages.isEmpty {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    Text("风险说明")
                        .font(.system(size: 10, weight: .semibold))
                    ForEach(task.riskMessages, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.leading, 30)
        .padding(.bottom, WorkbenchSpacing.xs)
    }
}

private struct ThreadTokenBreakdown: View {
    let title: String
    let usage: AccountThreadTokenUsage

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 92), alignment: .leading)],
                alignment: .leading,
                spacing: WorkbenchSpacing.xs
            ) {
                value("总量", usage.totalTokens)
                value("输入", usage.inputTokens)
                value("缓存输入", usage.cachedInputTokens)
                value("非缓存输入", usage.nonCachedInputTokens)
                value("输出", usage.outputTokens)
                value("reasoning", usage.reasoningOutputTokens)
            }
        }
    }

    private func value(_ title: String, _ number: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text(TokenCountFormatter.chinese(number))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
        .help(TokenCountFormatter.accessibility(number))
    }
}

private func shortThreadID(_ value: String) -> String {
    if value.hasPrefix("unresolved:") {
        return "未识别 rollout"
    }
    return "任务 …\(value.suffix(8))"
}

private struct WorkspaceThreadRow: View {
    let thread: WorkspaceThreadPresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                Image(systemName: thread.sourceThreadID == nil ? "bubble.left" : "arrow.triangle.branch")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: WorkbenchSpacing.xs) {
                        Text(thread.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if thread.hasContextSummary {
                            StatusChip("有摘要", color: .indigo, systemImage: "doc.text.fill")
                        }
                    }
                    if let sourceTitle = thread.sourceThreadTitle {
                        Text("接续自：\(sourceTitle)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let topic = thread.contextTopic {
                        Text(topic)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: WorkbenchSpacing.sm)
                Text(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, WorkbenchSpacing.md)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            thread.sourceThreadTitle.map { "\(thread.title)，接续自 \($0)" }
                ?? thread.title
        )
        .accessibilityHint("在 Codex 中打开这个任务")
    }
}

private struct ProjectRankingRow: View {
    let rank: Int
    let project: AccountProjectRankingItem
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: WorkbenchSpacing.sm) {
            Text("\(rank)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(project.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: WorkbenchSpacing.lg) {
                ProjectValue(title: "对话", value: "\(project.threadCount)")
                ProjectValue(
                    title: "Tokens",
                    value: TokenCountFormatter.chinese(project.tokensUsed),
                    width: 84,
                    alignment: .trailing,
                    spokenDetail: TokenCountFormatter.accessibility(project.tokensUsed)
                )
                ProjectValue(title: "最近活动", value: updatedText)
                    .frame(width: 120, alignment: .leading)
            }
        }
        .padding(.horizontal, WorkbenchSpacing.md)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: WorkbenchRadius.row, style: .continuous)
                .fill(Color.workbenchHairline.opacity(isHovered ? 0.55 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }

    private var updatedText: String {
        guard project.latestUpdatedAt > 0 else { return "--" }
        let raw = Double(project.latestUpdatedAt)
        let seconds = raw > 10_000_000_000 ? raw / 1_000 : raw
        return Date(timeIntervalSince1970: seconds).formatted(date: .numeric, time: .omitted)
    }
}

private struct ProjectValue: View {
    let title: String
    let value: String
    var width: CGFloat = 64
    var alignment: HorizontalAlignment = .leading
    var spokenDetail: String? = nil

    private var content: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
        .frame(width: width, alignment: alignment == .trailing ? .trailing : .leading)
    }

    @ViewBuilder
    var body: some View {
        if let spokenDetail {
            content
                .help(spokenDetail)
                .accessibilityLabel("\(title)：\(spokenDetail)")
        } else {
            content
        }
    }
}

struct InsightSummaryTile: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        }
    }
}

struct InsightsLoadingState: View {
    let message: String

    var body: some View {
        SurfaceCard {
            HStack(spacing: WorkbenchSpacing.sm) {
                ProgressView().controlSize(.small)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
        }
    }
}

struct InsightsUnavailableState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        SurfaceCard {
            QuietEmptyState(systemImage: systemImage, title: title, message: message)
                .frame(maxWidth: .infinity)
        }
    }
}

struct InsightsNotice: View {
    let message: String

    var body: some View {
        SurfaceCard {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
