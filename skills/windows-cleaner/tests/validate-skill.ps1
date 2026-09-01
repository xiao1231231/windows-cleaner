[CmdletBinding()]
param(
    [string]$SkillDirectory = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

try {
    $resolvedSkill = (Resolve-Path -LiteralPath $SkillDirectory -ErrorAction Stop).Path
    $folderName = Split-Path -Leaf $resolvedSkill
    if ($folderName.Length -gt 64 -or $folderName -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw 'The Skill folder name must use lowercase letters, digits, and single hyphens, with at most 64 characters.'
    }

    $skillFile = Join-Path $resolvedSkill 'SKILL.md'
    if (-not [IO.File]::Exists($skillFile)) {
        throw 'SKILL.md is required.'
    }

    $lines = [IO.File]::ReadAllLines($skillFile, [Text.Encoding]::UTF8)
    if ($lines.Count -lt 5 -or $lines[0] -ne '---') {
        throw 'SKILL.md must begin with YAML frontmatter.'
    }

    $closingIndex = -1
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -eq '---') {
            $closingIndex = $index
            break
        }
    }
    if ($closingIndex -lt 3) {
        throw 'SKILL.md frontmatter must have a closing delimiter and required fields.'
    }

    $frontmatter = @($lines[1..($closingIndex - 1)])
    $nameMatches = @($frontmatter | Where-Object { $_ -match '^name\s*:' })
    $descriptionMatches = @($frontmatter | Where-Object { $_ -match '^description\s*:' })
    if ($nameMatches.Count -ne 1) {
        throw 'SKILL.md frontmatter must contain exactly one top-level name field.'
    }
    if ($descriptionMatches.Count -ne 1) {
        throw 'SKILL.md frontmatter must contain exactly one top-level description field.'
    }

    $name = ($nameMatches[0] -replace '^name\s*:\s*', '').Trim().Trim('"').Trim("'")
    $description = ($descriptionMatches[0] -replace '^description\s*:\s*', '').Trim().Trim('"').Trim("'")
    if ($name -ne $folderName) {
        throw ('SKILL.md name must match the folder name: ' + $folderName)
    }
    if ($name.Length -gt 64 -or $name -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw 'SKILL.md name has an invalid format.'
    }
    if ([string]::IsNullOrWhiteSpace($description) -or $description.Length -gt 1024) {
        throw 'SKILL.md description must contain 1 to 1024 characters.'
    }
    if ($description.Contains('<') -or $description.Contains('>')) {
        throw 'SKILL.md description must not contain angle brackets.'
    }

    $bodyLines = @($lines[($closingIndex + 1)..($lines.Count - 1)])
    if ([string]::IsNullOrWhiteSpace(($bodyLines -join [Environment]::NewLine))) {
        throw 'SKILL.md must contain an instruction body after frontmatter.'
    }
    if (($lines -join [Environment]::NewLine) -match '(?i)<TODO>|\[TODO\]') {
        throw 'SKILL.md contains an unfinished TODO placeholder.'
    }

    foreach ($relativePath in @(
        'agents\openai.yaml',
        'scripts\delete.ps1',
        'scripts\scan-common.ps1',
        'scripts\scan-disk.ps1',
        'scripts\scan.ps1',
        'tests\safety.ps1',
        'tests\validate-skill.ps1'
    )) {
        if (-not [IO.File]::Exists((Join-Path $resolvedSkill $relativePath))) {
            throw ('Required Skill file is missing: ' + $relativePath)
        }
    }

    Write-Output ('VALID_SKILL  ' + $resolvedSkill)
} catch {
    throw ('INVALID_SKILL  ' + $_.Exception.Message)
}
