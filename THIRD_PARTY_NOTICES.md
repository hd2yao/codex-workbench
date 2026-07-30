# 第三方组件声明

本文件只记录 Codex 工作台发行包内自包含账号后端所携带的第三方运行组件，不构成对本仓库源码许可证的选择或变更。

## CPython

- 项目：Python / CPython
- 用途：为账号后端提供发行包内自包含的 Python 运行时。
- 许可证：Python Software Foundation License Version 2 及 CPython 随附的历史许可证。
- 上游来源：<https://github.com/python/cpython>、<https://docs.python.org/3/license.html>

## PyInstaller

- 版本：`6.21.0`
- 用途：把既有账号后端及 CPython 运行时组装为 macOS `arm64` onedir helper。
- 许可证：GNU General Public License Version 2，并适用 PyInstaller Bootloader Exception。
- 上游来源：<https://github.com/pyinstaller/pyinstaller>、<https://pyinstaller.org/en/stable/license.html>

## 随 CPython 收集的标准库组件

PyInstaller onedir 产物会包含当前构建解释器所需的 Python 标准库、动态库和系统运行组件。其许可证文本与归属以构建环境中 CPython 发行版附带内容为准；发布前必须对最终 bundle 再生成一次实际组件清单并复核本声明。
