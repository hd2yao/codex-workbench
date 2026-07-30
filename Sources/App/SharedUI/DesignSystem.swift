import AppKit
import CodexWorkbenchCore
import SwiftUI

enum WorkbenchSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

enum WorkbenchRadius {
    static let chip: CGFloat = 6
    static let row: CGFloat = 6
    static let panel: CGFloat = 10
    static let card: CGFloat = 10
}

extension Color {
    static let workbenchWindow = Color(nsColor: .windowBackgroundColor)
    static let workbenchCard = Color(nsColor: .controlBackgroundColor)
    static let workbenchBorder = Color(nsColor: .separatorColor)
    static let workbenchHairline = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.16)
                : NSColor.black.withAlphaComponent(0.12)
        }
    )
    static let workbenchSelection = Color.accentColor.opacity(0.11)
}

struct WorkbenchShadowSpec {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

enum WorkbenchShadow {
    static let overlay = WorkbenchShadowSpec(color: .black.opacity(0.12), radius: 12, x: 0, y: 5)
}

extension View {
    func workbenchShadow(_ spec: WorkbenchShadowSpec) -> some View {
        shadow(color: spec.color, radius: spec.radius, x: spec.x, y: spec.y)
    }
}

struct SurfaceCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat
    private let selected: Bool

    init(padding: CGFloat = WorkbenchSpacing.md, selected: Bool = false, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.padding = padding
        self.selected = selected
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: WorkbenchRadius.card, style: .continuous)
                    .fill(selected ? Color.workbenchSelection : Color.workbenchCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WorkbenchRadius.card, style: .continuous)
                    .stroke(
                        selected ? Color.accentColor.opacity(0.38) : Color.workbenchHairline,
                        lineWidth: selected ? 1 : 0.5
                    )
            )
    }
}

struct GroupedPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(Color.workbenchCard)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: WorkbenchRadius.panel,
                    style: .continuous
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: WorkbenchRadius.panel,
                    style: .continuous
                )
                .stroke(Color.workbenchHairline, lineWidth: 0.5)
            )
    }
}

struct PageHeader: View {
    let eyebrow: String?
    let title: String
    let description: String
    let trailing: AnyView?

    init(
        eyebrow: String? = nil,
        title: String,
        description: String,
        trailing: AnyView? = nil
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.description = description
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.lg) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Text(title)
                    .font(
                        .system(
                            size: WorkbenchInterfaceContract.pageTitleSize,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(.primary)
                Text(description)
                    .font(
                        .system(size: WorkbenchInterfaceContract.captionSize)
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: WorkbenchSpacing.md)
            if let trailing {
                trailing
            }
        }
    }
}

struct SectionTitle: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(
                    .system(
                        size: WorkbenchInterfaceContract.sectionTitleSize,
                        weight: .semibold
                    )
                )
            Spacer()
            if let detail {
                Text(detail)
                    .font(
                        .system(size: WorkbenchInterfaceContract.microSize)
                    )
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct StatusChip: View {
    let text: String
    let color: Color
    let systemImage: String?

    init(_ text: String, color: Color = .secondary, systemImage: String? = nil) {
        self.text = text
        self.color = color
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: WorkbenchSpacing.xxs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(
            .system(
                size: WorkbenchInterfaceContract.microSize,
                weight: .medium
            )
        )
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: WorkbenchRadius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkbenchRadius.chip, style: .continuous)
                .stroke(color.opacity(0.18), lineWidth: 0.5)
        )
    }
}

struct AdaptiveLabelValueRow<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: WorkbenchSpacing.md) {
                leading
                Spacer(minLength: WorkbenchSpacing.md)
                trailing
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                leading
                trailing
            }
        }
        .padding(.horizontal, WorkbenchSpacing.md)
        .padding(.vertical, 11)
    }
}

struct DataHealthIndicator: View {
    let presentation: WorkbenchDataHealthPresentation

