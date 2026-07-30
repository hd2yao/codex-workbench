import AppKit
import CodexWorkbenchCore
import SwiftUI

struct ProjectServicesView: View {
    @ObservedObject var model: WorkbenchAppModel
    @State private var showingAddProject = false
    @State private var showingProjectStopConfirmation = false
    @State private var showingBrowserStopConfirmation = false
    @State private var showingProjectRemoveConfirmation = false
    @State private var showingDuplicatePruneConfirmation = false
    @State private var projectToStop: AccountManagedProject?
    @State private var projectToRemove: AccountManagedProject?
    @State private var browserToStop: AccountBrowserProcess?
    @State private var selectedRowID: String?

    private var managed: AccountManagedProjects? {
        model.managedProjects
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                PageHeader(
                    eyebrow: "Codex Runtime",
                    title: "项目服务",
                    description: "只查看 Codex 任务、工作台登记项目和可归因的自动化 Chrome；不扫描系统全量端口。",
                    trailing: AnyView(
                        Button {
                            showingAddProject = true
                        } label: {
                            Label("添加项目", systemImage: "plus")
                        }
                        .disabled(model.isProjectActionInFlight)
                    )
                )

                if let message = model.projectActionMessage {
                    InsightsNotice(message: message)
                }

                summary
                discoveredServices
                registeredProjects
                browserProcesses
                taskEvidence
            }
            .padding(.horizontal, WorkbenchSpacing.lg)
            .padding(.vertical, WorkbenchSpacing.lg)
            .frame(maxWidth: 1_180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("project-services-page")
        .sheet(isPresented: $showingAddProject) {
            AddProjectServiceSheet { name, cwd, command, port in
                model.addManagedProject(
                    name: name,
                    cwd: cwd,
                    command: command,
                    port: port
                )
            }
        }
        .confirmationDialog(
            "停止项目服务？",
            isPresented: $showingProjectStopConfirmation,
            presenting: projectToStop
        ) { project in
            Button("停止 \(project.name)", role: .destructive) {
                model.stopManagedProject(project.id)
                projectToStop = nil
            }
            Button("取消", role: .cancel) {
                projectToStop = nil
            }
        } message: { project in
            Text("仅向受管进程组发送 SIGTERM，不会强制结束其余系统进程。")
        }
        .confirmationDialog(
            "结束自动化 Chrome？",
            isPresented: $showingBrowserStopConfirmation,
            presenting: browserToStop
        ) { process in
            Button("结束 PID \(process.pid)", role: .destructive) {
                if let fingerprint = process.fingerprint {
                    model.stopManagedProcess(pid: process.pid, fingerprint: fingerprint)
                }
                browserToStop = nil
            }
            Button("取消", role: .cancel) {
                browserToStop = nil
            }
        } message: { _ in
            Text("只允许结束明确识别的 Playwright cliDaemon，不会关闭普通 Chrome 子进程。")
        }
        .confirmationDialog(
            "删除项目登记？",
            isPresented: $showingProjectRemoveConfirmation,
            presenting: projectToRemove
        ) { project in
            Button("删除 \(project.name) 的登记", role: .destructive) {
                model.removeManagedProject(project.id)
                projectToRemove = nil
            }
            Button("取消", role: .cancel) {
                projectToRemove = nil
            }
        } message: { project in
            Text("这只会移除工作台保存的启动定义，不会停止 PID \(project.pid.map(String.init) ?? "—")，也不会释放仍被其他进程占用的端口。")
        }
        .confirmationDialog(
            "清理完全重复的登记？",
            isPresented: $showingDuplicatePruneConfirmation
        ) {
            Button("清理重复登记", role: .destructive) {
                model.pruneDuplicateManagedProjects()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除目录、命令和端口完全相同的多余登记；不会停止任何服务或 Chrome。")
        }
    }

    private var summary: some View {
        let projects = managed?.projects ?? []
        let tasks = managed?.codexTasks ?? []
        let browsers = managed?.browserProcesses ?? []
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 170, maximum: 280), spacing: WorkbenchSpacing.sm)],
            spacing: WorkbenchSpacing.sm
        ) {
            InsightSummaryTile(
                title: "登记项目",
                value: "\(projects.count)",
                detail: "可在工作台启动/停止",
                systemImage: "shippingbox"
            )
            InsightSummaryTile(
                title: "Codex 任务",
                value: "\(tasks.count)",
                detail: "只读归因记录",
                systemImage: "list.bullet.rectangle"
            )
            InsightSummaryTile(
                title: "自动化 Chrome",
                value: "\(browsers.count)",
                detail: "Playwright 守护进程",
                systemImage: "globe"
            )
            InsightSummaryTile(
                title: "发现端口",
                value: "\(managed?.discoveredServices.count ?? 0)",
                detail: "可归因的 Codex 服务",
                systemImage: "dot.radiowaves.left.and.right"
            )
        }
    }

    @ViewBuilder
    private var discoveredServices: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(
                "发现的 Codex 端口",
                detail: "从任务目录、启动命令和实际监听交叉确认；不是系统全量端口"
            )
            if let services = managed?.discoveredServices, !services.isEmpty {
                GroupedPanel {
                    VStack(spacing: 0) {
                        ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                            DiscoveredServiceRow(
                                service: service,
                                isBusy: model.isProjectRegistrationPending(
                                    cwd: service.cwd,
                                    command: service.command,
                                    port: service.port
                                ),
                                isPendingRegistration: model.isProjectRegistrationPending(
                                    cwd: service.cwd,
                                    command: service.command,
                                    port: service.port
                                ),
                                isSelected: selectedRowID == "discovered:\(service.id)",
                                selectAction: {
                                    toggleSelection("discovered:\(service.id)")
                                    if service.canOpen == true {
                                        model.openManagedService(
                                            service.serviceURL ?? "http://127.0.0.1:\(service.port)",
                                            name: service.name,
                                            serviceID: "discovered:\(service.id)"
                                        )
                                    }
                                },
                                registerAction: {
                                    model.addManagedProject(
                                        name: service.name,
                                        cwd: service.cwd,
                                        command: service.command,
                                        port: service.port,
                                        adoptCurrent: service.portListening
                                    )
                                },
                                openAction: {
                                    model.openManagedService(
                                        service.serviceURL ?? "http://127.0.0.1:\(service.port)",
                                        name: service.name,
                                        serviceID: "discovered:\(service.id)"
                                    )
                                }
                            )
                            if index < services.count - 1 {
                                Divider().padding(.leading, WorkbenchSpacing.md)
                            }
                        }
                    }
                }
            } else {
                SurfaceCard {
                    QuietEmptyState(
                        systemImage: "dot.radiowaves.left.and.right",
                        title: "暂未发现新的 Codex 端口",
                        message: "刷新会自动读取 Codex 任务记录；普通系统服务和普通 Chrome 不会纳入。"
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var registeredProjects: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("工作台项目", detail: "登记项目才提供一键启动/停止")
                Spacer()
                if projectsContainExactDuplicates {
                    Button("清理重复登记", role: .destructive) {
                        showingDuplicatePruneConfirmation = true
                    }
                    .disabled(model.isProjectActionInFlight)
                }
            }
            if let projects = managed?.projects, !projects.isEmpty {
                GroupedPanel {
                    VStack(spacing: 0) {
                        ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                            ManagedProjectRow(
                                project: project,
                                isBusy: model.isProjectActionInFlight("project:\(project.id)"),
                                openMessage: model.serviceOpenMessages["project:\(project.id)"],
                                isSelected: selectedRowID == "project:\(project.id)",
                                selectAction: {
                                    toggleSelection("project:\(project.id)")
                                    if project.canOpen == true, let url = project.serviceURL {
                                        model.openManagedService(
                                            url,
                                            name: project.name,
                                            serviceID: "project:\(project.id)"
                                        )
                                    }
                                },
                                startAction: { model.startManagedProject(project.id) },
                                switchAction: { model.switchManagedProject(project.id) },
                                stopAction: {
                                    projectToStop = project
                                    showingProjectStopConfirmation = true
                                },
                                removeAction: {
                                    projectToRemove = project
                                    showingProjectRemoveConfirmation = true
                                },
                                openAction: {
                                    if let url = project.serviceURL {
                                        model.openManagedService(
                                            url,
                                            name: project.name,
                                            serviceID: "project:\(project.id)"
                                        )
                                    }
                                }
                            )
                            if index < projects.count - 1 {
                                Divider().padding(.leading, WorkbenchSpacing.md)
                            }
                        }
                    }
                }
            } else {
                SurfaceCard {
                    QuietEmptyState(
                        systemImage: "shippingbox",
                        title: "还没有登记项目服务",
                        message: "点击右上角“添加项目”，保存目录、启动命令和可选端口后即可复用。"
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var browserProcesses: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle("自动化 Chrome", detail: "仅显示可安全结束的 Playwright cliDaemon；它们没有可验证 URL")
            if let processes = managed?.browserProcesses, !processes.isEmpty {
                GroupedPanel {
                    VStack(spacing: 0) {
                        ForEach(Array(processes.prefix(12).enumerated()), id: \.element.id) { index, process in
                            BrowserProcessRow(
                                process: process,
                                isBusy: model.isProjectActionInFlight("browser:\(process.pid)"),
                                stopAction: {
                                    browserToStop = process
                                    showingBrowserStopConfirmation = true
                                }
                            )
                            if index < min(processes.count, 12) - 1 {
                                Divider().padding(.leading, WorkbenchSpacing.md)
                            }
                        }
                    }
                }
            } else {
                SurfaceCard {
                    QuietEmptyState(
                        systemImage: "globe",
                        title: "没有可归因的自动化 Chrome",
                        message: "普通 Chrome、Chrome Helper 和系统浏览器不会出现在这里。"
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var taskEvidence: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle("任务来源证据", detail: "解释端口来自哪个 Codex 任务；历史记录不等于当前进程")
            if let tasks = managed?.codexTasks, !tasks.isEmpty {
                GroupedPanel {
                    VStack(spacing: 0) {
                        ForEach(Array(tasks.prefix(20).enumerated()), id: \.element.id) { index, task in
                            CodexTaskServiceRow(
                                task: task,
                                isSelected: selectedRowID == "task:\(task.id)",
                                selectAction: {
                                    toggleSelection("task:\(task.id)")
                                }
                            )
                            if index < min(tasks.count, 20) - 1 {
                                Divider().padding(.leading, WorkbenchSpacing.md)
                            }
                        }
                    }
                }
            } else {
                SurfaceCard {
                        QuietEmptyState(
                        systemImage: "list.bullet.rectangle",
                        title: "没有任务来源证据",
                        message: "发现端口后，这里会显示它来自哪个任务，以及当前是否仍在监听。"
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var projectsContainExactDuplicates: Bool {
        managed?.projects.contains(where: { $0.state == "duplicate_registration" }) == true
    }

    private func toggleSelection(_ id: String) {
        selectedRowID = selectedRowID == id ? nil : id
    }

}

private struct DiscoveredServiceRow: View {
    let service: AccountDiscoveredService
    let isBusy: Bool
    let isPendingRegistration: Bool
    let isSelected: Bool
    let selectAction: () -> Void
    let registerAction: () -> Void
    let openAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                Button(action: selectAction) {
                    rowIdentity(
                        icon: service.portListening ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath",
                        iconColor: service.portListening ? .green : .secondary,
                        title: service.name,
                        stateLabel: service.stateLabel,
                        stateColor: service.portListening ? .green : .secondary,
                        subtitle: "端口 \(service.port) · \(service.portOwnerPid.map { "PID \($0)" } ?? "当前无占用进程")"
                    )
                }
                .buttonStyle(.plain)
                Spacer(minLength: WorkbenchSpacing.sm)
                if service.canOpen == true {
                    Button("打开服务", action: openAction)
                        .disabled(isBusy)
                }
                Button(isPendingRegistration ? "登记中…" : "登记", action: registerAction)
                    .disabled(isBusy || isPendingRegistration || !service.canRegister)
            }
            inlineDiagnosis(
                reason: service.reason,
                hint: service.actionHint,
                isWarning: !service.canRegister
            )
            if isSelected {
                details
            }
        }
        .padding(.horizontal, WorkbenchSpacing.md)
        .padding(.vertical, WorkbenchSpacing.sm)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 1) {
            detailLine("来源任务", service.sourceTaskIds.count == 1 ? "1 个任务" : "\(service.sourceTaskIds.count) 个任务")
            detailLine("项目目录", service.cwd)
            detailLine("启动命令", service.command)
            if let ownerCommand = service.portOwnerCommand {
                detailLine("当前占用进程", "PID \(service.portOwnerPid ?? 0) · \(ownerCommand)")
            }
            if service.portListening, service.serviceKind == "backend" {
                Text("这是后端服务：打开服务后可能显示 API 响应或文档，而不是网页界面。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 30)
        .padding(.bottom, WorkbenchSpacing.xs)
    }
}

private struct ManagedProjectRow: View {
    let project: AccountManagedProject
    let isBusy: Bool
    let openMessage: String?
    let isSelected: Bool
    let selectAction: () -> Void
    let startAction: () -> Void
    let switchAction: () -> Void
    let stopAction: () -> Void
    let removeAction: () -> Void
    let openAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                Button(action: selectAction) {
                    rowIdentity(
                        icon: project.canStop ? "play.rectangle.fill" : "shippingbox",
                        iconColor: projectStatusColor(project),
                        title: project.name,
                        stateLabel: project.stateLabel,
                        stateColor: projectStatusColor(project),
                        subtitle: "\(project.port.map { "端口 \($0)" } ?? "未登记端口") · \(project.pid.map { "PID \($0)" } ?? "无受管 PID")"
                    )
                }
                .buttonStyle(.plain)
                Spacer(minLength: WorkbenchSpacing.sm)
                if project.canOpen == true {
                    Button("打开服务", action: openAction)
                        .disabled(isBusy)
                }
                if project.canStop {
                    Button("停止", role: .destructive, action: stopAction)
                        .disabled(isBusy)
                } else if project.canSwitch == true {
                    Button("切换启动", action: switchAction)
                        .disabled(isBusy)
                } else {
                    Button("启动", action: startAction)
                        .disabled(isBusy || !project.canStart)
                }
                if project.canRemove != false {
                    Button("删除登记", role: .destructive, action: removeAction)
                        .disabled(isBusy)
                }
            }
            inlineDiagnosis(
                reason: project.reason ?? project.lastError ?? "正在读取项目状态。",
                hint: project.actionHint,
                isWarning: project.state != "running" && project.state != "stopped"
            )
            if let openMessage {
                Text(openMessage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(openMessage.hasPrefix("无法") ? Color.orange : Color.green)
            }
            if isSelected {
                VStack(alignment: .leading, spacing: 1) {
                    detailLine("项目目录", project.cwd)
                    detailLine("启动命令", project.command)
                    if let owner = project.portOwnerCommand {
                        detailLine("端口占用进程", "PID \(project.portOwnerPid ?? 0) · \(owner)")
                    }
                    if project.portListening, project.serviceKind == "backend" {
                        Text("这是后端服务：打开服务后可能显示 API 响应或文档，而不是网页界面。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 30)
                .padding(.bottom, WorkbenchSpacing.xs)
            }
        }
        .padding(.horizontal, WorkbenchSpacing.md)
        .padding(.vertical, WorkbenchSpacing.sm)
        .background(rowSelectionBackground(isSelected))
    }
}

private struct BrowserProcessRow: View {
    let process: AccountBrowserProcess
    let isBusy: Bool
    let stopAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                rowIdentity(
                    icon: "globe",
                    iconColor: .orange,
                    title: process.taskLabel ?? "未命名任务",
                    stateLabel: process.stateLabel,
                    stateColor: .green,
                    subtitle: "PID \(process.pid) · Playwright cliDaemon"
                )
                Spacer(minLength: WorkbenchSpacing.sm)
                Button("停止", role: .destructive, action: stopAction)
                    .disabled(isBusy || !process.canStop || process.fingerprint == nil)
            }
            Text("此项只用于安全结束自动化守护进程；停止后会从实时列表自动移除。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, WorkbenchSpacing.md)
        .padding(.vertical, WorkbenchSpacing.sm)
    }

}

private struct CodexTaskServiceRow: View {
    let task: AccountCodexTask
    let isSelected: Bool
    let selectAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Button(action: selectAction) {
                rowIdentity(
                    icon: task.kind == "browser_automation" ? "globe" : "terminal",
                    iconColor: .secondary,
                    title: task.kind == "browser_automation" ? "自动化任务" : "任务",
                    stateLabel: task.stateLabel,
                    stateColor: task.state == "running" ? .green : .secondary,
                    subtitle: task.relatedPorts.isEmpty
                        ? "没有端口参数"
                        : "端口 " + task.relatedPorts.map(String.init).joined(separator: ", ")
                )
            }
            .buttonStyle(.plain)
            Text(task.state == "recorded"
                ? "这是历史来源记录：当前没有监听进程，不可直接启动或停止。"
                : "这是只读来源证据；要停止或重启服务，请先在发现端口中登记。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if isSelected {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    detailLine("任务 ID", task.taskId)
                    detailLine("项目目录", task.cwd ?? "未知目录")
                    detailLine("执行命令", task.command)
                    detailLine("当前状态", task.state == "recorded"
                        ? "历史记录不等于当前进程。"
                        : "任务记录或相关端口仍有运行证据，但尚未登记为可控服务。")
                }
                .padding(.leading, 30)
                .padding(.bottom, WorkbenchSpacing.xs)
            }
        }
        .padding(.horizontal, WorkbenchSpacing.md)
        .padding(.vertical, WorkbenchSpacing.sm)
        .background(rowSelectionBackground(isSelected))
    }
}

@MainActor
@ViewBuilder
private func rowIdentity(
    icon: String,
    iconColor: Color,
    title: String,
    stateLabel: String,
    stateColor: Color,
    subtitle: String
) -> some View {
    HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
        Image(systemName: icon)
            .foregroundStyle(iconColor)
            .frame(width: 22)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: WorkbenchSpacing.xs) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                StatusChip(stateLabel, color: stateColor)
            }
            Text(subtitle)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }
    .contentShape(Rectangle())
}

@MainActor
@ViewBuilder
private func inlineDiagnosis(reason: String, hint: String?, isWarning: Bool) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text("原因：\(reason)")
            .font(.system(size: 10))
            .foregroundStyle(isWarning ? Color.orange : .secondary)
        if let hint, !hint.isEmpty {
            Text("下一步：\(hint)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

@MainActor
private func detailLine(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
        Text(value)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .lineLimit(2)
            .truncationMode(.middle)
    }
}

@MainActor
private func rowSelectionBackground(_ isSelected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        .padding(.horizontal, 4)
}

@MainActor
private func projectStatusColor(_ project: AccountManagedProject) -> Color {
    switch project.state {
    case "running":
        return .green
    case "stopped":
        return .secondary
    default:
        return .orange
    }
}

private struct AddProjectServiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, String, String, Int?) -> Void
    @State private var name = ""
    @State private var cwd = ""
    @State private var command = ""
    @State private var port = ""

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            PageHeader(
                title: "添加项目服务",
                description: "保存后可从“项目服务”栏目一键启动/停止。凭据请放在项目环境配置中。"
            )
            Form {
                TextField("名称", text: $name)
                HStack {
                    TextField("项目目录", text: $cwd)
                    Button("选择") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK {
                            cwd = panel.url?.path ?? cwd
                        }
                    }
                }
                TextField("启动命令", text: $command)
                TextField("端口（可选）", text: $port)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("登记") {
                    onSave(
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        cwd.trimmingCharacters(in: .whitespacesAndNewlines),
                        command.trimmingCharacters(in: .whitespacesAndNewlines),
                        Int(port.trimmingCharacters(in: .whitespacesAndNewlines))
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(WorkbenchSpacing.lg)
        .frame(width: 620)
    }
}
