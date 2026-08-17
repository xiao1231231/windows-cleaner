---
name: windows-cleaner
description: Windows 磁盘空间分析与安全清理。用于检查本地磁盘或目录占用、查找大文件和缓存、生成带风险分级的清理清单，以及在用户逐项批准后执行受保护的删除流程。触发场景包括 C/D/E 等本地盘空间不足、Windows 临时文件或应用缓存分析、安装包残留检查和磁盘清理验证。
---

# Windows 磁盘空间分析与安全清理

始终使用中文回复。目标是帮助用户释放空间并最大限度降低误删风险；不要承诺绝对不会误删。

本 Skill 的流程与具体 Agent 平台无关，适用于 Claude Code、Codex 及其他能够读取本文件并调用 Windows PowerShell 的 Agent。`SKILL.md` 与 `scripts/` 是唯一必需的运行协议；`agents/` 下的文件只用于特定客户端的可选展示，不得作为安全判断或删除授权的来源。所有 Agent 都必须调用同一套脚本，不能在宿主提示词中复制一套较弱的删除逻辑。不支持此 Skill 格式或无法调用 Windows PowerShell 的 Agent 不在适用范围内。

## 安全边界

1. 默认只读。未经用户对规范化后的完整路径逐项批准，不执行删除。
2. 只处理本地 `FileSystem` 路径。拒绝注册表、证书等其他 PowerShell Provider、相对路径和盘符根目录。
3. 不提升管理员权限，不绕过访问控制，不使用 `-ExecutionPolicy Bypass`，也不由 Agent 自行改成 `RemoteSigned` 等执行策略。若系统策略阻止脚本运行，停止操作并请用户或管理员处理；失败属于安全停止，不改用其他删除命令。
4. 不直接删除 Windows、Program Files、ProgramData、用户目录根、Downloads 根、OneDrive 根、公共文档、桌面、文档、图片、音乐、视频、收藏夹、项目目录、`.vscode`、Keil 目录，或 `.ssh`、`.git`、`.svn`、`.hg`、`.claude`、`.codex`、`.gnupg`、`.env`、`.npmrc` 等敏感配置。此列表是基础保护项；主动提醒用户可以自行补充需要保护的文件或目录。把用户补充项记录为规范化的绝对路径，并在每次预览和执行时通过 `-ProtectedPaths` 原样传给删除脚本。
5. 不直接删除 `pagefile.sys`、`hiberfil.sys`、`swapfile.sys`、System Volume Information、Recovery、Boot、EFI、WinSxS、Windows Update 组件或系统还原数据。需要处理时说明影响并使用 Windows 官方设置、Storage Sense、`powercfg` 或 DISM 等受支持机制。
6. 不把扩展名、目录名或注册表中的安装记录单独作为“可安全删除”的证据。
7. 路径显示乱码、扫描不完整、身份不明或安全检查返回 `BLOCK`/`INVALID` 时停止，不自行绕过。
8. 对用途不明确的文件或目录标记为“待确认”，主动询问用户其来源和具体用途并等待答复；收到明确说明前不得进入删除预览。用户未回复或回复后仍无法确认时默认保留。
9. 禁止手写或直接调用 `Remove-Item`、`del`、`rd`、`rm`。所有删除只能通过 `scripts/delete.ps1`。

## 标准流程

1. 确认分析范围，以及用户当前只要报告还是也可能批准后续删除。
2. 记录清理前各磁盘的总容量和可用空间。
3. 使用 `scripts/scan.ps1` 扫描候选目录，从大到小定位占用来源。
4. 识别每个候选项的所有者、用途、最近修改时间、运行中的相关进程和可恢复性。
5. 生成清单；每项列出规范化路径、逻辑大小估算、扫描完整性、风险、影响和建议。
6. 展示风险清单后提醒用户检查所有“待确认”项；逐项询问用途并等待答复，根据用户返回的具体用途重新评估。未确认项保持保留，不进入后续删除流程。
7. 对其余候选删除路径运行 `scripts/delete.ps1` 的默认预览模式，把所有 `PLAN`/`BLOCK` 输出展示给用户，并由 Agent 在当前任务中原样保留 `PLAN_TOKEN`；不要求用户复制或辨认令牌。如用户补充了保护项，必须同时传入 `-ProtectedPaths`。任一目标为 `BLOCK` 时整批不会签发令牌。
8. 明确告知用户该操作是永久删除、不经过回收站。只对用户明确批准且预览为 `PLAN` 的原样路径，加 `-PlanToken <PLAN_TOKEN> -Execute` 执行。执行时的 `-Paths` 与 `-ProtectedPaths` 必须和获批预览完全一致；脚本、路径、保护列表或目标元数据发生任何变化时重新预览和确认。
9. 删除后重新扫描目标和磁盘可用空间，报告 `DELETED`、`PARTIAL_OR_FAILED`、`BLOCK` 等实际结果。

## 只读扫描

从任意 shell 调用时，每次传一个完整路径最稳妥：

```powershell
powershell -NoProfile -File "<skill目录>\scripts\scan.ps1" -Paths "C:\Users\<用户>\AppData\Local\Temp"
```

已经处于 PowerShell 时可传真正的数组；不要用逗号拼接字符串：

```powershell
& "<skill目录>\scripts\scan.ps1" -Paths @(
    "C:\Users\<用户>\AppData\Local\Temp",
    "D:\Downloads\old-installer.exe"
)
```

