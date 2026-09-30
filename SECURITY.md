# Security Policy / 安全策略

## 中文

### 支持范围

安全修复面向默认分支的最新版本。旧版本可能不会单独获得修复。

### 报告漏洞

仓库启用私密漏洞报告后，请通过 **Security > Report a vulnerability** 提交安全问题。
如果该入口尚不可用，只在公开 Issue 中请求私密联系方式，不附漏洞细节或复现数据。
请勿在公开 Issue 中提交订阅 URL、控制密钥、日志、运行配置、个人路径或真实凭据。

报告中建议包含受影响版本、问题类型、影响范围、最小复现步骤和建议修复方向。维护者确认问题前，请勿公开披露细节。

### 本地数据

以下内容可能包含敏感信息，并已通过 `.gitignore` 排除：

- `config/settings.json`
- `runtime/`
- `providers/`
- `logs/`
- `cache.db`
- `mihomo.exe`
- 环境变量文件、私钥和证书容器、备份及 `.codex/` 下的本地审计产物

订阅 URL 和运行配置以明文保存；本地控制密钥不替代文件权限管理。
发布者应单独检查当前文件、暂存区和 Git 历史；`.gitignore` 不会删除已提交的数据。
公开仓库建立后，请在 GitHub 设置中启用可用的 secret scanning 和 push protection。
源码仓库不分发核心；包含 Mihomo 的发行包需要单独核对二进制来源、其许可证与对应源码说明。

如果这些文件曾被提交或发送到外部，请先轮换订阅凭据和控制密钥，再评估 Git 历史清理。

## English

### Supported versions

Security fixes target the latest revision on the default branch. Older revisions may not receive separate patches.

### Reporting a vulnerability

Once private vulnerability reporting is enabled, use **Security > Report a vulnerability**.
If that option is unavailable, open an issue only to request a private contact route, without
vulnerability details or reproduction data. Do not place subscription URLs, controller secrets,
logs, runtime configuration, personal paths, or live credentials in a public issue.

Include the affected revision, issue class, impact, minimal reproduction steps, and a suggested remediation when possible. Please avoid public disclosure until the maintainer has confirmed the issue.

### Local data

The following paths may contain sensitive data and are excluded by `.gitignore`:

- `config/settings.json`
- `runtime/`
- `providers/`
- `logs/`
- `cache.db`
- `mihomo.exe`
- Environment files, private keys, certificate containers, backups, and local audit artifacts under `.codex/`

Subscription URLs and generated configuration are stored in plaintext; local controller secrets
do not replace filesystem permissions. Review working files, staged content, and Git history
separately; `.gitignore` does not remove committed data. Once the public repository exists,
enable available GitHub secret scanning and push protection. The source repository does not
distribute the core; releases containing Mihomo require separate provenance, license, and
corresponding source review.

If any of these files were committed or shared externally, rotate subscription credentials and controller secrets before evaluating Git history cleanup.
