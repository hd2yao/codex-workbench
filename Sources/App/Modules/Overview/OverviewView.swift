import CodexWorkbenchCore
import SwiftUI

struct OverviewView: View {
    @ObservedObject var model: WorkbenchAppModel

    private var recentEvents: [OperationEvent] {
        Array(
            model.events.filter {
                $0.importance == .critical || $0.importance == .important
            }
            .prefix(7)
        )
    }

    private var hasAttention: Bool {
        model.attentionCount > 0
            || model.accountError != nil
            || !model.ledgerWarnings.isEmpty
            || model.desktopClientSelection.status != .selected
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                PageHeader(
                    title: "运行概览",
                    description: "桌面客户端、账号角色、事件与数据新鲜度。",
                    trailing: AnyView(lastUpdatedView)
                )

                OverviewStatusBoard(model: model)

                if hasAttention {
                    OverviewAttentionPanel(model: model)
                }

                GroupedPanel {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionTitle("最近活动", detail: "跨全部任务")
                            .padding(.horizontal, WorkbenchSpacing.md)
                            .padding(.vertical, WorkbenchSpacing.sm)
                        Divider()
                        if recentEvents.isEmpty {
                            QuietEmptyState(
                                systemImage: "clock.badge.questionmark",
                                title: "还没有操作事件",
                                message: "刷新后会从任务台账、上下文摘要和账号状态中补录可证实的事件。"
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            ForEach(
                                Array(recentEvents.enumerated()),
                                id: \.element.id
                            ) { index, event in
                                CompactEventRow(event: event) {
                                    model.selectedEventID = event.id
                                    model.selectedModule = .activity
                                }
                                if index < recentEvents.count - 1 {
                                    Divider().padding(.leading, 54)
                                }
                            }
                        }
                    }
                }

                EvidenceCoveragePanel(model: model)
            }
            .padding(.horizontal, WorkbenchSpacing.lg)
            .padding(.vertical, WorkbenchSpacing.lg)
            .frame(maxWidth: 1_180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("overview-page")
    }

    private var lastUpdatedView: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("最后更新")
                .font(
                    .system(
                        size: WorkbenchInterfaceContract.microSize,
                        weight: .medium
                    )
                )
                .foregroundStyle(.tertiary)
            Text(
                model.lastUpdated?
                    .formatted(date: .omitted, time: .shortened)
                    ?? "正在读取"
            )
            .font(
                .system(
                    size: WorkbenchInterfaceContract.captionSize,
                    weight: .medium,
                    design: .monospaced
                )
            )
            .foregroundStyle(.secondary)
        }
    }
}

private struct OverviewStatusBoard: View {
    @ObservedObject var model: WorkbenchAppModel

