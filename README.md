# Codex 工作台

一个原生 macOS 工作台，用同一个 App 管理本机 ChatGPT / Codex 客户端、账号与额度、操作日志、项目任务、工作环境和自动化资产。

它是完整产品，不是“账号工具加上一堆集成”。每项用户可见能力都是并列模块；概览只负责组合信息。

## 产品模块

| 模块 | 内容 |
|---|---|
| 概览 | 跨模块状态、数据健康和需关注事件 |
| 账号与额度 | 本地账号识别、官方额度、切换与精确客户端重启 |
| 操作日志 | 脱敏生命周期事件、筛选、证据和任务定位 |
| 项目与任务 | 项目、线程、Token 归因、风险和上下文接续 |
| 项目环境与服务 | Git、端口、本地服务和工作环境 |
| 工具与自动化 | Skills、规则、Hooks、自动化、插件和配置资产 |
| 外观与皮肤 | 跟随系统、浅色、深色工作台外观 |

详细源码边界见[产品模块与源码边界](docs/architecture/product-modules.md)。

## 从源码安装

要求：Apple Silicon（M 系列）、macOS 13+、Xcode Command Line Tools、Git，以及能生成 macOS 13 兼容 arm64 后端的 Python 3.12 工具链。

```bash
git clone https://github.com/hd2yao/codex-workbench.git
cd codex-workbench
./install-from-source.sh --check
./install-from-source.sh
```

构建脚本会拒绝最低系统版本高于 macOS 13 的 Python，避免悄悄产出无法在目标系统运行的后端。如果默认 `python3` 被拒绝，可以用 `uv` 在本仓库的忽略构建目录中下载兼容工具链：

```bash
uv python install --install-dir .build/toolchains/python --no-bin 3.12
export CODEX_WORKBENCH_BUILD_PYTHON="$(find "$PWD/.build/toolchains/python" -path '*/bin/python3.12' -type f | head -n 1)"
./install-from-source.sh
```

该路径会在你的机器上构建应用和 arm64 本地数据后端，并把 App 安装到
`~/Applications/Codex 工作台.app`。安装后的日常运行不依赖 Python。

源码运行不需要 Developer ID 签名或 Apple 公证；它与下载预构建 DMG 是两种不同的分发方式。当前仓库不提供预构建发布包、不提供自动更新，也不要求 App Store。未来如分发供他人直接双击安装的 DMG，再单独处理 macOS Gatekeeper 所需的签名与公证。

## 本地数据与隐私

- 默认读取本机 `~/.codex`、Codex 历史和工作区元数据；不会上传这些数据。
- 操作台账保存在 `~/.codex/operation-ledger/events.jsonl`，增强采集会先备份已有 `hooks.json`，并可幂等卸载。
- 旧 `~/.codex-profiles` 仅做兼容读取；不会删除或迁移其数据。工作台不再安装或维护独立的 Codex Profile Switcher App。
- 不记录认证正文、Cookie、token、完整提示词、完整回复或完整 patch。

## 开发与验证

```bash
./test.sh
swift build
./build-app.sh
./verify-install.sh
```

`Platform/LocalDataRuntime` 只放随 App 打包的本地数据辅助程序；`Platform/DesktopClientRuntime` 只负责探测、打开和重启 ChatGPT/Codex。它们都是基础设施，不是“账号”或其他业务模块的父级。

## 状态

本仓库当前只提供源码。发布预构建 DMG、自动更新、App Store 上架、第三方模型 Provider 接入和 ChatGPT 皮肤编辑均不属于当前提交范围。
