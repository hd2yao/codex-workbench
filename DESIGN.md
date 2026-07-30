# Codex 工作台 Design Lock

## 2026-07-27 定向视觉修复

本增量只锁定已经完成的 Logo、图表与数量显示；六个功能模块的整套 K3 工程台账重设计按
用户要求暂缓，不由其他模型补画。

- 侧栏与 App 图标统一使用“四段观测环 + 右上蓝色高亮 + 中心点”，不再使用
  `scope` SF Symbol 或旧紫色 orbit / timeline 构造。
- 账号用量图在 macOS 13 与 14+ 均支持连续 hover；气泡显示日期、分组精确值和
  中文数量级，并通过 Core 纯几何钳位在 plot area 内。
- 所选日期的同一信息必须在图下摘要、`.help` 和 accessibility label 可达，不能
  只依赖 hover。
- Token 常驻摘要统一使用中文数量级：小于 1 万显示分组精确值，之后依次使用
  `万 / 亿 / 万亿`；项目、工具与账号页不得各自保留 K / M / B formatter。
- 容器 hairline 统一适配浅 / 深色；图表气泡是浮层，可使用唯一的克制投影。

## 2026-07-25 主题、Token 趋势与工作流资产增量

本增量覆盖下文“工具 / Skill”中的使用排行契约，并为账号页增加可信趋势图：

- toolbar 提供“跟随系统 / 浅色 / 深色”三态外观菜单，设置页绑定同一持久化偏好；
- 账号页使用当前账号的近 7 / 14 / 30 日每日 Token 折线图，不跨账号合并；
- 官方 daily buckets 为首选，本地记录只作为明确标注的降级；
- 删除 Skill 使用次数排行，改为规则、Skills、Hooks、自动化、插件与配置的资产目录；
- 动态工具只写“涉及任务”，不声称真实调用次数。

图表使用 `LineMark`、轻 `AreaMark` 和 macOS X 轴悬停选择；不恢复柱状图、彩色 KPI
或营销式仪表盘。完整设计、响应式和数据口径见
`docs/plans/2026-07-25-theme-usage-workflow-assets-design.md`。

## 2026-07-25 界面重设计增量

本增量覆盖下文中与“大标题 + 四摘要卡 + 蓝色当前账号 hero”有关的旧页面契约；
Calm Operations Console 的产品性格、六个功能模块的信息架构和操作日志 V1.4 契约保持
不变。设计提案由 Codex 主代理按 `frontend-design-workflow` 审计，并使用只读
OpenCode Go `opencode-go/kimi-k3` 作为外部设计顾问。

### 新的五秒任务

用户不滚动即可回答：

1. 当前正在控制 ChatGPT 还是兼容 Codex，真实路径 / PID / 选择依据是什么；
2. 桌面默认账号、当前任务账号和统计归因账号是否一致；
3. 是否存在需关注事件；
4. 数据源是否正常、最近一次成功刷新距今多久。

桌面客户端、Codex Home、App Server 和 Codex 任务必须使用准确主语，不再全部
写成“Codex App”。所有打开、切到和重启文案由真实客户端 target 动态生成。

### 新布局

- toolbar：目标客户端 chip、打开 / 切到客户端、全局刷新；全局操作不在页内重复。
- sidebar：展示六个功能模块与概览；底部常显综合数据健康与新鲜度，不放按钮。
- 概览：一个连续状态板 + 需关注 + 最近活动，替代四个等权 KPI 卡和静态工作原则
  卡。
- 账号页改名“账号与额度”：三账号角色、中性当前账号、行式额度 / 重置摘要、紧凑
  其他账号、旧 Profiles 迁移与诊断。
- 900pt 单列、1160pt 常规、1440pt 可双栏；只允许主内容纵向滚动。

### Token 覆盖

- 页面标题：`20pt semibold`；section：`13pt semibold`；正文 / 数值：`13pt`；
  caption：`12pt`；micro：`11pt`；所有数字使用 monospaced digits。
- 间距：`4 / 8 / 12 / 16 / 24 / 32`；连续容器圆角 `10pt`；chip `5–7pt`；
  hairline `0.5–1pt`；分组行最小 `28–34pt`。
- 绿色只表示已确认运行或健康；蓝色只表示交互或选中；未知为灰并显示原因。
- 不使用大面积蓝色账号背景、card-in-card、渐变、玻璃卡墙、装饰阴影或超过
  `20pt` 的页面信息数字。

完整数据与行为设计见
`docs/plans/2026-07-25-chatgpt-client-vault-redesign-design.md`。

## 设计目标