    var body: some View {
        GroupedPanel {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle("状态板", detail: "来源独立，不互相回退")
                    .padding(.horizontal, WorkbenchSpacing.md)
                    .padding(.vertical, WorkbenchSpacing.sm)
                Divider()
                statusRow(
                    systemImage: "rectangle.on.rectangle",
                    title: "桌面客户端",
                    detail: model.desktopClientIdentityDetail,
                    value: model.desktopClientDisplayName,
                    color: model.desktopClientTarget?.isRunning == true
                        ? .green
                        : .secondary
                )
                rowDivider
                statusRow(
                    systemImage: model.runtimePresentation.symbol,
                    title: "任务运行",
                    detail: model.runtimePresentation.detail,
                    value: model.runtimePresentation.label,
                    color: runtimeColor
                )
                rowDivider
                roleRow(
                    systemImage: "person.crop.circle",
                    title: "桌面默认账号",
                    role: model.accountPayload?.profileRoles?.desktop,
                    fallback: model.currentProfileName
                )
                rowDivider
                roleRow(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "当前任务账号",
                    role: model.accountPayload?.profileRoles?.task
                )
                rowDivider
                roleRow(
                    systemImage: "chart.bar.xaxis",
                    title: "统计归因",
                    role: model.accountPayload?.profileRoles?.attribution
                )
                rowDivider
                statusRow(
                    systemImage: "clock",
                    title: "今日重要事件",
                    detail: "关键与重要操作",
                    value: String(model.todayImportantEventCount),
                    color: .secondary
                )
                rowDivider
                statusRow(
                    systemImage: "externaldrive.badge.checkmark",
                    title: "数据新鲜度",
                    detail: model.dataHealthPresentation.detail,
                    value: model.dataHealthPresentation.label,
                    color: dataHealthColor
                )
            }
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 42)
    }

    private func statusRow(
        systemImage: String,
        title: String,
        detail: String,
        value: String,
        color: Color
    ) -> some View {
        AdaptiveLabelValueRow {
            HStack(spacing: WorkbenchSpacing.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(
                            .system(
                                size: WorkbenchInterfaceContract.bodySize,
                                weight: .medium
                            )
                        )
                    Text(detail)
                        .font(
                            .system(size: WorkbenchInterfaceContract.microSize)
                        )
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        } trailing: {
            StatusChip(value, color: color)
        }
    }

    private func roleRow(
        systemImage: String,
        title: String,
        role: AccountRole?,
        fallback: String? = nil
    ) -> some View {
        let profile = role?.profile ?? fallback
        let confidence = role?.confidence ?? .unknown
        return AdaptiveLabelValueRow {
            HStack(spacing: WorkbenchSpacing.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(
                            .system(
                                size: WorkbenchInterfaceContract.bodySize,
                                weight: .medium
                            )
                        )
                    Text(role?.source ?? "没有可靠来源")
                        .font(
                            .system(size: WorkbenchInterfaceContract.microSize)
                        )
                        .foregroundStyle(.tertiary)
                }
            }
        } trailing: {
            HStack(spacing: WorkbenchSpacing.xs) {
                Text(
                    AccountPresentationBuilder.profileDisplayName(profile)
                )
                .font(
                    .system(
                        size: WorkbenchInterfaceContract.captionSize,
                        weight: .medium
                    )
                )
                .lineLimit(1)
                .truncationMode(.middle)
                StatusChip(
                    confidence.displayName,
                    color: confidence == .inferred ? .orange : .secondary
                )
            }
        }
    }

    private var runtimeColor: Color {
        switch model.runtimePresentation.state {
        case "running": .green
        case "waiting": .orange
        default: .secondary
        }
    }

    private var dataHealthColor: Color {
        switch model.dataHealthPresentation.level {
        case .healthy: .green
        case .degraded: .orange
        case .unavailable: .red
        }
    }
}

private struct OverviewAttentionPanel: View {
    @ObservedObject var model: WorkbenchAppModel

    var body: some View {
        GroupedPanel {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle("需要关注")
                    .padding(.horizontal, WorkbenchSpacing.md)
                    .padding(.vertical, WorkbenchSpacing.sm)
                Divider()
                if model.desktopClientSelection.status != .selected {
                    attentionRow(
                        title: "桌面客户端无法安全选择",
                        detail: model.desktopClientUnavailableReason
                            ?? "请打开诊断查看运行实例",
                        button: "查看账号",
                        module: .accounts
                    )
                }
                if let error = model.accountError {
                    attentionRow(
                        title: "账号数据已降级",
                        detail: error,
                        button: "查看账号",
                        module: .accounts
                    )
                }
                if !model.ledgerWarnings.isEmpty {
                    attentionRow(
                        title: "证据读取有警告",
                        detail: model.ledgerWarnings[0],
                        button: "查看日志",
                        module: .activity
                    )
                }
                if model.attentionCount > 0 {
                    attentionRow(
                        title: "\(model.attentionCount) 条事件需要复核",
                        detail: "失败、账号、额度或推断事件",
                        button: "打开日志",
                        module: .activity
                    )
                }
            }
        }
    }

    private func attentionRow(
        title: String,
        detail: String,
        button: String,
        module: AppModule
    ) -> some View {
        AdaptiveLabelValueRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(
                        .system(
                            size: WorkbenchInterfaceContract.bodySize,
                            weight: .medium
                        )
                    )
                Text(detail)
                    .font(
                        .system(size: WorkbenchInterfaceContract.microSize)
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } trailing: {
            Button(button) {
                model.selectedModule = module
            }
            .controlSize(.small)
        }
    }
}

