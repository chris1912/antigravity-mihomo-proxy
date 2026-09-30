# Contributing / 贡献指南

## 中文

### 提交问题

提交 Issue 前请确认问题能够在默认分支复现，并说明 Windows 版本、PowerShell 版本、操作步骤和脱敏后的错误信息。不要上传订阅地址、控制密钥、真实节点配置、日志全文或个人路径。

### 提交修改

1. 从默认分支创建功能分支。
2. 保持改动聚焦，避免无关重构或依赖变更。
3. 新增或修改的类、字段和方法应补充简洁中文注释。
4. PowerShell 脚本必须兼容 Windows PowerShell 5.1，并保持 UTF-8 BOM。
5. 运行验证命令：

   ```powershell
   .\build.ps1 -Validate
   ```

6. 确认 `git status --ignored --short` 中的本地设置、运行数据和日志仍处于忽略状态。
7. 逐项核对 `git diff --cached --name-only` 和暂存差异，扫描当前文件、暂存区及计划公开的 Git 历史。
   测试夹具使用虚构路径、节点和订阅，不使用真实数据；不要通过广泛排除目录绕过密钥扫描。
8. 公开提交使用 GitHub 提供的隐私邮箱，并避免把本地审计报告或截图加入提交。

只修改文档时，可执行 `git diff --check` 并核对相对链接和中英文一致性，按改动范围选择其他检查。
验证结果应说明实际运行的宿主版本、检查范围以及未运行的项目，不能把语法检查写成业务验证。

Pull Request 应说明变更目的、关键实现、验证结果和已知风险。涉及进程停止、路径删除、凭据存储或发布逻辑的修改需要额外说明安全边界。

## English

### Reporting an issue

Before opening an issue, confirm that it reproduces on the default branch. Include the Windows version, PowerShell version, reproduction steps, and redacted error details. Do not upload subscription URLs, controller secrets, real node configuration, complete logs, or personal paths.

### Submitting a change

1. Create a feature branch from the default branch.
2. Keep the change focused and avoid unrelated refactoring or dependency changes.
3. Add concise Chinese comments for new or modified classes, fields, and methods.
4. Keep PowerShell scripts compatible with Windows PowerShell 5.1 and encoded with a UTF-8 BOM.
5. Run the validation command:

   ```powershell
   .\build.ps1 -Validate
   ```

6. Confirm with `git status --ignored --short` that local settings, runtime data, and logs remain ignored.
7. Review `git diff --cached --name-only` and staged diffs individually; scan current files,
   staged content, and the Git history intended for publication. Fixtures must use fictional
   paths, nodes, and subscriptions. Do not bypass secret scanning with broad exclusions.
8. Use a GitHub privacy email for public commits and keep local audit reports and screenshots out of commits.

For documentation-only changes, run `git diff --check`, review relative links and bilingual
consistency, and select other checks according to scope. Describe the actual host version,
checks run, and skipped items; syntax checks must not be reported as business validation.

Pull requests should explain the purpose, key implementation details, validation results, and known risks. Changes involving process termination, path deletion, credential storage, or release behavior should describe their safety boundaries explicitly.
