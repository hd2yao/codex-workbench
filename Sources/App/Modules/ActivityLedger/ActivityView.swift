import AppKit
import CodexWorkbenchCore
import SwiftUI

struct ActivityView: View {
    @ObservedObject var model: WorkbenchAppModel

    var body: some View {
        activityContent
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                PageHeader(
                    eyebrow: "Activity",
                    title: "操作日志",
                    description: "最新变化在上。项目、对话、触发来源和判断依据都可定位。"
                )
                ActivityFilterBar(model: model)
            }
            .padding(.horizontal, WorkbenchSpacing.lg)
            .padding(.top, WorkbenchSpacing.lg)
            .padding(.bottom, WorkbenchSpacing.md)

            GeometryReader { proxy in
                if proxy.size.width >= 1_040 {
                    HStack(spacing: 0) {
                        ActivityList(model: model, expandsSelection: false)
                            .frame(minWidth: 610, maxWidth: .infinity)
                        Divider()
                        Group {
                            if let event = model.selectedEvent {
                                ActivityInspector(event: event)
                            } else {
                                QuietEmptyState(
                                    systemImage: "sidebar.right",
                                    title: "选择一条操作",
                                    message: "这里会显示具体改动、关联对话、来源链和技术证据。"
                                )
                            }
                        }
                        .frame(width: 350)
                        .background(Color.workbenchCard.opacity(0.45))
                    }
                } else {
                    ActivityList(model: model, expandsSelection: true)
                }
            }
        }
        .background(Color.workbenchWindow)
        .accessibilityIdentifier("activity-page")
    }
}

private struct ActivityFilterBar: View {
    @ObservedObject var model: WorkbenchAppModel

    var body: some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            HStack(spacing: WorkbenchSpacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("搜索动作、任务、来源或账号", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("搜索操作日志")
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 260, maxWidth: 460, minHeight: 30)
            .background(Color.workbenchCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.workbenchBorder.opacity(0.65), lineWidth: 0.5)
            )

            Picker("级别", selection: $model.importanceFilter) {
                Text("全部级别").tag(Optional<EventImportance>.none)
                Text("关键").tag(Optional(EventImportance.critical))
                Text("重要").tag(Optional(EventImportance.important))
                Text("常规").tag(Optional(EventImportance.routine))
                Text("诊断").tag(Optional(EventImportance.diagnostic))
            }
            .labelsHidden()
            .frame(width: 105)

            Picker("来源", selection: $model.actorFilter) {
                Text("全部来源").tag(Optional<EventActorType>.none)
                ForEach(EventActorType.allCases.filter { $0 != .unknown }, id: \.self) { type in
                    Text(type.displayName).tag(Optional(type))
                }
            }
            .labelsHidden()
            .frame(width: 115)

            Picker("状态", selection: $model.statusFilter) {
                Text("全部状态").tag(Optional<EventStatus>.none)
                ForEach(EventStatus.allCases.filter { $0 != .unknown }, id: \.self) { status in
                    Text(status.displayName).tag(Optional(status))
                }
            }
            .labelsHidden()
            .frame(width: 105)

            Spacer(minLength: 0)

            Text("\(model.filteredEvents.count) 条")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ActivityList: View {
    @ObservedObject var model: WorkbenchAppModel
    let expandsSelection: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sections: [ActivityDaySection] {
        ActivityGrouper.sections(for: model.filteredEvents)
    }

    var body: some View {
        Group {
            if model.filteredEvents.isEmpty {
                QuietEmptyState(
                    systemImage: model.events.isEmpty ? "clock.badge.questionmark" : "line.3.horizontal.decrease.circle",
                    title: model.events.isEmpty ? "还没有操作事件" : "没有匹配结果",
                    message: model.events.isEmpty
                        ? "刷新后会从本地证据补录可确认的操作。"
                        : "尝试清除搜索或放宽筛选条件。"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.events) { event in
                                    ActivityTimelineRow(
                                        event: event,
                                        isSelected: model.selectedEventID == event.id,
                                        showsInlineDetails: expandsSelection && model.selectedEventID == event.id
                                    ) {
                                        if reduceMotion {
                                            model.selectEvent(event)
                                        } else {
                                            withAnimation(.easeOut(duration: 0.14)) {
                                                model.selectEvent(event)
                                            }
                                        }
                                    }
                                }
                            } header: {
                                ActivityDateHeader(day: section.day, count: section.events.count)
                            }
                        }
                    }
                    .padding(.horizontal, WorkbenchSpacing.lg)
                    .padding(.bottom, WorkbenchSpacing.lg)
                }
            }
        }
    }
}

private struct ActivityDateHeader: View {
    let day: Date
    let count: Int

