# Codex 工作台独立仓库与模块化迁移 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将工作台从 `agent-tools` 独立为公开的 `codex-workbench` 仓库，并以并列产品模块整理源码。

**Architecture:** SwiftUI App/Core 仍使用 SwiftPM target，但源码移动到 `Sources/App/{Modules,Platform}` 与 `Sources/Core/{Modules,Platform}`。Python 后端迁入 `Platform/LocalDataRuntime`，仅保留工作台需要的源和测试；应用客户端探测迁入 `Platform/DesktopClientRuntime`。旧 Profile Switcher UI/Web/菜单栏不是工作台模块，不迁入。

**Tech Stack:** Swift 6、SwiftUI、Swift Package Manager、Python 3、PyInstaller、Bash、GitHub CLI。

---

### Task 1: 创建迁移结构测试和目标仓库

**Files:**
- Create: `Tests/Scripts/test-module-layout.sh`
- Create: `.gitignore`
- Create: `docs/architecture/product-modules.md`
- Modify: `specs/workbench-repository-migration/{spec.md,execution-contract.md,tasks.md}`

**Step 1: 写出失败的结构测试**

测试应断言目标仓库存在六个一级产品模块、两个平台运行时目录、没有 `codex-profile-switcher`，且后端构建脚本不含 `../codex-profile-switcher`。

**Step 2: 在新仓库尚未迁移前运行测试**

Run: `bash Tests/Scripts/test-module-layout.sh`
Expected: FAIL，因目标目录尚不存在。

**Step 3: 用 GitHub bootstrap dry-run 创建公开仓库计划**

Run: `python3 /Users/example/program/codex-workflow-skills/github-project-bootstrap/scripts/create_github_project.py --description "Modular macOS workbench for local Codex and ChatGPT operations" --repo-name codex-workbench --parent-dir /Users/example/program --visibility public --dry-run`

Expected: 输出公开仓库创建计划，不创建远端。

**Step 4: 创建公开仓库并建立迁移分支**

Run: 同上命令去除 `--dry-run`，随后 `git -C /Users/example/program/codex-workbench switch -c migrate/modular-workbench`。

**Step 5: 验证仓库身份**

Run: `gh repo view --json name,url,visibility,defaultBranchRef`。
Expected: `codex-workbench`、`PUBLIC`、默认分支 `main`。

**Step 6: Commit**

```bash
git add .gitignore docs/architecture/product-modules.md Tests/Scripts/test-module-layout.sh specs/workbench-repository-migration
git commit -m "docs: define modular workbench migration"
```

### Task 2: 迁入源码并按模块移动

**Files:**
- Create: `Sources/App/{Shell,Modules/*,Platform/DesktopClientRuntime,SharedUI}`
- Create: `Sources/Core/{Modules/*,Platform/*}`
- Create: `Platform/LocalDataRuntime/*.py`
- Create: `Tests/LocalDataRuntimeTests/*.py`
- Modify: `Package.swift`
- Modify: `scripts/build-account-backend.sh`
- Modify: `scripts/account-resource-fingerprint.sh`
- Modify: `Tests/Scripts/test-account-resource-freshness.sh`
- Delete: no file in the new repository; old Profile Switcher UI is deliberately not copied.

**Step 1: 复制当前工作台 tracked 源码、资源、脚本、文档、截图和测试到新仓库**

从来源工作树的 `codex-workbench/` 复制，排除 `.build/`、`build/`、App 图标生成物和 Git 元数据。先比较清单与 `git ls-files`。

**Step 2: 迁入最小 Python 本地运行时与测试**

从 `codex-profile-switcher/` 仅复制 `codex_profile.py`、`codex_profile_dashboard.py`、`codex_runtime_services.py`、`account_vault.py` 和相应纯后端测试；不复制 Web、菜单栏、profile 启动器、旧安装/构建脚本或历史规划文档。

**Step 3: 按模块移动 Swift 文件**

将 UI 和 Core 文件移至对应模块；共享客户端探测移至 `Platform/DesktopClientRuntime`，共享数据访问、证据和格式化逻辑移至 `Platform/LocalDataRuntime` 或 `SharedUI`。在 `Package.swift` 为现有 target 声明新的 source path。

