import CodexWorkbenchCore
import SwiftUI

struct ToolsSkillsView: View {
    @ObservedObject var model: WorkbenchAppModel
    @State private var assetCategory: WorkflowAssetCategory = .all
    @State private var searchText = ""

    private var insights: WorkspaceInsightsPresentation {
        AccountPresentationBuilder.workspaceInsights(payload: model.accountPayload)
    }

    private var assets: [WorkflowItemPresentation] {
        let categoryMatches = model.workspaceCatalog.workflows.assets.filter {
            assetCategory.matches($0.kind)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return categoryMatches }
        return categoryMatches.filter { asset in
            [
                asset.name,
                asset.purpose,
                asset.status,
                asset.schedule,
                asset.kind.title,
                asset.source.title,
                asset.copyState.title,
            ]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                PageHeader(
                    eyebrow: "Tools & Skills",
                    title: "工具与自动化",
                    description: "查看近期任务涉及的动态工具，以及本机已配置的规则、Skills、Hooks、自动化与扩展。",
                    trailing: AnyView(
                        Button("刷新") { Task { await model.refreshAll() } }
                            .disabled(model.isRefreshing)
                    )
                )

                if let error = model.accountError {
                    InsightsNotice(message: error)
                }

                rankingPanel(
                    title: "最近涉及的工具",
                    detail: insights.toolsAvailable ? "\(insights.tools.count) 项" : "数据源不可用",
                    available: insights.toolsAvailable,
                    isEmpty: insights.tools.isEmpty,
                    emptyMessage: "近期任务没有可靠的动态工具关联"
                ) {
                    ForEach(Array(insights.tools.enumerated()), id: \.element.id) { index, tool in
                        ToolRankingRow(rank: index + 1, tool: tool)
                        if index < insights.tools.count - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }

                workflowAssetPanel

                SurfaceCard {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("统计口径")
                                .font(.system(size: 11, weight: .semibold))
                            Text("“最近涉及的工具”来自本地任务数据库，只表示工具与任务存在关联；工作流资产只表示文件存在及其配置状态，不会把 SKILL.md 读取推断为 Skill 的实际调用。页面不展示工作流文件正文。")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, WorkbenchSpacing.lg)
            .padding(.vertical, WorkbenchSpacing.lg)
            .frame(maxWidth: 1_180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("tools-skills-page")
    }

    private var workflowAssetPanel: some View {
        SurfaceCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(
                    "工作流资产",
                    detail: assetDetail
                )
                    .padding(.horizontal, WorkbenchSpacing.md)
                    .padding(.vertical, WorkbenchSpacing.sm)
                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.md) {
                        assetCategoryPicker
                        Spacer(minLength: WorkbenchSpacing.md)
                        assetSearchField
                    }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                        assetCategoryPicker
                        assetSearchField
                    }
                }
                .padding(WorkbenchSpacing.md)

                Divider()

                if assets.isEmpty {
                    QuietEmptyState(
                        systemImage: "tray",
                        title: "没有匹配的资产",
                        message: searchText.isEmpty
                            ? "本机工作流目录中没有识别到这一类配置。"
                            : "尝试更换分类或搜索词。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 116)
                } else {
                    ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                        WorkflowAssetRow(item: asset)
                        if index < assets.count - 1 {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
        }
    }

    private var assetCategoryPicker: some View {
        Picker("资产分类", selection: $assetCategory) {
            ForEach(WorkflowAssetCategory.allCases, id: \.self) { category in
                Text(category.title).tag(category)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 560)
        .accessibilityLabel("工作流资产分类")
    }

    private var assetSearchField: some View {
        TextField("搜索名称、用途或状态", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 230)
            .accessibilityLabel("搜索工作流资产")
    }

    private var assetDetail: String {
        let total = model.workspaceCatalog.workflows.assets.count
        if assetCategory == .all, searchText.isEmpty {
            return "\(total) 项"
        }
        return "\(assets.count) / \(total) 项"
    }

    @ViewBuilder
    private func rankingPanel<Content: View>(
        title: String,
        detail: String,
        available: Bool,
        isEmpty: Bool,
        emptyMessage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        SurfaceCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(title, detail: detail)
                    .padding(.horizontal, WorkbenchSpacing.md)
                    .padding(.vertical, WorkbenchSpacing.sm)
                Divider()
                if !available {
                    QuietEmptyState(
                        systemImage: "externaldrive.badge.questionmark",
                        title: "数据源不可用",
                        message: "本地 Codex 历史暂未提供可靠的工具关联。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 116)
                } else if isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 84)
                } else {
                    content()
                }
            }
        }
    }
}