解释扫描状态：

- `COMPLETE`：枚举过程中未遇到访问错误。
- `PARTIAL`：有目录无法读取；结果是下限，不能据此断言目录完整大小。
- `INVALID`：不是受支持的绝对文件系统路径，或目标是 reparse point。
- `logical` 是逻辑文件大小估算，不等于实际占用或最终可释放空间；硬链接、压缩、稀疏文件和云占位文件会产生差异。
- `skipped_reparse` 大于 0 时，报告中明确说明未统计链接目标。

可用空间总览使用只读命令：

```powershell
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    Select-Object DeviceID,
        @{n="TotalGB";e={[math]::Round($_.Size/1GB,1)}},
        @{n="FreeGB";e={[math]::Round($_.FreeSpace/1GB,1)}}
```

## 候选项与风险分级

优先调查明确的临时目录、应用官方缓存目录、包管理器缓存和已验证的升级残留。优先使用应用或包管理器提供的清理命令，并在相关应用退出后操作。

| 风险 | 判断标准 | 默认动作 |
|---|---|---|
| 低 | 官方明确标记为可重建缓存，应用已退出，扫描完整 | 可建议清理，仍需预览和批准 |
| 中 | 删除后需要重新下载、重新登录或重建索引 | 说明代价后谨慎建议 |
| 高 | 身份不明、配置、离线数据、安装器、存档或可能含个人资料 | 默认保留 |
| 禁止 | 系统关键目录、项目、个人文档、保护树或 reparse point | 不执行删除 |

> **注意：**列出风险清单后，明确提醒用户检查其中用途不清楚的文件或目录。把这些项目标记为“待确认”，主动询问用户它们的来源和具体用途，等待用户答复后再决定保留还是进入删除预览；不得用猜测代替确认。

`.exe`、`.zip`、`.rar` 可能是便携程序、固件或资料包；浏览器和桌面应用的 `Cache` 目录也可能影响当前会话。不能仅凭名称或扩展名降为低风险。

## 删除预览与执行

删除脚本默认只生成计划，不删除。`PLAN_TOKEN` 绑定当前 Windows 用户、当前脚本、规范化路径、保护列表及文件系统元数据快照；它不能代替用户批准，Agent 必须先展示风险和 `PLAN` 路径并等待用户明确答复。Agent 只需在当前任务中保留令牌，不要让用户手动复制长字符串；令牌无法解密、脚本发生变化或宿主切换 Windows 身份时重新预览。

从 Bash、cmd、PowerShell 或其他宿主调用时，一次处理一个目标最不容易传错参数；若用户没有补充保护项，省略 `-ProtectedPaths`：

```powershell
powershell -NoProfile -File "<skill目录>\scripts\delete.ps1" -Paths "C:\Users\<用户>\AppData\Local\Temp\verified-cache" -ProtectedPaths "D:\用户指定保留的目录"
```

将 `PLAN` 输出中的完整路径、项目数、快照和永久删除影响逐项发给用户。只有用户明确批准后，Agent 才把预览输出的单行令牌原样传回脚本：

```powershell
powershell -NoProfile -File "<skill目录>\scripts\delete.ps1" -Paths "C:\Users\<用户>\AppData\Local\Temp\verified-cache" -ProtectedPaths "D:\用户指定保留的目录" -PlanToken "<PLAN_TOKEN>" -Execute
```

已经处于 PowerShell 时，可以使用真正的数组处理同一批目标；预览和执行必须复用完全相同的数组：

```powershell
$targets = @("C:\cache-a", "D:\cache-b")
$userProtected = @("D:\keep-a", "D:\keep-b")
& "<skill目录>\scripts\delete.ps1" -Paths $targets -ProtectedPaths $userProtected
# 等待用户批准后，把输出的 PLAN_TOKEN 保存到 $planToken，再执行：
& "<skill目录>\scripts\delete.ps1" -Paths $targets -ProtectedPaths $userProtected -PlanToken $planToken -Execute
```

`-ProtectedPaths` 同时保护指定路径、其下级路径以及会把该保护项一并删除的上级目标。脚本还会拒绝系统关键项、受保护目录的上级、敏感配置/版本库标记和顶层工程清单，并再次验证 Provider、绝对路径、保护目录、访问完整性、reparse point 与预览快照。任何 `BLOCK` 都视为最终拒绝；不要改用裸删除命令绕过。

快照使用路径、类型、大小、时间戳和属性检测预览后的变化，不读取或散列文件内容。预览后让相关应用保持关闭；如果内容变化，脚本会 `BLOCK` 并要求重新预览。极窄的最终校验到删除之间的竞争窗口无法完全消除，因此仍不要在活跃写入目录中执行整树删除。

结果含义：

- `PLAN`：仅预览，未删除。
- `PLAN_TOKEN`：本次预览的受保护执行令牌；只能在用户批准同一批内容后原样使用。
- `DELETED`：删除后确认目标不存在。
- `BLOCK`：安全验证未通过，没有执行删除。
- `PARTIAL_OR_FAILED`：可能已发生部分删除，目标仍存在；立即停止后续批次并重新扫描。
- `DELETED_WITH_ERROR`：目标已消失但命令报告异常；记录异常并验证周边目录。

## 汇报

汇报清理前后每个磁盘的可用空间、每个目标的实际状态、未处理项及原因。磁盘可用空间可能受后台下载、更新和临时文件变化影响，不把前后差值简单等同于删除项大小。
