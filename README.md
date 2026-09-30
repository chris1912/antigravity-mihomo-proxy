# Antigravity Mihomo Proxy / Antigravity Mihomo 代理管理器

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-blue)](https://learn.microsoft.com/powershell/)
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-blue)](https://www.microsoft.com/windows/)
[![Mihomo](https://img.shields.io/badge/Mihomo-v1.19.30-green)](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.30)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

[中文](#中文) · [English](#english)

## 中文

### 项目简介

面向 Windows 的 PowerShell / WinForms 代理管理工具，为 Antigravity 提供独立的
Mihomo 核心，并支持为其他接受 HTTP / SOCKS 代理的应用创建多个通用实例。

同一实例共享订阅，可将不同监听端口绑定到不同节点；不同实例拥有独立的核心进程、
控制端口、运行目录和密钥，共用项目目录中的 Mihomo 可执行文件。
项目不修改系统代理或已有 Clash / Mihomo 配置；通用实例需要由目标应用自行设置代理。

### 功能

- Antigravity 专用代理，默认代理端口 `7899`、控制端口 `19090`。
- 一个订阅提供多个 HTTP / SOCKS 混合监听端口，分别选择出口节点。
- 添加、重命名、启动、停止和删除通用代理实例。
- 检查基础延迟，对 Antigravity 节点执行 Gemini API 端点探测。
- 在核心管理中核对 PID、启动时间、可执行文件和配置路径。
- 配置 Antigravity 快捷方式、旧启动入口和 `agy-proxy` CLI 包装器。
- 在专用代理与已有 Clash 端口 `7898` 之间切换。
- 按白名单生成便携 ZIP，排除个人设置、订阅缓存、控制密钥和日志。

### 环境要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | 64 位 Windows 10 / 11 |
| PowerShell | Windows PowerShell 5.1，或 PowerShell 7 |
| 核心 | Mihomo `v1.19.30`，Windows amd64 |
| 订阅 | Mihomo proxy-provider 支持的节点订阅 |
| 可选应用 | Antigravity IDE、Antigravity 2.0、`agy` CLI |

`start.cmd` 使用 Windows PowerShell 5.1；PowerShell 7 可直接运行 `start.ps1`。
项目未提供完整的跨版本运行兼容性认证。

缺少核心或版本不符时，GUI 会请求确认，再从
[固定版本官方 Release](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.30)
下载，校验 Release 提供的 SHA-256 摘要及解压后的核心版本。
已有核心只检查版本；版本检查不能证明二进制来源。源码仓库不包含 `mihomo.exe`。

### 安装

克隆公开仓库并启动 GUI：

```powershell
git clone https://github.com/chris1912/antigravity-mihomo-proxy.git
Set-Location -LiteralPath 'antigravity-mihomo-proxy'
.\start.ps1
```

也可下载源码 ZIP，完整解压后双击 `start.cmd`。
请使用当前用户可写的目录，保留相对目录结构；首次加载订阅可能需要联网下载核心。
非标准安装目录请在 GUI 中选择 Antigravity 可执行文件。
若脚本被执行策略阻止，按照本机管理员的策略处理。

### 使用

1. 打开“Antigravity 专用”页，输入自己的订阅 URL，点击“加载订阅”。
2. 选择节点，按需执行“测基础延迟”或“深度测Gemini”。
3. 选择端口并指派节点；需要多个出口时添加监听端口。
4. 保存配置并切换启动入口；此操作本身不启动 IDE。
5. 通过已配置的快捷方式，或以下启动器启动应用：

   ```powershell
   .\launch-saved-antigravity.ps1 -Target ide
   .\launch-saved-antigravity.ps1 -Target v2
   .\agy-proxy.cmd --help
   ```

6. 为其他应用代理时，通过“+ 添加新代理实例”设置订阅和节点映射，
   点击“保存并启动本实例”，再在目标应用中填写 `127.0.0.1` 和对应监听端口。
7. 在 GUI 中停止不再需要的核心；关闭窗口后，后台核心继续运行。

完成配置后的最小使用示例：

```powershell
curl.exe --proxy http://127.0.0.1:7899 https://example.com/
```

使用通用实例时，将 `7899` 换成实例的实际监听端口。
不要在文档、Issue 或截图中公开真实订阅 URL。

| 用途 | 默认端口 |
| --- | ---: |
| Antigravity 主代理 | 7899 |
| Antigravity 控制 API | 19090 |
| 新通用实例代理 | 从 7880 起自动选择 |
| 新通用实例控制 API | 从 19091 起自动选择 |
| Clash 切换目标 | 7898 |

**切换操作会修改本地入口：**保存专用入口会改写桌面 / 开始菜单快捷方式、
项目和用户目录中的 `agy-proxy` 包装器，并可能修改已安装 IDE 的 CLI 入口和旧启动脚本。
切换到 Clash 还会退出识别到的 Antigravity、语言服务和 `agy` 进程，并停止专用核心。
请先保存应用中的工作；脚本保留部分入口备份，但不提供完整自动撤销流程。

### 配置与结构

程序在内存中创建默认设置，保存时写入 `config/settings.json`。
[settings.example.json](config/settings.example.json) 仅展示配置结构，不含可用订阅；
真实订阅、节点名、安装路径和实例设置只应保存在本地。

| 路径 | 用途 |
| --- | --- |
| `AntigravityProxy.ps1` | GUI、设置与核心管理 |
| `start.ps1` / `start.cmd` | GUI 入口 |
| `launch-saved-antigravity.ps1` | 专用代理下的 IDE / 2.0 启动器 |
| `launch-clash-antigravity.ps1` | Clash 下的 IDE / 2.0 启动器 |
| `run-agy-with-*.ps1` / `agy-proxy.cmd` | CLI 代理启动器 |
| `switch-antigravity-to-clash.ps1` | 本地入口切换 |
| `build.ps1` / `build.cmd` | 验证、清理与便携打包 |
| `tests/Test-ProxyCore.ps1` | 本地回归脚本 |
| `runtime/` / `providers/` / `logs/` | 运行配置、密钥、元数据、订阅缓存与日志 |

不要提交真实设置、运行数据、环境变量文件、私钥、备份、数据库、核心二进制或生成 ZIP。
空 `.gitkeep` 文件可发布。
实现约束见 [MEMORY.md](MEMORY.md)，贡献方法见 [CONTRIBUTING.md](CONTRIBUTING.md)。

### 检查与打包

本次更新（2026-09-30）执行了静态语法、编码、示例 JSON、本地链接、
发布文件和 Git 历史的密钥扫描；未运行回归脚本、GUI、真实订阅或联网代理验证。

维护者需要运行回归检查时，可执行：

```powershell
.\build.ps1 -Validate
```

此命令解析 PowerShell AST，执行临时目录中的回归脚本，并尝试读取本地核心版本；
不验证真实订阅、GUI 全流程或完整的二进制供应链。

生成便携包：

```powershell
.\build.ps1
```

普通打包会读取本地设置以恢复实例目录，再按白名单归档；不复制真实设置和运行数据。
包内 `config/settings.json` 来自空示例。
**本机存在 `mihomo.exe` 时，便携包会包含该二进制。**
源码仓库与二进制发行包属于不同发布范围；发布含核心的 ZIP 前，
单独核对二进制来源、第三方许可证及对应源码获取说明。

默认打包不清理运行数据。`-Clean` / `-CleanOnly` 会删除实例运行文件、日志、
下载缓存及 `.codex/` 下的本地审计产物。
清理前先停止本项目核心，并保留所需备份。本轮没有运行打包或清理。

### 限制

- 支持 Windows / amd64，GUI 当前为中文。
- 订阅须包含可用于 proxy-provider 的节点，不承诺导入任意完整 Clash 配置。
- GUI 网络操作同步执行，大量节点测试可能暂时降低响应。
- Gemini 探测不使用 API Key；HTTP 400 / 403 等响应可能被标为可用，
  不能据此确认账号、额度、地区权限或实际模型调用成功。
- Gemini 测试暂时切换主策略组节点，可能影响使用该端口的应用。
- 通用实例只提供端口，不自动改写任意应用的网络设置。
- 已运行的 IDE 可能需要完全退出再启动，才能继承新代理。
- Clash 切换依赖已运行的本地 `7898` 端口，不会自动配置 Clash。

### 安全

订阅 URL 可能含凭据，会以明文保存在本地设置和生成配置中。
控制 API 配置为 `127.0.0.1`，使用随机本地密钥；这些措施不替代文件访问控制。
不要公开真实配置、日志、入口备份或屏幕上的敏感内容。
项目不保证订阅来源可信；安全报告方法见 [SECURITY.md](SECURITY.md)。

### 许可证

本仓库管理脚本和文档采用 [MIT License](LICENSE)，保留原版权署名。
Mihomo 固定版本采用 [GNU GPL v3](https://github.com/MetaCubeX/mihomo/blob/v1.19.30/LICENSE)，
MIT 不替代其许可证。本项目不是 Antigravity、Google 或 Mihomo 官方产品。

## English

### Summary

A PowerShell / WinForms proxy manager for Windows, with a dedicated Mihomo process for
Antigravity and multiple general instances for other applications that accept HTTP / SOCKS proxies.

Ports within an instance share a subscription and can select different nodes. Separate instances
have their own core process, controller port, runtime directory, and secret, while sharing the
Mihomo executable in the project directory.
The project does not change the system proxy or existing Clash / Mihomo configuration;
other applications must be configured to use a general instance's proxy port.

### Features

- Dedicated Antigravity proxy, defaulting to proxy `7899` and controller `19090`.
- Multiple HTTP / SOCKS mixed listener ports per subscription, with a node selection per port.
- Add, rename, start, stop, and delete general proxy instances.
- Basic latency checks and Gemini API endpoint probes for Antigravity nodes.
- PID, start time, executable, and configuration path checks during core management.
- Configure Antigravity shortcuts, legacy launchers, and the `agy-proxy` CLI wrapper.
- Switch between the dedicated proxy and an existing Clash port `7898`.
- Build portable ZIPs from an allowlist, excluding personal settings, caches, secrets, and logs.

### Requirements

| Component | Requirement |
| --- | --- |
| Operating system | 64-bit Windows 10 / 11 |
| PowerShell | Windows PowerShell 5.1, or PowerShell 7 |
| Core | Mihomo `v1.19.30`, Windows amd64 |
| Subscription | Nodes supported by Mihomo proxy-providers |
| Optional applications | Antigravity IDE, Antigravity 2.0, `agy` CLI |

`start.cmd` uses Windows PowerShell 5.1; PowerShell 7 can run `start.ps1` directly.
Comprehensive runtime compatibility across these versions has not been certified.

If the core is missing or has a different version, the GUI requests confirmation before
downloading from the [pinned official Release](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.30).
It checks the Release-provided SHA-256 digest and extracted core version.
Existing executables receive only a version check, which does not establish their provenance.
The source repository does not contain `mihomo.exe`.

### Installation

Clone the public repository and start the GUI:

```powershell
git clone https://github.com/chris1912/antigravity-mihomo-proxy.git
Set-Location -LiteralPath 'antigravity-mihomo-proxy'
.\start.ps1
```

Alternatively, download the source ZIP, extract it completely, and double-click `start.cmd`.
Use a writable directory and preserve the relative layout; the first subscription load may
need network access to download the core.
Select the executable in the GUI for a nonstandard Antigravity installation.
Handle blocked scripts according to your machine's execution policy.

### Usage

1. Open the Antigravity tab, enter your subscription URL, and load the nodes.
2. Select a node and optionally run a basic latency or Gemini endpoint check.
3. Select a port and assign its node; add ports for additional exits.
4. Save the configuration and switch launch entries. This does not start the IDE.
5. Start the application through a configured shortcut or the corresponding launcher:

   ```powershell
   .\launch-saved-antigravity.ps1 -Target ide
   .\launch-saved-antigravity.ps1 -Target v2
   .\agy-proxy.cmd --help
   ```

6. For another application, add a general instance, set its subscription and node mappings,
   save and start it, then configure the application with `127.0.0.1` and its listener port.
7. Stop unused cores in the GUI. Closing the window leaves background cores running.

Minimal usage after configuring the proxy:

```powershell
curl.exe --proxy http://127.0.0.1:7899 https://example.com/
```

Replace `7899` with the actual listener port for a general instance.
Never expose real subscription URLs in documentation, issues, or screenshots.

| Purpose | Default port |
| --- | ---: |
| Antigravity primary proxy | 7899 |
| Antigravity controller API | 19090 |
| New general instance proxy | Automatically selected from 7880 |
| New general instance controller API | Automatically selected from 19091 |
| Clash switch target | 7898 |

**Switching changes local launch entries:** saving dedicated entries rewrites desktop / Start
menu shortcuts and project / user `agy-proxy` wrappers, and may change an installed IDE's
CLI entry and legacy scripts.
Clash switching also closes identified Antigravity, language service, and `agy` processes,
and stops the dedicated core. Save your work first.
Some original entries are backed up, but a complete automatic undo is not provided.

### Configuration and layout

Defaults are created in memory; saving writes `config/settings.json`.
[settings.example.json](config/settings.example.json) describes the structure without a usable
subscription. Keep actual subscriptions, node names, installation paths, and instance settings local.

| Path | Purpose |
| --- | --- |
| `AntigravityProxy.ps1` | GUI, settings, and core management |
| `start.ps1` / `start.cmd` | GUI entry points |
| `launch-saved-antigravity.ps1` | IDE / 2.0 with the dedicated proxy |
| `launch-clash-antigravity.ps1` | IDE / 2.0 with Clash |
| `run-agy-with-*.ps1` / `agy-proxy.cmd` | CLI proxy launchers |
| `switch-antigravity-to-clash.ps1` | Local entry switching |
| `build.ps1` / `build.cmd` | Validation, cleanup, and portable packaging |
| `tests/Test-ProxyCore.ps1` | Local regression script |
| `runtime/` / `providers/` / `logs/` | Configuration, secrets, metadata, subscription caches, and logs |

Do not commit actual settings, runtime data, environment files, private keys, backups,
databases, core binaries, or generated ZIPs. Empty `.gitkeep` files may be published.
See [MEMORY.md](MEMORY.md) for implementation notes and [CONTRIBUTING.md](CONTRIBUTING.md) for contributions.

### Checks and packaging

This update (2026-09-30) ran static syntax, encoding, example JSON, local link checks, and
secret scans of publication files and Git history.
Regression scripts, GUI operations, live subscriptions, and proxy connectivity were not run.

Maintainers can run regression checks when needed:

```powershell
.\build.ps1 -Validate
```

This parses the PowerShell AST, runs regression checks in a temporary directory, and attempts
to read the local core version. It does not validate live subscriptions, the complete GUI
workflow, or the entire binary supply chain.

Build a portable package:

```powershell
.\build.ps1
```

Normal packaging reads local settings to restore instance directories, then uses an archive
allowlist that excludes actual settings and runtime data.
The packaged `config/settings.json` comes from the empty example.
**If a local `mihomo.exe` exists, the package includes that binary.**
Source publication and binary distribution are separate scopes; review binary provenance,
third-party licensing, and corresponding source directions before publishing a ZIP with the core.

Normal packaging preserves runtime data. `-Clean` / `-CleanOnly` delete instance runtime files,
logs, download caches, and local audit artifacts under `.codex/`.
Stop project cores and retain needed backups before cleaning. Packaging and cleanup were not run here.

### Limitations

- Windows / amd64 only; the GUI is currently in Chinese.
- Subscriptions must contain nodes usable by proxy-providers; arbitrary complete Clash configurations are not guaranteed.
- GUI network operations are synchronous; large node tests may temporarily reduce responsiveness.
- Gemini probes use no API key. HTTP 400 / 403 may be marked available, which does not establish
  account access, quota, regional entitlement, or a successful model call.
- Gemini tests temporarily change the primary group's node and may affect active applications.
- General instances expose ports without automatically changing arbitrary application settings.
- An existing IDE may need to exit completely before restarting with new proxy settings.
- Clash switching needs an existing local listener on `7898` and does not configure Clash.

### Security

Subscription URLs can contain credentials and are stored in plaintext in local settings and
generated configuration. The controller API is configured on `127.0.0.1` with a random local
secret; these measures do not replace filesystem access controls.
Do not publish real configuration, logs, entry backups, or sensitive screen content.
Subscription providers are not verified. See [SECURITY.md](SECURITY.md) for reporting.

### License

Management scripts and documentation use the [MIT License](LICENSE), retaining the original
copyright attribution.
The pinned Mihomo version uses [GNU GPL v3](https://github.com/MetaCubeX/mihomo/blob/v1.19.30/LICENSE);
MIT does not replace its license. This is not an official Antigravity, Google, or Mihomo product.
