# Windows Cleaner

[English](README_EN.md)

Windows Cleaner 是一个面向 AI Agent 的 Windows 磁盘空间分析与安全清理 Skill。它先进行只读扫描和风险分级，只有在用户逐项确认完整路径并完成删除预览后，才允许执行永久删除。

> [!WARNING]
> 删除操作不经过回收站。任何用途不明的文件或目录都应默认保留，并先向用户确认。

> [!IMPORTANT]
> **列出风险清单后，必须逐项详细询问再决定是否删除。** Agent 应向用户说明并确认每一项的具体用途、删除后果、可恢复性，以及是否会导致配置或离线数据丢失、重新登录、重新下载、重建索引或应用异常。用户明确回答前不得进入删除预览；回答仍不清楚或无法确认时默认保留。不得仅凭“看起来像缓存”、文件名或大模型自身判断跳过询问，以防模型误判造成重要数据丢失。

## 主要特点

- 默认只读，不会在扫描阶段删除文件。
- 删除前必须生成绑定目标快照的 `PLAN_TOKEN`。
- 拒绝磁盘根目录、系统目录、个人资料目录、项目目录、敏感配置和 reparse point。
- 支持用户通过 `-ProtectedPaths` 补充受保护路径。
- 预览后目标发生变化时拒绝执行，要求重新扫描和确认。
- 不提升管理员权限，不绕过 PowerShell 执行策略。
- 包含可重复运行的 PowerShell 安全测试。

## 运行要求

- Windows 10/11 或 Windows Server
- Windows PowerShell 5.1
- 支持 `SKILL.md` Skill 格式并能调用 Windows PowerShell 的 AI Agent

本项目不限定单一 Agent。`agents/openai.yaml` 只是 Codex 的可选界面元数据；安全规则和删除授权始终由 `SKILL.md` 与 `scripts/` 中的脚本共同实施。

## 仓库结构

```text
skills/windows-cleaner/
├── SKILL.md
├── agents/openai.yaml
├── scripts/scan.ps1
├── scripts/delete.ps1
└── tests/safety.ps1
```

## 安装

### Codex

下载或克隆本仓库后，将 `skills/windows-cleaner` 整个目录复制到：

```text
%USERPROFILE%\.codex\skills\windows-cleaner
```

PowerShell 示例（在仓库根目录执行）：

```powershell
$destination = Join-Path $env:USERPROFILE ".codex\skills\windows-cleaner"
Copy-Item -LiteralPath ".\skills\windows-cleaner" -Destination $destination -Recurse
```

如果目标目录已经存在，请先自行核对差异，不要直接覆盖。安装后新建一个 Agent 任务，再使用 `$windows-cleaner`。

### 其他 Agent

将 `skills/windows-cleaner` 复制到该 Agent 规定的 Skill 目录。目标 Agent 必须能够读取 `SKILL.md` 并调用 Windows PowerShell；不支持该格式的 Agent 不能直接使用本项目。

## 使用

使用 Agent 时可以直接提出：

```text
使用 $windows-cleaner 分析 C 盘空间，只生成清理建议，不要删除。
```

只读扫描脚本也可以独立运行：

```powershell
powershell -NoProfile -File ".\skills\windows-cleaner\scripts\scan.ps1" -Paths "C:\Users\<用户>\AppData\Local\Temp"
```

删除脚本默认只生成预览，不执行删除：

```powershell
powershell -NoProfile -File ".\skills\windows-cleaner\scripts\delete.ps1" -Paths "C:\待确认的缓存目录"
```

只有用户明确批准预览中原样显示的完整路径后，Agent 才能使用返回的 `PLAN_TOKEN` 执行。完整授权流程、安全边界和结果状态请以 [`SKILL.md`](skills/windows-cleaner/SKILL.md) 为准。

## 测试

```powershell
powershell -NoProfile -File ".\skills\windows-cleaner\tests\safety.ps1"
```

测试应以 `PASSED: all safety tests` 结束。GitHub Actions 也会在推送和拉取请求时运行同一套检查。

## 安全问题

请阅读 [SECURITY.md](SECURITY.md)。涉及潜在误删、保护绕过或任意路径删除的问题，请使用 GitHub Private Vulnerability Reporting 私下报告，不要先公开利用细节。

## 许可证

本项目采用 [MIT License](LICENSE)。MIT 允许个人和企业免费使用、修改、分发及商业使用，但必须保留版权和许可证声明；软件按“原样”提供，不附带担保。