    private var color: Color {
        switch presentation.level {
        case .healthy: .green
        case .degraded: .orange
        case .unavailable: .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.label)
                    .font(
                        .system(
                            size: WorkbenchInterfaceContract.microSize,
                            weight: .medium
                        )
                    )
                Text(presentation.detail)
                    .font(
                        .system(size: WorkbenchInterfaceContract.microSize)
                    )
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                if let date = presentation.lastSuccessfulRefresh {
                    Text("成功读取 \(date.formatted(date: .omitted, time: .shortened))")
                        .font(
                            .system(
                                size: WorkbenchInterfaceContract.microSize,
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct QuietEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: WorkbenchSpacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(
                    .system(
                        size: WorkbenchInterfaceContract.sectionTitleSize,
                        weight: .semibold
                    )
                )
            Text(message)
                .font(
                    .system(size: WorkbenchInterfaceContract.captionSize)
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(WorkbenchSpacing.xl)
        .accessibilityElement(children: .combine)
    }
}

struct MetricValue: View {
    let title: String
    let value: String
    let spokenDetail: String?

    init(title: String, value: String, spokenDetail: String? = nil) {
        self.title = title
        self.value = value
        self.spokenDetail = spokenDetail
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(
                    .system(
                        size: WorkbenchInterfaceContract.microSize,
                        weight: .medium
                    )
                )
                .foregroundStyle(.secondary)
            Text(value)
                .font(
                    .system(
                        size: WorkbenchInterfaceContract.sectionTitleSize,
                        weight: .semibold,
                        design: .monospaced
                    )
                )
                .lineLimit(1)
        }
        .padding(WorkbenchSpacing.md)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
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

struct ChartCalloutCard: View {
    static let defaultSize = CGSize(width: 176, height: 64)

    let dateText: String
    let exactText: String
    let magnitudeText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(dateText)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(exactText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1)
            Text(magnitudeText)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(
            width: ChartCalloutCard.defaultSize.width,
            height: ChartCalloutCard.defaultSize.height,
            alignment: .leading
        )
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.workbenchHairline, lineWidth: 0.5)
        )
        .workbenchShadow(WorkbenchShadow.overlay)
        .accessibilityElement(children: .combine)
    }
}

struct WorkbenchLogoMark: View {
    var size: CGFloat = 28

    var body: some View {
        Canvas { context, canvasSize in
            let side = min(canvasSize.width, canvasSize.height)
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let ringRadius = side * 0.36
            let gap = Double.pi / 14
            let ringWidth = side * 0.055

            // 四段观测环
            for segment in 0..<4 {
                var arc = Path()
                arc.addArc(
                    center: center,
                    radius: ringRadius,
                    startAngle: .radians(Double(segment) * .pi / 2 + gap),
                    endAngle: .radians(Double(segment + 1) * .pi / 2 - gap),
                    clockwise: false
                )
                context.stroke(
                    arc,
                    with: .color(.primary.opacity(0.55)),
                    style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                )
            }

            // 右上 accent 高亮弧
            var highlight = Path()
            highlight.addArc(
                center: center,
                radius: ringRadius,
                startAngle: .radians(-.pi / 2 + gap),
                endAngle: .radians(-gap),
                clockwise: false
            )
            context.stroke(
                highlight,
                with: .color(.accentColor),
                style: StrokeStyle(lineWidth: ringWidth * 1.4, lineCap: .round)
            )

            // 四个刻度
            for tick in 0..<4 {
                let angle = Double(tick) * .pi / 2
                let cosine = CGFloat(cos(angle))
                let sine = CGFloat(sin(angle))
                var mark = Path()
                mark.move(to: CGPoint(
                    x: center.x + cosine * (ringRadius + ringWidth),
                    y: center.y + sine * (ringRadius + ringWidth)
                ))
                mark.addLine(to: CGPoint(
                    x: center.x + cosine * (ringRadius + ringWidth + side * 0.055),
                    y: center.y + sine * (ringRadius + ringWidth + side * 0.055)
                ))
                context.stroke(mark, with: .color(.primary.opacity(0.4)), lineWidth: side * 0.03)
            }

            // 中心点
            let dot = side * 0.15
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)),
                with: .color(.primary.opacity(0.85))
            )
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Codex 工作台标识")
    }
}

