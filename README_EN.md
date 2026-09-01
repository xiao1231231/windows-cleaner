# Windows Cleaner

[简体中文](README.md)

Windows Cleaner is a Windows disk-space analysis and safety-focused cleanup Skill for AI agents. It performs read-only scanning and risk classification first. Permanent deletion is available only after the user approves each normalized path and the script produces a bound preview token.

> [!WARNING]
> Deletion bypasses the Recycle Bin. Keep every file or directory whose purpose is unclear and ask the user before proceeding.

> [!IMPORTANT]
> **After presenting the risk list, resolve every item marked as requiring confirmation.** The agent must discuss unclear items in detail, including their purpose, deletion consequences, and recoverability. These items must not enter deletion preview until the user gives a clear answer; keep them when their impact remains uncertain. Candidates whose purpose and impact are already supported by reliable evidence must still be shown with their risks and approved individually, but the user need not repeat information that is already clear.

## Highlights

- Read-only by default.
- Whole-drive scanning supports controlled parallelism, main-thread progress, and bounded access-error samples.
- Requires a snapshot-bound `PLAN_TOKEN` before execution.
- Blocks drive roots, system locations, personal-data roots, AppData first-level roots, projects, sensitive configuration, and reparse points.
- Accepts user-supplied protected paths through `-ProtectedPaths`.
- Rejects execution when a target changes after preview.
- Supports stable structured JSON output for deletion results.
- Never elevates privileges or bypasses PowerShell execution policy.
- Includes repeatable PowerShell safety tests.

## Requirements

- Windows 10/11 or Windows Server
- Windows PowerShell 5.1
- An AI agent that supports the `SKILL.md` convention and can invoke Windows PowerShell

The workflow is not tied to one agent. `agents/openai.yaml` contains optional Codex UI metadata only; authorization and safety checks remain in `SKILL.md` and the bundled scripts.

## Repository layout

```text
skills/windows-cleaner/
├── SKILL.md
├── agents/openai.yaml
├── scripts/
│   ├── scan-common.ps1
│   ├── scan-disk.ps1
│   ├── scan.ps1
│   └── delete.ps1
└── tests/
    ├── safety.ps1
    └── validate-skill.ps1
```

## Installation

### Codex

Download or clone the repository, then copy the complete `skills/windows-cleaner` directory to:

```text
%USERPROFILE%\.codex\skills\windows-cleaner
```

PowerShell example from the repository root:

```powershell
$destination = Join-Path $env:USERPROFILE ".codex\skills\windows-cleaner"
Copy-Item -LiteralPath ".\skills\windows-cleaner" -Destination $destination -Recurse
```

If the destination already exists, inspect the differences instead of overwriting it blindly. Start a new agent task after installation, then invoke `$windows-cleaner`.

### Other agents

Copy `skills/windows-cleaner` into the Skill directory required by that agent. The agent must understand `SKILL.md` and be able to invoke Windows PowerShell.

## Usage

Example agent request:

```text
Use $windows-cleaner to analyze drive C. Produce recommendations only and do not delete anything.
```

Run the read-only scanner directly:

```powershell
powershell -NoProfile -File ".\skills\windows-cleaner\scripts\scan-disk.ps1" -Drive "C:\" -Top 30 -Threads 8
powershell -NoProfile -File ".\skills\windows-cleaner\scripts\scan.ps1" -Paths "C:\Users\<user>\AppData\Local\Temp"
```

`scan-disk.ps1` reports progress as root-level entries finish and emits a bounded set of `ERROR_SAMPLE` diagnostics. Use `-NoProgress` to suppress progress or `-ErrorSampleLimit 0` to suppress samples without changing the complete error count.

The deletion script previews by default:

```powershell
powershell -NoProfile -File ".\skills\windows-cleaner\scripts\delete.ps1" -Paths "C:\verified-cache-directory"
```

Automation can pass `-OutputFormat Json`. Combining it with `-WhatIf` still produces one parseable JSON document and records the skipped operation as a structured `SKIP` event.

Execution is allowed only after the user explicitly approves the exact normalized path shown in preview and the agent returns the emitted `PLAN_TOKEN`. See [`SKILL.md`](skills/windows-cleaner/SKILL.md) for the complete authorization protocol, safety boundaries, and result codes.

## Tests

```powershell
powershell -NoProfile -File ".\skills\windows-cleaner\tests\validate-skill.ps1"
powershell -NoProfile -File ".\skills\windows-cleaner\tests\safety.ps1"
```

The test run must end with `PASSED: all safety tests`. GitHub Actions runs the same checks for pushes and pull requests.

## Security

See [SECURITY.md](SECURITY.md). Report suspected protection bypasses, unintended deletions, or arbitrary-path deletion privately through GitHub Private Vulnerability Reporting before publishing details.

## License

This project is licensed under the [MIT License](LICENSE). The MIT License permits personal and commercial use, modification, and distribution as long as the copyright and license notices are retained. The software is provided without warranty.