**Step 4: 修正所有文件路径与 Python 导入路径**

后端构建脚本只使用 `$ROOT_DIR/Platform/LocalDataRuntime`，测试显式加入该目录；不得引用来源工作树或旧仓库相对路径。

**Step 5: 运行结构和 Package 验证**

Run: `bash Tests/Scripts/test-module-layout.sh && swift package describe`。
Expected: PASS，SwiftPM 仍发现既有三个产品。

**Step 6: Commit**

```bash
git add Package.swift Sources Platform Tests scripts Resources docs screenshots specs
git commit -m "refactor: organize workbench by product modules"
```

### Task 3: 更新公开仓库文档和安全边界

**Files:**
- Modify: `README.md`
- Modify: `DESIGN.md`
- Modify: `install-from-source.sh`
- Modify: `Tests/Scripts/test-source-bootstrap.sh`
- Modify: `Tests/Scripts/test-install-migration.sh`

**Step 1: 更新 README**

说明源码安装、产品模块图、运行时本地数据读取、不会上传数据、源码安装不需要 Developer ID 公证；明确预编译 DMG 的 Gatekeeper 行为与源码运行的区别。

**Step 2: 更新安装/测试脚本**

删除对旧仓库布局的假设，保留现有数据/Hook 不迁移和不删除的保护。

**Step 3: 执行快速文档与脚本验证**

Run: `bash Tests/Scripts/test-source-bootstrap.sh && bash Tests/Scripts/test-install-migration.sh && git diff --check`。
Expected: PASS。

**Step 4: Commit**

```bash
git add README.md DESIGN.md install-from-source.sh Tests/Scripts/test-source-bootstrap.sh Tests/Scripts/test-install-migration.sh
git commit -m "docs: document standalone workbench repository"
```

### Task 4: 验证、推送新仓库并清理旧仓库

**Files:**
- Modify (old repository): `.gitignore`
- Delete (old repository): `codex-workbench/`, `codex-profile-switcher/`
- Delete (ignored local artifacts, after source push): `codex-workbench/.build/`, `codex-workbench/build/`, `codex-profile-switcher/build/`。

**Step 1: 执行新仓库完整回归**

Run: `./test.sh && bash Tests/Scripts/test-ui-source-contracts.sh && bash Tests/Scripts/test-account-backend-bundle.sh && bash Tests/Scripts/test-account-resource-freshness.sh`。
Expected: PASS；若签名工具或网络发布工具未安装，只运行不依赖它们的检查并记录事实。

**Step 2: 审查 staged 内容和大文件**

Run: `git diff --check && git status --short && git ls-files -s | awk '$4 ~ /(^|\\/)(\.env|build|\.build|dist)(\\/|$)/ { print; exit 1 }'`。
Expected: 无错误、无本机生成物或敏感文件。

**Step 3: 将迁移分支快进到 main 并推送**

Run: `git switch main && git merge --ff-only migrate/modular-workbench && git push -u origin main`。
Expected: GitHub `main` 显示完整工作台代码。

**Step 4: 清理旧仓库 tracked 源码并更新忽略规则**

只有确认新仓库 `main` 包含 T002/T003 源后，使用 `git rm -r -- codex-workbench codex-profile-switcher`；删除已确认的 ignored build 目录，不触碰用户主目录、已安装 App 或用户数据。

**Step 5: 验证旧仓库保留范围并提交推送**

Run: `git ls-files | rg '^(codex-workbench|codex-profile-switcher)/'`（应无输出），`git ls-files | rg '^(water-reminder|codex-thread-bridge)/'`（应有输出），随后提交并 `git push origin main`。

**Step 6: 删除确认归属旧 Profile Switcher 的 GitHub Release**

新仓库 `main` 已推送后，先重新核对 `hd2yao/agent-tools` 的 12 个 Release 均无资产且说明为 Profile Switcher，再执行 `gh release delete <tag> --repo hd2yao/agent-tools --yes`。不传 `--cleanup-tag`。

**Step 7: 收敛检查**

逐项复核 `spec.md` 的 AC-001 至 AC-007，记录签名/公证和远端 Release 未执行为已批准非目标。