struct SidebarBrandHeader: View {
    var body: some View {
        HStack(spacing: WorkbenchSpacing.sm) {
            WorkbenchLogoMark(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Codex 工作台")
                    .font(.system(size: 13, weight: .semibold))
                Text("本地状态观测与操作台账")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, WorkbenchSpacing.sm)
        .padding(.vertical, WorkbenchSpacing.md)
        .accessibilityElement(children: .combine)
    }
}

extension EventCategory {
    var displayName: String {
        switch self {
        case .account: "账号"
        case .automation: "自动化"
        case .context: "上下文"
        case .hook: "Hook"
        case .plugin: "Plugin"
        case .quota: "额度"
        case .skill: "Skill"
        case .system: "系统"
        case .thread: "任务"
        case .unknown: "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .account: "person.crop.circle"
        case .automation: "calendar.badge.clock"
        case .context: "arrow.triangle.2.circlepath"
        case .hook: "point.3.connected.trianglepath.dotted"
        case .plugin: "puzzlepiece.extension"
        case .quota: "gauge.with.dots.needle.33percent"
        case .skill: "wand.and.stars"
        case .system: "gearshape"
        case .thread: "bubble.left.and.bubble.right"
        case .unknown: "circle.dotted"
        }
    }

    var color: Color {
        switch self {
        case .quota: .orange
        case .context: .indigo
        case .thread: .blue
        case .account: .teal
        case .automation, .hook, .plugin, .skill: .purple
        case .system, .unknown: .secondary
        }
    }
}

extension EventStatus {
    var displayName: String {
        switch self {
        case .success: "成功"
        case .failure: "失败"
        case .inProgress: "进行中"
        case .skipped: "已跳过"
        case .unknown: "未知"
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .failure: .red
        case .inProgress: .blue
        case .skipped, .unknown: .secondary
        }
    }
}

extension EventCertainty {
    var displayName: String {
        switch self {
        case .confirmed: "已核实"
        case .inferred: "根据证据推断"
        case .unverified: "尚无足够证据"
        }
    }

    var explanation: String {
        switch self {
        case .confirmed: "来自明确的系统记录或结构化关系。"
        case .inferred: "由前后状态和时间窗口推断，官方未提供事件原因。"
        case .unverified: "已观察到线索，但当前证据不足以确认原因。"
        }
    }

    var color: Color {
        switch self {
        case .confirmed: .secondary
        case .inferred: .orange
        case .unverified: .red
        }
    }
}

extension EventImportance {
    var displayName: String {
        switch self {
        case .critical: "关键变更"
        case .important: "重要"
        case .routine: "常规"
        case .diagnostic: "诊断"
        }
    }

    var color: Color {
        switch self {
        case .critical: .orange
        case .important: .indigo
        case .routine: .secondary
        case .diagnostic: .secondary
        }
    }

    var markerSize: CGFloat {
        switch self {
        case .critical: 24
        case .important: 22
        case .routine: 18
        case .diagnostic: 16
        }
    }

    var titleWeight: Font.Weight {
        switch self {
        case .critical: .bold
        case .important: .semibold
        case .routine: .medium
        case .diagnostic: .regular
        }
    }
}

extension EventThreadRelation {
    var displayName: String {
        switch self {
        case .activeAtTime: "发生时所在对话"
        case .source: "来源对话"
        case .target: "接续后的对话"
        case .triggeredBy: "由该对话触发"
        case .unrelated: "无直接关系"
        case .unknown: "关系未知"
        }
    }
}

extension EventActorType {
    var displayName: String {
        switch self {
        case .agent: "Agent"
        case .app: "App"
        case .automation: "Automation"
        case .hook: "Hook"
        case .plugin: "Plugin"
        case .skill: "Skill"
        case .system: "System"
        case .user: "用户"
        case .unknown: "其他"
        }
    }
}

extension AccountRoleConfidence {
    var displayName: String {
        switch self {
        case .confirmed: "确定"
        case .inferred: "推断"
        case .unknown: "未知"
        }
    }

    var color: Color {
        switch self {
        case .confirmed: .green
        case .inferred: .orange
        case .unknown: .secondary
        }
    }
}

extension JSONValue {
    var displayText: String {
        switch self {
        case .array(let values): values.map(\.displayText).joined(separator: ", ")
        case .bool(let value): value ? "true" : "false"
        case .null: "—"
        case .number(let value):
            value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
        case .object(let values):
            values.keys.sorted().map { "\($0): \(values[$0]?.displayText ?? "—")" }.joined(separator: "\n")
        case .string(let value): value
        }
    }
}
