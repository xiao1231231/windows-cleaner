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
3. 分析整盘时先使用 `scripts/scan-disk.ps1` 对本地盘符根目录做一次遍历并按一级项目从大到小输出；扫描器可在互不重叠的一级目录之间受控并行，但每棵目录树仍只能遍历一次。再使用 `scripts/scan.ps1` 精查选中的候选目录，避免重复扫描相互重叠的大目录。
4. 识别每个候选项的所有者、用途、最近修改时间、运行中的相关进程和可恢复性。
5. 生成清单；每项列出规范化路径、逻辑大小估算、扫描完整性、风险、影响和建议。
6. 展示风险清单后提醒用户检查所有“待确认”项；逐项询问用途并等待答复，根据用户返回的具体用途重新评估。未确认项保持保留，不进入后续删除流程。
7. 对其余候选删除路径运行 `scripts/delete.ps1` 的默认预览模式，把所有 `PLAN`/`BLOCK` 输出展示给用户，并由 Agent 在当前任务中原样保留 `PLAN_TOKEN`；不要求用户复制或辨认令牌。如用户补充了保护项，必须同时传入 `-ProtectedPaths`。任一目标为 `BLOCK` 时整批不会签发令牌。若后续可能执行，优先在客户端内置的同一个持久终端中完成预览、等待确认和执行；在启动该终端前先取得目标路径所需的写权限，不复用权限状态过期的旧终端。
8. 明确告知用户该操作是永久删除、不经过回收站。只对用户明确批准且预览为 `PLAN` 的原样路径，加 `-PlanToken <PLAN_TOKEN> -Execute` 执行。执行时的 `-Paths` 与 `-ProtectedPaths` 必须和获批预览完全一致；脚本、路径、保护列表或目标元数据发生任何变化时重新预览和确认。`PLAN_TOKEN` 还绑定 Windows DPAPI 宿主安全上下文：内置终端将要执行时，必须由该内置终端生成令牌；不要把其他沙箱、外部终端或不同 Windows 身份生成的令牌带入执行。内置终端因访问控制无法执行时保持 `BLOCK`，再把同一路径和保护列表交给本地安全执行脚本重新预览，不绕过权限。
9. 删除后重新扫描目标和磁盘可用空间，报告 `DELETED`、`PARTIAL_OR_FAILED`、`BLOCK` 等实际结果。

## 只读扫描

整盘初筛使用 `scan-disk.ps1`。它只接受本地 FileSystem 盘符根目录，拒绝普通目录、UNC 和网络盘；每个一级项目只遍历一次，不跟随 reparse point。扫描器默认按处理器数量使用最多 8 个 worker，只在互不重叠的盘符根一级目录之间并行，目录内仍保持流式单次遍历。`-Threads 1` 可恢复串行模式；机械盘、系统正在高负载或并行扫描反而变慢时使用。`-Top` 仅限制展示的最大项目数量，汇总仍包含全部可读取项目，存在错误的项目始终展示。默认在每个盘符根一级目录完成时由主线程输出一行 `PROGRESS`；需要静默调用时传 `-NoProgress`。`-ErrorSampleLimit` 控制最多展示多少条访问错误样本，默认 5、设为 0 可关闭样本，但不会改变完整 `errors` 计数：

```powershell
powershell -NoProfile -File "<skill目录>\scripts\scan-disk.ps1" -Drive "C:\" -Top 30 -Threads 8 -ErrorSampleLimit 5
```

整盘输出中，`PROGRESS` 只表示已完成的一级目录数，不是大小百分比；磁盘汇总中的 `workers` 是本次配置的并发数；`ENTRY` 是按逻辑大小降序排列的盘符根目录一级项目；`SKIPPED` 是未跟随的根级 reparse point；`ERROR_SAMPLE` 给出有限数量的典型失败路径和系统返回原因。任一不可读取目录或文件元数据错误都会让对应项目及磁盘汇总成为 `PARTIAL`，大小是下限。错误样本只是诊断示例，`errors` 才是完整错误总数；达到样本上限不会停止计数。并行只改变调度，不降低 `PARTIAL`、错误计数和 reparse point 检查。整盘扫描不是文件系统的原子时间点快照，扫描期间仍在写入的目录可能让相邻两次结果略有差异。整盘初筛后只对需要进一步判断的 `ENTRY` 使用 `scan.ps1`，不要再次扫描已经能直接分类的小项目。

候选目录或单个文件使用 `scan.ps1`。扫描器会逐级检查从盘符根目录到目标的每个路径组件，拒绝路径链中任何 junction、符号链接或其他 reparse point；遍历期间也会在打开目录前再次检查其属性。从任意 shell 调用时，每次传一个完整路径最稳妥：