private enum WorkflowAssetCategory: String, CaseIterable {
    case all
    case rules
    case skills
    case hooks
    case automations
    case extensions

    var title: String {
        switch self {
        case .all: "全部"
        case .rules: "规则"
        case .skills: "Skills"
        case .hooks: "Hooks"
        case .automations: "自动化"
        case .extensions: "扩展"
        }
    }

    func matches(_ kind: WorkflowFileKind) -> Bool {
        switch self {
        case .all: true
        case .rules: kind == .rule
        case .skills: kind == .skill
        case .hooks: kind == .hook
        case .automations: kind == .automation
        case .extensions: kind == .plugin || kind == .configuration
        }
    }
}

private struct WorkflowAssetRow: View {
    let item: WorkflowItemPresentation

    var body: some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
            Image(systemName: symbol)
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.kind.title)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                }
                Text(item.purpose ?? "未声明用途")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: WorkbenchSpacing.sm)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 5) {
                    AssetBadge(text: item.source.title)
                    AssetBadge(
                        text: item.copyState.title,
                        color: item.copyState == .mismatchedCopies ? .orange : .secondary
                    )
                }
                Text(statusAndSchedule)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("更新于 \(item.modifiedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, WorkbenchSpacing.md)
        .padding(.vertical, 10)
        .ledgerRowHover()
        .accessibilityElement(children: .combine)
    }

    private var statusAndSchedule: String {
        let status = item.status ?? "状态未声明"
        guard let schedule = item.schedule, !schedule.isEmpty else { return status }
        return "\(status) · \(schedule)"
    }

    private var symbol: String {
        switch item.kind {
        case .rule: "doc.text"
        case .skill: "sparkles.rectangle.stack"
        case .hook: "point.3.connected.trianglepath.dotted"
        case .automation: "clock.arrow.circlepath"
        case .plugin: "puzzlepiece.extension"
        case .configuration: "slider.horizontal.3"
        }
    }

    private var iconColor: Color {
        item.copyState == .mismatchedCopies ? .orange : .accentColor
    }
}

private struct AssetBadge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                color.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
    }
}

private struct ToolRankingRow: View {
    let rank: Int
    let tool: AccountToolRankingItem

    var body: some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            RankLabel(rank: rank)
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(tool.namespace.isEmpty ? "本地工具" : tool.namespace)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: WorkbenchSpacing.sm)
            RankedValue(title: "涉及任务", value: "\(tool.callCount)")
            RankedValue(
                title: "相关 Tokens",
                value: TokenCountFormatter.chinese(tool.threadTokens),
                spokenDetail: TokenCountFormatter.accessibility(tool.threadTokens)
            )
        }
        .padding(.horizontal, WorkbenchSpacing.md)
        .padding(.vertical, 9)
        .ledgerRowHover()
        .accessibilityElement(children: .combine)
    }
}

private struct RankLabel: View {
    let rank: Int

    var body: some View {
        Text("\(rank)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Color.workbenchWindow.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct RankedValue: View {
    let title: String
    let value: String
    var spokenDetail: String? = nil

    private var content: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .lineLimit(1)
        }
        .frame(minWidth: 84, alignment: .trailing)
    }

    @ViewBuilder
    var body: some View {
        if let spokenDetail {
            content
                .help(spokenDetail)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title)：\(spokenDetail)")
        } else {
            content
                .accessibilityElement(children: .combine)
        }
    }
}

private struct LedgerRowHover: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: WorkbenchRadius.row, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.04 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: WorkbenchRadius.row, style: .continuous)
                    .stroke(Color.workbenchHairline, lineWidth: 0.5)
                    .opacity(isHovered ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension View {
    fileprivate func ledgerRowHover() -> some View {
        modifier(LedgerRowHover())
    }
}