    var body: some View {
        HStack {
            Text(dayTitle)
                .font(.system(size: 11, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, WorkbenchSpacing.sm)
        .padding(.bottom, WorkbenchSpacing.xs)
        .background(Color.workbenchWindow.opacity(0.96))
    }

    private var dayTitle: String {
        if Calendar.current.isDateInToday(day) { return "今天" }
        if Calendar.current.isDateInYesterday(day) { return "昨天" }
        return day.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN")))
    }
}

private struct ActivityTimelineRow: View {
    let event: OperationEvent
    let isSelected: Bool
    let showsInlineDetails: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                    Text(event.occurredAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                        .padding(.top, 2)

                    VStack(spacing: 0) {
                        ZStack {
                            Circle()
                                .fill(event.importance.color.opacity(event.importance == .routine ? 0.08 : 0.14))
                                .frame(width: event.importance.markerSize, height: event.importance.markerSize)
                            Circle()
                                .stroke(event.importance.color.opacity(0.22), lineWidth: 0.5)
                                .frame(width: event.importance.markerSize, height: event.importance.markerSize)
                            Image(systemName: event.category.systemImage)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(event.importance == .routine ? Color.secondary : event.category.color)
                        }
                        Rectangle()
                            .fill(Color.workbenchBorder.opacity(event.importance == .routine ? 0.35 : 0.62))
                            .frame(width: 1, height: 66)
                    }
                    .frame(width: 24)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: WorkbenchSpacing.xs) {
                            Text(event.title)
                                .font(.system(size: event.importance == .diagnostic ? 11 : 12, weight: event.importance.titleWeight))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: WorkbenchSpacing.sm)
                            if event.importance != .routine {
                                StatusChip(event.importance.displayName, color: event.importance.color)
                            }
                            StatusChip(event.status.displayName, color: event.status.color)
                        }
                        Text(event.summary)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        ActivityScopeLine(event: event)
                        HStack(spacing: 6) {
                            Label(event.actor.label, systemImage: "bolt.horizontal.circle")
                            Text("·")
                            Text(event.certainty.displayName)
                                .foregroundStyle(event.certainty.color)
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, WorkbenchSpacing.sm)
                .padding(.top, 11)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(accessibilitySummary)
            .accessibilityValue(accessibilitySummary)
            .accessibilityHint(showsInlineDetails ? "收起事件详情" : "显示事件详情")
            .buttonStyle(.plain)

            if showsInlineDetails {
                Divider().padding(.leading, 78)
                ActivityInspector(event: event, inline: true)
                    .padding(.leading, 78)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color.workbenchSelection : (isHovering ? Color.primary.opacity(0.035) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.28) : .clear, lineWidth: 0.5)
        )
        .onHover { isHovering = $0 }
    }

    private var accessibilitySummary: String {
        let changes = event.changes?.prefix(2).map(\.summary).joined(separator: "；")
        let source = event.relatedThreads?.first { $0.role == .modificationSource }
        return [
            event.title,
            event.status.displayName,
            changes,
            source?.title.map { "修改来源对话 \($0)" },
            "来源 \(event.actor.label)",
            event.certainty.displayName,
        ]
        .compactMap { $0 }
        .joined(separator: "，")
    }
}

private struct ActivityScopeLine: View {
    let event: OperationEvent