struct CompactEventRow: View {
    let event: OperationEvent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                Image(systemName: event.category.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(event.category.color)
                    .frame(width: 30, height: 30)
                    .background(
                        event.category.color.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(
                            .system(
                                size: WorkbenchInterfaceContract.bodySize,
                                weight: .medium
                            )
                        )
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(event.summary)
                        .font(
                            .system(size: WorkbenchInterfaceContract.microSize)
                        )
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    HStack(spacing: WorkbenchSpacing.xs) {
                        Text(event.project?.name ?? "无项目")
                        Text("·")
                        Text(event.thread?.title ?? "无关联任务")
                        Text("·")
                        Text(event.status.displayName)
                        Text("·")
                        Text(event.certainty.displayName)
                    }
                    .font(
                        .system(size: WorkbenchInterfaceContract.microSize)
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: WorkbenchSpacing.md)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(
                        event.occurredAt.formatted(
                            date: .omitted,
                            time: .shortened
                        )
                    )
                    .font(
                        .system(
                            size: WorkbenchInterfaceContract.microSize,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(.secondary)
                    Text(event.actor.label)
                        .font(
                            .system(size: WorkbenchInterfaceContract.microSize)
                        )
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, WorkbenchSpacing.md)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(event.title)，\(event.status.displayName)，\(event.certainty.displayName)，\(event.actor.label)"
        )
    }
}

private struct EvidenceCoveragePanel: View {
    @ObservedObject var model: WorkbenchAppModel

    var body: some View {
        GroupedPanel {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle("证据覆盖")
                    .padding(.horizontal, WorkbenchSpacing.md)
                    .padding(.vertical, WorkbenchSpacing.sm)
                Divider()
                EvidenceFactLine(
                    title: "任务目录",
                    detail: "\(model.workspaceCatalog.recentThreads.count) 个真实任务"
                )
                Divider().padding(.leading, 42)
                EvidenceFactLine(
                    title: "上下文摘要",
                    detail: "\(model.workspaceCatalog.contextSummaryCount) 个任务有摘要"
                )
                Divider().padding(.leading, 42)
                EvidenceFactLine(
                    title: "工作流文件",
                    detail: "\(model.workspaceCatalog.workflows.hooks.count) 个 Hook · \(model.workspaceCatalog.workflows.automations.count) 个自动化"
                )
                if !model.ledgerWarnings.isEmpty {
                    Divider().padding(.leading, 42)
                    ForEach(
                        Array(model.ledgerWarnings.prefix(3).enumerated()),
                        id: \.offset
                    ) { _, warning in
                        Label(
                            warning,
                            systemImage: "exclamationmark.circle.fill"
                        )
                        .font(
                            .system(size: WorkbenchInterfaceContract.microSize)
                        )
                        .foregroundStyle(Color.orange)
                        .lineLimit(2)
                        .padding(.horizontal, WorkbenchSpacing.md)
                        .padding(.vertical, WorkbenchSpacing.xs)
                    }
                }
            }
        }
    }
}

private struct EvidenceFactLine: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(
                    .system(
                        size: WorkbenchInterfaceContract.captionSize,
                        weight: .medium
                    )
                )
            Spacer()
            Text(detail)
                .font(
                    .system(size: WorkbenchInterfaceContract.microSize)
                )
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, WorkbenchSpacing.md)
        .padding(.vertical, 10)
    }
}
