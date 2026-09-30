# Technical Notes / 技术说明

维护更新 / Maintenance update: 2026-09-30 (Codex)

## 中文

### 架构与启动

- GUI 使用 WinForms；CMD 入口默认使用 Windows PowerShell 5.1，PowerShell 7 可直接运行 PS1。
- 主代理默认端口为 `7899`，控制端口为 `19090`；通用实例拥有独立进程、目录、端口和密钥。
- 所有实例共用根目录中的 Mihomo 可执行文件，固定版本为 `v1.19.30`。
- 默认设置由 `New-DefaultSettings` 在内存中创建；公开示例不是 GUI 读取的配置模板。
- `start.ps1` 通过进程环境变量传递根目录；启动器按主脚本入口标记装载函数定义。
- GUI 关闭后后台核心继续运行；停止核心、删除配置和清理目录是不同操作。

### 数据与兼容性

- PowerShell 使用 UTF-8 BOM；Markdown、JSON 和格式规则使用 UTF-8 无 BOM。
- Mihomo JSON 显式按 UTF-8 解码，保留中文节点名和 Emoji。
- `PortMappings` 按数组处理，避免单元素管道结果被解包为标量。
- 设置保存使用临时文件和备份；损坏的主配置不得覆盖有效备份。
- 实例 ID 限制为安全字符，并按 Windows 大小写不敏感规则去重。
- 用户设置、订阅、控制密钥、缓存、日志、入口备份和审计产物不得进入公开文件集。

### 进程与入口修改

- 主核心管理核对 PID、启动时间、可执行文件及配置路径；身份不明确时应停止操作。
- 专用启动器以进程环境变量和 Electron 参数应用代理，不修改系统代理。
- 保存入口会改写快捷方式、CLI 包装器和部分安装入口；Clash 切换还会退出相关应用。
- 非标准安装目录应通过 GUI 设置或环境目录发现，不在公开源码中固化个人路径。
- Gemini 探测不包含真实认证，端点响应不能证明服务业务可用性。

### 检查与发布

- `build.ps1 -Validate` 执行 AST 解析、临时目录中的回归脚本和本地核心版本检查。
- 普通打包读取本地设置以恢复实例目录；归档白名单不复制真实设置和运行数据。
- 便携包可能含本机 Mihomo 二进制；公开源码不含核心，二进制发行需另审来源和许可证。
- 清理参数会删除运行文件和 `.codex/`；应先停核心并保留所需本地报告。
- 本次只运行静态解析、格式、链接及隐私 / 密钥扫描，没有运行测试、GUI 或构建。
- 发布扫描分别覆盖当前文件、暂存区和计划公开的历史；公开提交使用 GitHub 隐私邮箱。

## English

### Architecture and startup

- The GUI uses WinForms. CMD entry points default to Windows PowerShell 5.1; PowerShell 7 can run PS1 files directly.
- Primary defaults are proxy `7899` and controller `19090`; general instances have separate processes, directories, ports, and secrets.
- All instances share the root Mihomo executable, pinned to `v1.19.30`.
- `New-DefaultSettings` creates defaults in memory; the public example is not a template read by the GUI.
- `start.ps1` passes the root through a process environment variable; launchers load definitions using the main entry marker.
- Background cores remain active after the GUI closes. Stopping a core, deleting settings, and cleaning directories are separate operations.

### Data and compatibility

- PowerShell uses UTF-8 BOM; Markdown, JSON, and format rules use UTF-8 without BOM.
- Mihomo JSON is explicitly decoded as UTF-8 to preserve Chinese node names and emoji.
- Handle `PortMappings` as arrays to avoid unwrapping single-element pipeline results.
- Settings use temporary and backup files. A damaged primary must not replace a valid backup.
- Instance IDs accept safe characters and use Windows case-insensitive deduplication.
- User settings, subscriptions, controller secrets, caches, logs, entry backups, and audit artifacts must stay outside the publication set.

### Processes and launch entries

- Primary core management checks PID, start time, executable, and configuration path; ambiguous identity should stop the operation.
- Dedicated launchers apply process environment variables and Electron arguments without changing the system proxy.
- Saving entries changes shortcuts, CLI wrappers, and some installed entries. Clash switching also closes related applications.
- Discover nonstandard installations through GUI settings or environment directories, rather than embedding personal paths.
- Gemini probes perform no real authentication; endpoint responses do not establish business service availability.

### Checks and publication

- `build.ps1 -Validate` runs AST parsing, regression checks in a temporary directory, and a local core version check.
- Normal packaging reads local settings to restore instance directories; the archive allowlist excludes actual settings and runtime data.
- Portable packages may include a local Mihomo binary. Public source excludes the core; binary releases need separate provenance and license review.
- Cleanup flags delete runtime files and `.codex/`; stop cores and retain needed reports first.
- This update ran only static parsing, format, link, privacy, and secret checks; no tests, GUI operations, or builds.
- Publication scans cover current files, staged content, and intended public history separately; public commits use a GitHub privacy email.