    var body: some View {
        if event.scope != nil || event.project != nil || event.thread != nil || event.account != nil {
            HStack(spacing: 6) {
                if event.scope == .globalWorkflow {
                    ScopePill(text: "全局工作流", systemImage: "globe")
                }
                if let project = event.project {
                    ScopePill(
                        text: project.name ?? project.path ?? "未知项目",
                        systemImage: "folder"
                    )
                }
                if let thread = event.thread {
                    ScopePill(
                        text: thread.title ?? compactID(thread.id) ?? "未命名对话",
                        systemImage: "bubble.left"
                    )
                }
                if let account = event.account {
                    ScopePill(
                        text: account.profile ?? account.label ?? "全局账号",
                        systemImage: "person.crop.circle"
                    )
                }
                if event.account != nil, event.project == nil, event.thread == nil {
                    ScopePill(text: "全局事件", systemImage: "globe")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func compactID(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return "对话 …\(id.suffix(8))"
    }
}

private struct ScopePill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct ActivityInspector: View {
    let event: OperationEvent
    var inline = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    HStack {
                        Image(systemName: event.category.systemImage)
                            .foregroundStyle(event.category.color)
                        Text(event.category.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(event.category.color)
                        Spacer()
                        StatusChip(event.importance.displayName, color: event.importance.color)
                    }
                    Text(event.title)
                        .font(.system(size: inline ? 15 : 17, weight: .semibold))
                    Text(event.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(event.occurredAt.formatted(date: .abbreviated, time: .standard))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    HStack(spacing: WorkbenchSpacing.xs) {
                        StatusChip(event.certainty.displayName, color: event.certainty.color)
                        Text(event.certainty.explanation)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }

                if let changes = event.changes, !changes.isEmpty {
                    InspectorSection(title: event.action == "context_compacted" ? "压缩后摘要" : "本次改动") {
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                                EventChangeRow(change: change)
                            }
                        }
                    }
                }

                if event.scope != nil
                    || event.thread != nil
                    || event.project != nil
                    || event.account != nil
                    || event.relatedThreads?.isEmpty == false {
                    InspectorSection(title: "归属与关联") {
                        if event.scope == .globalWorkflow {
                            InspectorValue(label: "作用域", value: "全局工作流")
                        }
                        if let project = event.project {
                            InspectorValue(label: "来源项目", value: project.name ?? "未知项目")
                            if let path = project.path {
                                InspectorValue(label: "项目路径", value: path, monospaced: true)
                            }
                        }
                        if let thread = event.thread {
                            InspectorValue(
                                label: isWorkflowChange ? "修改来源对话" : "对话",
                                value: thread.title ?? "未命名对话"
                            )
                            if !isWorkflowChange {
                                InspectorValue(label: "关系", value: thread.relation.displayName)
                            }
                            if let threadID = thread.id {
                                InspectorValue(label: "对话 ID", value: threadID, monospaced: true)
                            }
                            if let threadID = thread.id,
                               CodexIntegration.threadURL(for: threadID) != nil {
                                Button {
                                    CodexIntegrationService.openThread(threadID)
                                } label: {
                                    Label("在 Codex 中打开对话", systemImage: "arrow.up.forward.app")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        } else if isWorkflowChange {
                            InspectorValue(label: "修改来源对话", value: "未定位到唯一对话")
                        }
                        ForEach(deliveryTargets, id: \.id) { related in
                            RelatedThreadView(
                                label: "投递目标对话",
                                thread: related
                            )
                        }
                        if let account = event.account {
                            InspectorValue(label: "账号", value: account.profile ?? account.label ?? "全局账号")
                        }
                    }
                }

                InspectorSection(title: "来源") {
                    InspectorValue(label: "主体", value: "\(event.actor.type.displayName) · \(event.actor.label)")
                    InspectorValue(label: "事件", value: event.action, monospaced: true)
                    ForEach(Array(event.sourceChain.enumerated()), id: \.offset) { index, actor in
                        InspectorValue(label: index == 0 ? "来源链" : "", value: "\(index + 1). \(actor.label)")
                    }
                }

                if event.before != nil || event.after != nil, !isWorkflowChange {
                    InspectorSection(title: "状态变化") {
                        if let before = event.before {
                            InspectorValue(label: "之前", value: before.displayText)
                        }
                        if let after = event.after {
                            InspectorValue(label: "之后", value: after.displayText)
                        }
                    }
                }

                if event.before != nil || event.after != nil, isWorkflowChange {
                    DisclosureGroup("技术状态") {
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                            if let before = event.before {
                                InspectorValue(label: "之前", value: before.displayText)
                            }
                            if let after = event.after {
                                InspectorValue(label: "之后", value: after.displayText)
                            }
                        }
                        .padding(.top, WorkbenchSpacing.xs)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                }

                if !event.evidence.isEmpty {
                    InspectorSection(title: "证据") {
                        ForEach(Array(event.evidence.enumerated()), id: \.offset) { _, evidence in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(evidence.label)
                                    .font(.system(size: 10, weight: .medium))
                                if let path = evidence.path {
                                    Text(path)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                    if evidence.kind == "context_card" {
                                        Button {
                                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                        } label: {
                                            Label("打开完整摘要卡片", systemImage: "doc.text.magnifyingglass")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityHint("使用默认应用打开 PreCompact 生成的完整上下文摘要卡片")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(inline ? WorkbenchSpacing.md : WorkbenchSpacing.lg)
        }
    }

    private var isWorkflowChange: Bool {
        event.scope == .globalWorkflow
    }

    private var deliveryTargets: [EventRelatedThread] {
        event.relatedThreads?.filter { $0.role == .deliveryTarget } ?? []
    }
}

private struct EventChangeRow: View {
    let change: EventChange

    var body: some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isEvidenceBoundary ? tint : .primary)
                Text(change.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if change.before != nil || change.after != nil {
                    Text(changeTransition)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WorkbenchSpacing.xs)
        .background(tint.opacity(isEvidenceBoundary ? 0.075 : 0.055), in: RoundedRectangle(cornerRadius: 7))
    }

    private var isEvidenceBoundary: Bool {
        change.label == "证据边界"
    }

    private var tint: Color {
        isEvidenceBoundary ? .orange : .accentColor
    }

    private var changeTransition: String {
        [change.before ?? "—", change.after ?? "—"].joined(separator: " → ")
    }
}

private struct RelatedThreadView: View {
    let label: String
    let thread: EventRelatedThread

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            InspectorValue(label: label, value: thread.title ?? "未命名对话")
            if let projectName = thread.projectName {
                InspectorValue(label: "目标项目", value: projectName)
            }
            InspectorValue(label: "对话 ID", value: thread.id, monospaced: true)
            if CodexIntegration.threadURL(for: thread.id) != nil {
                Button {
                    CodexIntegrationService.openThread(thread.id)
                } label: {
                    Label("打开投递目标对话", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorValue: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