- **目标界面**：可长期使用的原生 macOS Codex 运维控制台。
- **用户场景**：工作中随时确认 Codex 状态、追溯关键操作、定位任务、管理账号。
- **主要任务**：在 5 秒内回答“发生了什么、谁触发、在哪个任务、是否可信、下一步去哪”。
- **参考模式**：结构借鉴，不复制品牌视觉或独特资产。
- **成功标准**：像成熟的 Mac 工具，而不是网页后台模板或数据营销页。

## 参考拆解

| 参考 | 采用 | 不采用 |
|---|---|---|
| [Apple Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) / [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views) | 原生侧栏、持久选中、可调整分栏、合理 min/max、可隐藏侧栏 | 自定义厚分隔线、过度玻璃化 |
| [Apple Toolbars](https://developer.apple.com/cn/design/human-interface-guidelines/toolbars) | 标题栏承载页面标题、搜索和当前页操作 | 把所有筛选和按钮塞入 toolbar |
| [Raycast Extensions](https://manual.raycast.com/extensions) / [Settings](https://manual.raycast.com/settings) | 上层工具壳、模块分组、菜单栏快速入口 | 黑色命令面板式高对比作为整页主题 |
| [GitHub Audit Log](https://docs.github.com/en/organizations/keeping-your-organization-secure/managing-security-settings-for-your-organization/reviewing-the-audit-log-for-your-organization) | actor/action/time 的事件语法、筛选与检索 | 安全审计表格的强技术文案 |
| [Vercel Activity Log](https://vercel.com/docs/activity-log) | 紧凑倒序活动流、状态与范围筛选 | Web 控制台式顶栏和品牌组件 |
| [Sentry Issue Details](https://docs.sentry.dev/product/issues/issue-details/) | 概要头、生命周期活动、渐进式详情 inspector | 过多告警密度和工程术语 |
| [Linear](https://linear.app/) | 克制色彩、清晰排版、低噪声分隔与紧凑节奏 | 复制其品牌紫色和网页导航结构 |
| [Stats](https://github.com/exelban/stats) | 菜单栏常驻、模块独立配置、按需展开 | 把所有指标都塞进菜单栏 |

## 视觉 DNA

- **信息架构**：固定侧栏 + 单一主内容 + 宽屏可选 inspector。
- **布局骨架**：titlebar toolbar、页面标题区、紧凑内容区；不使用营销 hero。
- **密度**：工作型中高密度，8pt 基线；一屏至少看见 6 条日志或 3 个账号摘要。
- **字体**：系统字体；标题使用 20/24 semibold，正文 13/18，辅助 11/16；数值使用 monospaced digits。
- **色彩**：中性表面为主，强调色只表达选择或语义状态。
- **组件语言**：8–12pt 圆角、0.5–1pt 边框、极轻阴影；卡片只用于真正独立的信息组。
- **状态交互**：选中、hover、focus、loading、empty、error 都有明确但克制的反馈。
- **动效**：120–180ms 淡入/位移，只用于展开和状态变化；尊重 Reduce Motion。
- **独特记忆点**：日志时间轴的“来源链 + 置信度 + 任务定位”三件套。

## Design Lock

### 视觉方向

**Calm Operations Console / 安静的运行控制台**。像 Apple 原生工具与 Linear 的克制信息密度结合：稳、清楚、可信，不追求炫技。

### 产品性格

- 理性、可解释、可靠。
- 对不确定性诚实，不用绿色圆点包装推断。
- 主要信息先于装饰，操作先于数据炫耀。

### 几何模型

- 窗口最小：`900 × 640`。
- 默认：`1160 × 780`。
- 宽屏验收：`1440 × 900`。
- 侧栏：默认 `216pt`，允许 `188–248pt`；可通过 toolbar/快捷键隐藏。
- 内容边距：最小窗口 `20pt`，默认/宽屏 `28pt`。
- 内容最大可读宽度：概览 `1180pt`；日志列表不超过 `820pt`，多余空间给 inspector。
- 固定层：titlebar/toolbar；其余内容垂直滚动。
- 只有主内容滚动，不允许根窗口产生横向滚动。

```text
┌──────────────────────────────────────────────────────────────┐
│ traffic lights   当前模块          Codex 状态   搜索 / 操作  │
├──────────────┬───────────────────────────────────────────────┤
│ Codex 工作台 │ 页面标题 / 说明 / 局部筛选                    │
│              │                                               │
│ 概览         │ 核心内容（连续表面，少量必要卡片）             │
│ 操作日志     │                                               │
│ 账号管理     │ 宽屏时：列表                 │ 详情 inspector │
│ ───────────  │                                               │
│ 即将推出     │                                               │
│ 线程/自动化  │                                               │
└──────────────┴───────────────────────────────────────────────┘
```

### 色彩与 token

颜色使用 SwiftUI semantic colors，以下是角色而非固定 hex：

- `surface.window`：`windowBackgroundColor`
- `surface.sidebar`：系统 sidebar material
- `surface.card`：`controlBackgroundColor`，保证不透明度足以隔绝背景干扰
- `surface.selected`：accent 10–14% 混合
- `border.subtle`：`separatorColor` 55–70%
- `text.primary` / `text.secondary` / `text.tertiary`：系统 label colors
- `semantic.success`：green，仅用于已确认成功
- `semantic.warning`：orange，仅用于需关注/推断/资源消耗
- `semantic.failure`：red，仅用于失败或高风险
- `semantic.thread`：blue
- `semantic.context`：indigo/purple
- `semantic.neutral`：secondary gray

禁止同屏为不同模块各自指定彩虹色图标。侧栏统一使用单色 SF Symbols，选中项才跟随 accent。

### 间距、圆角和阴影

- 间距标尺：`4 / 8 / 12 / 16 / 24 / 32`。
- 卡片圆角：`12pt`；小 chip/button：`7–8pt`；popover：系统默认。
- 边框：`0.5–1pt`。
- 阴影：仅浮层或高优先级概览卡使用 `y=1, blur=8, opacity<=0.06`。
- 不做彩色发光、霓虹、深重投影和多层玻璃卡。

## 页面契约

### 概览

阅读顺序：

1. 标题与“最后更新”。
2. 四个紧凑状态块：Codex、当前登录账号、今日事件、需关注。
3. “最近活动”宽面板，显示 6–8 条事件。
4. “数据源健康”与快捷操作，作为次要信息。

状态块数字不超过 28pt，不使用超大 KPI。每块必须同时显示语义标签，不能只靠颜色。

### 操作日志

```text
[搜索________________________________] [级别] [来源] [状态]

今天
  19:13  ● 已使用 1 次额度重置       成功  账号模块
           hd-master · 确定 · 活动时任务：系统日志时间轴设计
  18:46  ● 上下文已压缩               成功  PreCompact Hook
           来源任务 → 当前任务 · 确定
```

- 最新在上；日期标题 sticky。
- 行高 `76–96pt`，标题单行，摘要最多两行；scope chips 可在窄屏换行。
- 时间列固定 `54pt`；时间轴轨道固定 `20pt`；正文自适应；右侧来源/状态保持稳定宽度。
- hover 只增强背景；核心字段不可只放 tooltip。
- 点击行：默认展开/选中；宽屏显示右侧 inspector，窄屏使用 sheet 或页内展开。
- 行内必须显示项目与对话名称；账号级事件显示账号与“全局事件”，不虚构线程。
- 重要性通过节点尺寸、细强调线和文字共同表达，不只依赖颜色。
- inspector 分区：概要、归属（项目/对话/账号）、完整线程 ID 与关系、来源链、before/after、证据、原始字段（脱敏）。
- 工作流变更的列表摘要必须写人能理解的调整内容，不以 fingerprint 充当摘要。
- 工作流详情顺序固定为：本次改动、归属、来源、技术状态、证据；“修改来源对话”和“投递目标对话”使用不同标签与打开入口。
- 全局 Automation 同时显示“全局工作流”作用域；无法定位来源对话时显示明确降级文案，不留空也不虚构线程。
- 全局规则、Codex 配置、Plugin、Skill、Hook、Automation 的列表摘要都必须回答“做了什么”；名称和“已更新/已新增”只作为标题，不能作为摘要重复一次。
- 详情“本次改动”优先使用“用途调整 / 新增能力 / 移除能力”。缺少旧版本时显示“更新后职责 / 更新后包含”，并紧邻显示“无法确认是否均为本次新增”的证据边界。
- 上下文压缩详情的第一信息区命名为“压缩后摘要”，直接展示 context card 中最近有效用户要求和压缩前进展；“卡片已生成”只能作为来源状态，不能占用内容摘要位置。
- 压缩后摘要每项完整换行，不使用 tooltip 承担正文；证据区提供“打开完整摘要卡片”，长内容保持可选择且不挤压归属信息。
- fingerprint、文件时间和内部事件名统一放在“技术状态”，不得占据“本次改动”的主要视觉位置。

### 账号管理

- 顶部只展示 Codex 当前实际登录账号，不用最近任务或统计归因替代“当前”。
- 当前账号依次展示官方返回的额度窗口、逐张重置卡和账号用量；窗口按 `window_minutes` 动态命名（例如 5 小时或 7 日），缺失的第二窗口显示“其他额度 —”，不得伪造固定时长。
- 其他 profile 作为切换目标放在当前账号之后；当前账号有明确但不夸张的选中状态。
- 切换账号是高影响动作，按钮文案为“切换并重启 Codex”，点击后需明确进度和结果。
- 最近任务与统计归因只放在可展开的高级诊断中，并明确不会决定当前登录账号。

### 菜单栏

- 宽度约 `360pt`，最大高度 `500pt`。
- 顶部：Codex 状态 + 当前实际登录账号。
- 中部：最近 3 条 P0/P1 事件。
- 底部：打开工作台、打开客户端；设置/退出放次级菜单。
- 菜单栏不是完整 Dashboard，不放多页导航和复杂图表。

### 项目分析

- 使用本地账号后端的项目排行，不在账号页混入项目维度。
- 顶部只显示项目数、对话数和累计 Tokens；下方连续排行展示项目名、完整路径、对话、Tokens 和最近活动。
- “数据源不可用”与“数据源可用但暂无项目”必须分开表达。

### 工具 / Skill

- 动态工具区只展示本地数据库中“涉及任务”的关联证据，不称实际调用次数。
- Skill 不展示使用排行；工作流资产目录展示规则、Skills、Hooks、自动化、插件与配置。
- 同 slug 的 Skill 源码和全局安装副本按 fingerprint 合并，并明确一致 / 不一致。
- 长 namespace、工具名和 Skill 名单行截断，不产生横向滚动。

## 状态来源

| UI 状态 | 权威来源 | 作用域 | 降级文案 |
|---|---|---|---|
| Codex 是否运行 | `NSRunningApplication` bundle id | 设备 | “未检测到 Codex 进程” |
| 当前登录账号 | 本地数据运行时的 `active_profile` + `desktop_status/active_profile` | 设备 | “未知；打开账号管理刷新” |
| 最近任务账号 | `profile_roles.task` | 最近活动任务 | 必须显示“推断”或“未知” |
| 统计归因账号 | `profile_roles.attribution` | 本地统计周期 | “未建立归因记录” |
| 日志事实 | operation ledger + evidence | 单事件 | `已核实 / 根据证据推断 / 尚无足够证据` |

## 响应式策略

- `900–1079pt`：侧栏可隐藏；日志单列，详情页内展开；状态块 2×2。
- `1080–1279pt`：侧栏固定；日志主列；详情按选择以 overlay/页内呈现；状态块 4 列。
- `>=1280pt`：日志列表 + `320–380pt` inspector；账号卡可双列。
- 长 profile 名单行中间/尾部截断，完整值在可访问性描述和详情中显示。
- 最大数字使用 monospaced digits，预留位宽；缺失值显示“—”和原因，不显示假 0。

## 状态覆盖

- `loading`：使用稳定骨架/ProgressView，不让布局跳动。
- `empty`：说明为何暂无事件，并给出“重新扫描”操作。
- `error`：局部错误卡，不替换整个页面；保留上次成功数据并标注时间。
- `disabled`：降低对比并给说明，不只变灰。
- `success`：短暂状态反馈，不常驻庆祝动画。
- `inferred`：橙色细标签 + “推断”，绝不使用成功绿色。

## 禁止漂移

- 不做营销 hero、玻璃拟态大卡片墙、装饰渐变背景。
- 不用 32pt 以上大数字制造“Dashboard 感”。
- 不混用 emoji、文字图标、第三方彩色图标和 SF Symbols。
- 不让每个模块拥有独立视觉主题。
- 不把 hover tooltip 当作必要信息的唯一入口。
- 不把推断状态显示为“当前”事实。

## 验收截图

- `overview-light-900x640.png`
- `overview-light-1160x780.png`
- `activity-light-1440x900-selected.png`
- `activity-dark-1160x780.png`
- `accounts-light-1160x780.png`
- `menubar-dark.png`
- V1.2 `workflow-event-minimum.png`：`900×640` 行内展开。
- V1.2 `workflow-event-default.png`：`1160×780` 行内详情与改动优先层级。
- V1.2 `workflow-event-wide.png`：宽屏列表 + inspector。
- V1.2 `workflow-event-associations.png`：来源项目、修改来源对话与投递目标对话。
- V1.3 `workflow-event-skill.png`：Skill 更新的列表摘要、用途和能力变化。
- V1.3 `workflow-event-hook.png`：Hook 新增/更新的职责、主要能力与证据边界。
- V1.3 `workflow-event-automation-variable.png`：变量式 Automation 更新调用的历史回填。
- V1.4 `context-summary-wide.png`：宽屏中的压缩后摘要、最近用户要求和压缩前进展。
- V1.4 `workflow-rule-wide.png`：宽屏中全局规则的具体增删与修改来源对话。

任何文字重叠、内容越界、根窗口横向滚动、关键字段缺失、推断被当事实或截图产物身份不明，直接判 `FAIL`。