```powershell
powershell -NoProfile -File "<skill目录>\scripts\scan.ps1" -Paths "C:\Users\<用户>\AppData\Local\Temp" -ErrorSampleLimit 5
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

扫描脚本的进程退出码同时表达批次状态：`0` 表示全部 `COMPLETE`，`1` 表示未处理的脚本内部错误，`2` 表示至少一个输入为 `INVALID`，`3` 表示没有 `INVALID` 但至少一个结果为 `PARTIAL`。多个路径中只要出现 `INVALID`，退出码 `2` 优先于 `3`；调用者仍须读取每一行状态，不能只凭退出码推断具体目标。

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

删除脚本默认只生成计划，不删除。`PLAN_TOKEN` 绑定当前 Windows 用户、当前脚本、规范化路径、保护列表、文件系统元数据快照及生成它的 DPAPI 宿主安全上下文；它不能代替用户批准，Agent 必须先展示风险和 `PLAN` 路径并等待用户明确答复。Agent 只需在当前任务中保留令牌，不要让用户手动复制长字符串。优先在已具备目标写权限的客户端内置持久终端中预览并在同一终端执行；令牌无法解密、脚本发生变化、宿主安全上下文改变或 Windows 身份切换时，必须在将要执行的终端重新预览。

从 Bash、cmd、PowerShell 或其他宿主调用时，一次处理一个目标最不容易传错参数；若用户没有补充保护项，省略 `-ProtectedPaths`：

```powershell
powershell -NoProfile -File "<skill目录>\scripts\delete.ps1" -Paths "C:\Users\<用户>\AppData\Local\Temp\verified-cache" -ProtectedPaths "D:\用户指定保留的目录"
```

将 `PLAN` 输出中的完整路径、后代项目数 `child_count`、快照和永久删除影响逐项发给用户。`child_count` 不含目标本身：单个文件为 0，目录为其全部后代文件和目录数。只有用户明确批准后，Agent 才把预览输出的单行令牌原样传回脚本：

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

快照使用路径、类型、大小、时间戳和属性检测预览后的变化，不读取或散列文件内容。树检查采用流式枚举，只保存待遍历目录，不把平目录的全部子项一次性载入内存；任一枚举或元数据访问错误仍立即失败关闭。预览后让相关应用保持关闭；如果内容变化，脚本会 `BLOCK` 并要求重新预览。执行模式还会在任何删除发生前，对整批目标逐项做只读删除权限和共享占用预检；全部通过时输出 `ACCESS_OK`，其中 `checked_items` 是权限预检实际检查的项目数并包含目标本身。任一项缺少有效删除权限或被不共享删除的句柄锁定时整批 `BLOCK`。该预检能避免已知权限/占用问题造成的部分删除，但无法消除预检之后发生的极窄竞争窗口，因此仍不要在活跃写入目录中执行整树删除。

自动化消费者需要稳定字段时，可在预览和执行两次调用中都传 `-OutputFormat Json`；默认 `Text` 保持面向人工的既有状态行。JSON 顶层包含 `schema_version`、`mode`、`events`、`plan_token` 和 `summary`，事件使用 `status`、`path`、`reason`、`child_count`、`checked_items`、`snapshot`。JSON 只改变输出格式，不改变令牌绑定、逐项批准、整批权限预检或任何保护边界；同一批预览与执行仍必须使用完全相同的路径和保护列表。

结果含义：

- `PLAN`：仅预览，未删除。
- `PLAN_TOKEN`：本次预览的受保护执行令牌；只能在用户批准同一批内容后原样使用。
- `ACCESS_OK`：执行前只读权限/占用预检通过，尚未因该行发生删除。
- `DELETED`：删除后确认目标不存在。
- `BLOCK`：安全验证未通过，没有执行删除。
- `PARTIAL_OR_FAILED`：可能已发生部分删除，目标仍存在；立即停止后续批次并重新扫描。
- `DELETED_WITH_ERROR`：目标已消失但命令报告异常；记录异常并验证周边目录。

## 汇报

汇报清理前后每个磁盘的可用空间、每个目标的实际状态、未处理项及原因。磁盘可用空间可能受后台下载、更新和临时文件变化影响，不把前后差值简单等同于删除项大小。

扫描任务完成并列出“优先清理”“需要确认”“默认保留”等候选项目后，必须在整份候选清单末尾单独追加以下原文提示，使其明确适用于清单中的所有项目；不要把它埋在某个项目说明里，也不要省略或改写成含义更弱的表述：

> 如果对文件作用有不清楚的地方请详细询问具体作用和删除后果后再进行决策
