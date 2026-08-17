[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$deleteScript = Join-Path $skillRoot 'scripts\delete.ps1'
$scanScript = Join-Path $skillRoot 'scripts\scan.ps1'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Output ("FAIL  " + $Message)
    } else {
        Write-Output ("PASS  " + $Message)
    }
}

function Invoke-Text {
    param([scriptblock]$Action)
    return ((& $Action 2>&1) | Out-String)
}

function Get-PlanToken {
    param([string]$Text)
    $match = [regex]::Match($Text, '(?m)^PLAN_TOKEN\s+(\S+)\s*$')
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("windows-cleaner-test-" + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$commaPath = Join-Path $testRoot 'cache,old.tmp'
[IO.File]::WriteAllText($commaPath, 'fixture')
$executePath = Join-Path $testRoot 'execute.tmp'
[IO.File]::WriteAllText($executePath, 'fixture')
$whatIfPath = Join-Path $testRoot 'whatif.tmp'
[IO.File]::WriteAllText($whatIfPath, 'fixture')
$confirmPath = Join-Path $testRoot 'confirm-preference.tmp'
[IO.File]::WriteAllText($confirmPath, 'fixture')
$directExecutePath = Join-Path $testRoot 'direct-execute.tmp'
[IO.File]::WriteAllText($directExecutePath, 'fixture')
$tamperedTokenPath = Join-Path $testRoot 'tampered-token.tmp'
[IO.File]::WriteAllText($tamperedTokenPath, 'fixture')
$changingPath = Join-Path $testRoot 'changing-cache'
[IO.Directory]::CreateDirectory($changingPath) | Out-Null
[IO.File]::WriteAllText((Join-Path $changingPath 'old.cache'), 'fixture')
$sensitiveDirectory = Join-Path $testRoot '.ssh'
[IO.Directory]::CreateDirectory($sensitiveDirectory) | Out-Null
[IO.File]::WriteAllText((Join-Path $sensitiveDirectory 'id_ed25519'), 'fixture')
$repositoryParent = Join-Path $testRoot 'repository-parent'
$repositoryMarker = Join-Path $repositoryParent '.git'
[IO.Directory]::CreateDirectory($repositoryMarker) | Out-Null
[IO.File]::WriteAllText((Join-Path $repositoryMarker 'config'), 'fixture')
$sensitiveFile = Join-Path $testRoot '.gitconfig'
[IO.File]::WriteAllText($sensitiveFile, 'fixture')
$svnParent = Join-Path $testRoot 'svn-project'
[IO.Directory]::CreateDirectory((Join-Path $svnParent '.svn')) | Out-Null
[IO.File]::WriteAllText((Join-Path $svnParent '.svn\wc.db'), 'fixture')
$hgParent = Join-Path $testRoot 'hg-project'
[IO.Directory]::CreateDirectory((Join-Path $hgParent '.hg')) | Out-Null
[IO.File]::WriteAllText((Join-Path $hgParent '.hg\requires'), 'fixture')
$packageProject = Join-Path $testRoot 'package-project'
[IO.Directory]::CreateDirectory($packageProject) | Out-Null
[IO.File]::WriteAllText((Join-Path $packageProject 'package.json'), '{}')
$environmentFile = Join-Path $testRoot '.env'
[IO.File]::WriteAllText($environmentFile, 'SECRET=fixture')
$npmrcFile = Join-Path $testRoot '.npmrc'
[IO.File]::WriteAllText($npmrcFile, '//registry/:_authToken=fixture')
$userProtectedPath = Join-Path $testRoot 'user-protected'
[IO.Directory]::CreateDirectory($userProtectedPath) | Out-Null
[IO.File]::WriteAllText((Join-Path $userProtectedPath 'keep.tmp'), 'fixture')
$userProtectedParent = Join-Path $testRoot 'protected-overlap-parent'
$userProtectedChild = Join-Path $userProtectedParent 'keep-this-child'
[IO.Directory]::CreateDirectory($userProtectedChild) | Out-Null
[IO.File]::WriteAllText((Join-Path $userProtectedChild 'keep.tmp'), 'fixture')
$junctionTarget = Join-Path $testRoot 'junction-target'
$junctionParent = Join-Path $testRoot 'junction-parent'
$junctionPath = Join-Path $junctionParent 'link'
[IO.Directory]::CreateDirectory($junctionTarget) | Out-Null
[IO.Directory]::CreateDirectory($junctionParent) | Out-Null
[IO.File]::WriteAllText((Join-Path $junctionTarget 'target-data.tmp'), 'fixture')
$junctionCreated = $false
try {
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget -ErrorAction Stop | Out-Null
    $junctionCreated = $true
} catch {
    Write-Output ('SKIP  Junction fixture could not be created: ' + $_.Exception.Message)
}

$substRoot = Join-Path $testRoot 'subst-root'
[IO.Directory]::CreateDirectory($substRoot) | Out-Null
[IO.File]::WriteAllText((Join-Path $substRoot 'pagefile.sys'), 'fixture')
$substLetter = $null
$substCreated = $false
foreach ($candidateLetter in [char[]]'ZYXWVUTSRQPONMLKJIHGFED') {
    if (-not (Test-Path ($candidateLetter + ':\'))) {
        $substLetter = [string]$candidateLetter
        break
    }
}
if ($substLetter) {
    & subst.exe ($substLetter + ':') $substRoot
    $substCreated = ($LASTEXITCODE -eq 0 -and (Test-Path ($substLetter + ':\')))
}
if (-not $substCreated) {
    Write-Output 'SKIP  A temporary subst drive could not be created.'
}

try {
    # Prevent the pre-fix script from performing any real deletion while guard tests run.
    $global:SafetyTestRemoveCalls = [System.Collections.Generic.List[string]]::new()
    function global:Remove-Item {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true)][string]$LiteralPath,
            [switch]$Recurse,
            [switch]$Force
        )
        $global:SafetyTestRemoveCalls.Add($LiteralPath)
    }

    $global:SafetyTestRemoveCalls.Clear()
    $preview = Invoke-Text { & $deleteScript -Paths $commaPath }
    Assert-True ($preview -match 'PLAN') 'Delete defaults to preview mode.'
    Assert-True ($global:SafetyTestRemoveCalls.Count -eq 0) 'Preview never calls Remove-Item.'
    Assert-True ($preview -notmatch 'MISSING') 'A comma in a valid path is not split.'

    $global:SafetyTestRemoveCalls.Clear()
    $provider = Invoke-Text { & $deleteScript -Paths 'HKCU:\Environment' }
    Assert-True ($provider -match 'BLOCK.*FileSystem') 'Delete rejects non-FileSystem providers.'
    Assert-True ($global:SafetyTestRemoveCalls.Count -eq 0) 'Provider rejection never calls Remove-Item.'

    $global:SafetyTestRemoveCalls.Clear()
    $driveRoot = Invoke-Text { & $deleteScript -Paths ([IO.Path]::GetPathRoot($testRoot)) }
    Assert-True ($driveRoot -match 'BLOCK.*drive roots are protected') 'Delete rejects drive roots before traversal.'
    Assert-True ($global:SafetyTestRemoveCalls.Count -eq 0) 'Drive-root rejection never calls Remove-Item.'

    $global:SafetyTestRemoveCalls.Clear()
    $profileRoot = Invoke-Text { & $deleteScript -Paths $env:USERPROFILE }
    Assert-True ($profileRoot -match 'BLOCK.*protected') 'Delete rejects the user profile root.'
    Assert-True ($global:SafetyTestRemoveCalls.Count -eq 0) 'Profile-root rejection never calls Remove-Item.'

    $desktopRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
    $desktop = Invoke-Text { & $deleteScript -Paths $desktopRoot }
    Assert-True ($desktop -match 'BLOCK.*protected tree') 'Delete rejects protected personal-data trees.'

    Push-Location $testRoot
    try {
        $relative = Invoke-Text { & $deleteScript -Paths 'cache,old.tmp' }
    } finally {
        Pop-Location
    }
    Assert-True ($relative -match 'BLOCK.*relative paths are not allowed') 'Delete rejects relative paths.'

    $global:SafetyTestRemoveCalls.Clear()
    $sensitiveDirectoryResult = Invoke-Text { & $deleteScript -Paths $sensitiveDirectory }
    Assert-True ($sensitiveDirectoryResult -match 'BLOCK.*sensitive') 'Delete rejects a sensitive configuration directory.'
    $repositoryParentResult = Invoke-Text { & $deleteScript -Paths $repositoryParent }
    Assert-True ($repositoryParentResult -match 'BLOCK.*sensitive') 'Delete rejects a parent tree containing a .git marker.'
    $sensitiveFileResult = Invoke-Text { & $deleteScript -Paths $sensitiveFile }
    Assert-True ($sensitiveFileResult -match 'BLOCK.*sensitive') 'Delete rejects a sensitive configuration file.'
    $svnResult = Invoke-Text { & $deleteScript -Paths $svnParent }
    Assert-True ($svnResult -match 'BLOCK.*sensitive') 'Delete rejects a Subversion project marker.'
    $hgResult = Invoke-Text { & $deleteScript -Paths $hgParent }
    Assert-True ($hgResult -match 'BLOCK.*sensitive') 'Delete rejects a Mercurial project marker.'
    $packageProjectResult = Invoke-Text { & $deleteScript -Paths $packageProject }
    Assert-True ($packageProjectResult -match 'BLOCK.*project') 'Delete rejects a top-level project manifest.'
    $environmentFileResult = Invoke-Text { & $deleteScript -Paths $environmentFile }
    Assert-True ($environmentFileResult -match 'BLOCK.*sensitive') 'Delete rejects a .env secrets file.'
    $npmrcResult = Invoke-Text { & $deleteScript -Paths $npmrcFile }
    Assert-True ($npmrcResult -match 'BLOCK.*sensitive') 'Delete rejects an .npmrc credentials file.'
    Assert-True ($global:SafetyTestRemoveCalls.Count -eq 0) 'Sensitive-path rejection never calls Remove-Item.'

    $savedSystemRoot = $env:SystemRoot
    try {
        $env:SystemRoot = Join-Path $testRoot 'spoofed-system-root'
        $trustedWindows = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
        $trustedSystemFile = Join-Path $trustedWindows 'System32\kernel32.dll'
        $trustedSystemResult = Invoke-Text { & $deleteScript -Paths $trustedSystemFile }
    } finally {
        $env:SystemRoot = $savedSystemRoot
    }
    Assert-True ($trustedSystemResult -match 'BLOCK.*protected tree') 'Trusted Windows protection survives a spoofed SystemRoot environment variable.'

    $protectedChild = Join-Path $testRoot 'protected-parent\protected-child'
    [IO.Directory]::CreateDirectory($protectedChild) | Out-Null
    $savedSystemRoot = $env:SystemRoot
    try {
        $env:SystemRoot = $protectedChild
        $protectedParentResult = Invoke-Text { & $deleteScript -Paths (Split-Path -Parent $protectedChild) }
    } finally {
        $env:SystemRoot = $savedSystemRoot
    }
    Assert-True ($protectedParentResult -match 'BLOCK.*contains protected') 'Delete rejects a parent containing a built-in protected tree.'

    $testProfile = Join-Path $testRoot 'test-profile'
    $downloadsRoot = Join-Path $testProfile 'Downloads'
    $downloadsChild = Join-Path $downloadsRoot 'approved-installer.tmp'
    $otherProfile = Join-Path (Split-Path -Parent $testProfile) 'other-profile'
    [IO.Directory]::CreateDirectory($downloadsRoot) | Out-Null
    [IO.Directory]::CreateDirectory($otherProfile) | Out-Null
    [IO.File]::WriteAllText($downloadsChild, 'fixture')
    [IO.File]::WriteAllText((Join-Path $otherProfile 'personal-data.tmp'), 'fixture')
    $savedUserProfile = $env:USERPROFILE
    try {
        $env:USERPROFILE = $testProfile
        $downloadsRootResult = Invoke-Text { & $deleteScript -Paths $downloadsRoot }
        $downloadsChildResult = Invoke-Text { & $deleteScript -Paths $downloadsChild }
        $otherProfileResult = Invoke-Text { & $deleteScript -Paths $otherProfile }
    } finally {
        $env:USERPROFILE = $savedUserProfile
    }
    Assert-True ($downloadsRootResult -match 'BLOCK.*personal-data root') 'Delete rejects the Downloads root itself.'
    Assert-True ($downloadsChildResult -match 'PLAN') 'Downloads descendants remain eligible for individual approval.'
    if ($otherProfileResult -notmatch 'BLOCK.*other user profile') {
        Write-Output ('DIAGNOSTIC other-profile result: ' + $otherProfileResult.Trim())
    }
    Assert-True ($otherProfileResult -match 'BLOCK.*other user profile') 'Delete rejects another user profile tree.'

    if ($substCreated) {
        $criticalRootFile = $substLetter + ':\pagefile.sys'
        $criticalRootResult = Invoke-Text { & $deleteScript -Paths $criticalRootFile }
        Assert-True ($criticalRootResult -match 'BLOCK.*critical root') 'Delete rejects a critical file at a drive root.'
    }

    $global:SafetyTestRemoveCalls.Clear()
    $userProtectedResult = Invoke-Text {
        & $deleteScript -Paths $userProtectedPath -ProtectedPaths $userProtectedPath
    }
    Assert-True ($userProtectedResult -match 'BLOCK.*user-protected') 'Delete enforces user-supplied protected paths.'
    $userProtectedParentResult = Invoke-Text {
        & $deleteScript -Paths $userProtectedParent -ProtectedPaths $userProtectedChild
    }
    Assert-True ($userProtectedParentResult -match 'BLOCK.*user-protected') 'Delete rejects a parent that overlaps a user-protected child.'
    $invalidProtectedResult = Invoke-Text {
        & $deleteScript -Paths $commaPath -ProtectedPaths 'relative-protected-path'
    }
    Assert-True ($invalidProtectedResult -match 'BLOCK.*invalid ProtectedPaths') 'Delete fails closed for an invalid user-protected path.'
    Assert-True ($global:SafetyTestRemoveCalls.Count -eq 0) 'User-protected rejection never calls Remove-Item.'

    if ($junctionCreated) {
        $global:SafetyTestRemoveCalls.Clear()
        $junctionTargetResult = Invoke-Text { & $deleteScript -Paths $junctionPath }
        Assert-True ($junctionTargetResult -match 'BLOCK.*target is a junction') 'Delete rejects a reparse-point target.'
        $junctionParentResult = Invoke-Text { & $deleteScript -Paths $junctionParent }
        Assert-True ($junctionParentResult -match 'BLOCK.*contains reparse point') 'Delete rejects a tree containing a reparse point.'
        Assert-True ($global:SafetyTestRemoveCalls.Count -eq 0) 'Reparse-point rejection never calls Remove-Item.'
    }

    function global:Get-ChildItem { throw 'simulated enumeration failure' }
    try {
        $inspectionFailure = Invoke-Text { & $deleteScript -Paths $testRoot }
    } finally {
        Microsoft.PowerShell.Management\Remove-Item function:\Get-ChildItem -ErrorAction SilentlyContinue
    }
    Assert-True ($inspectionFailure -match 'BLOCK.*cannot fully inspect') 'Delete fails closed when tree inspection is incomplete.'

    $scanProvider = Invoke-Text { & $scanScript -Paths 'HKCU:\Environment' }
    Assert-True ($scanProvider -match 'INVALID.*FileSystem') 'Scan rejects non-FileSystem providers.'

    $scanComma = Invoke-Text { & $scanScript -Paths $commaPath }
    Assert-True ($scanComma -match 'COMPLETE') 'Scan accepts a literal path containing a comma.'
    Assert-True ($scanComma -notmatch 'INVALID|MISSING') 'Scan does not split a comma-containing path.'

    $skillText = [IO.File]::ReadAllText((Join-Path $skillRoot 'SKILL.md'), [Text.Encoding]::UTF8)
    Assert-True ($skillText -notmatch 'Remove-Item\s+-LiteralPath') 'SKILL.md does not provide a raw Remove-Item recipe.'
    Assert-True ($skillText -notmatch '(?i)powershell[^\r\n]*-ExecutionPolicy\s+Bypass') 'SKILL.md does not recommend ExecutionPolicy Bypass.'
    Assert-True ($skillText -match 'PLAN_TOKEN') 'SKILL.md documents the preview token protocol.'

    $directExecute = ((& powershell.exe -NoProfile -File $deleteScript -Paths $directExecutePath -Execute 2>&1) | Out-String)
    Assert-True ($directExecute -match 'BLOCK.*PlanToken') 'Execute refuses to run without a preview PlanToken.'
    Assert-True ([IO.File]::Exists($directExecutePath)) 'Missing-token rejection leaves the fixture unchanged.'

    $whatIfPreview = ((& powershell.exe -NoProfile -File $deleteScript -Paths $whatIfPath 2>&1) | Out-String)
    $whatIfToken = Get-PlanToken -Text $whatIfPreview
    Assert-True (-not [string]::IsNullOrWhiteSpace($whatIfToken)) 'Preview emits a single PlanToken.'
    $whatIf = ((& powershell.exe -NoProfile -File $deleteScript -Paths $whatIfPath -PlanToken $whatIfToken -Execute -WhatIf 2>&1) | Out-String)
    Assert-True ($whatIf -match '(?m)^SKIP\s+') 'WhatIf declines the destructive operation.'
    Assert-True ([IO.File]::Exists($whatIfPath)) 'WhatIf leaves the temporary fixture unchanged.'

    $executePreview = ((& powershell.exe -NoProfile -File $deleteScript -Paths $executePath 2>&1) | Out-String)
    $executeToken = Get-PlanToken -Text $executePreview
    $execute = ((& powershell.exe -NoProfile -File $deleteScript -Paths $executePath -PlanToken $executeToken -Execute 2>&1) | Out-String)
    Assert-True ($execute -match '(?m)^DELETED\s+') 'Execute mode deletes an approved temporary fixture.'
    Assert-True (-not [IO.File]::Exists($executePath)) 'Execute mode verifies the fixture is gone.'

    $tamperedPreview = ((& powershell.exe -NoProfile -File $deleteScript -Paths $tamperedTokenPath 2>&1) | Out-String)
    $validTamperedToken = Get-PlanToken -Text $tamperedPreview
    $replacement = if ($validTamperedToken.StartsWith('A')) { 'B' } else { 'A' }
    $tamperedToken = $replacement + $validTamperedToken.Substring(1)
    $tamperedResult = ((& powershell.exe -NoProfile -File $deleteScript -Paths $tamperedTokenPath -PlanToken $tamperedToken -Execute 2>&1) | Out-String)
    Assert-True ($tamperedResult -match 'BLOCK.*invalid PlanToken') 'Execute rejects a tampered PlanToken.'
    Assert-True ([IO.File]::Exists($tamperedTokenPath)) 'Tampered-token rejection leaves the fixture unchanged.'

    $changingPreview = ((& powershell.exe -NoProfile -File $deleteScript -Paths $changingPath 2>&1) | Out-String)
    $changingToken = Get-PlanToken -Text $changingPreview
    [IO.File]::WriteAllText((Join-Path $changingPath 'important-document.docx'), 'created after preview')
    $changingResult = ((& powershell.exe -NoProfile -File $deleteScript -Paths $changingPath -PlanToken $changingToken -Execute 2>&1) | Out-String)
    Assert-True ($changingResult -match 'BLOCK.*changed since preview') 'Execute rejects a target whose contents changed after preview.'
    Assert-True ([IO.File]::Exists((Join-Path $changingPath 'important-document.docx'))) 'Snapshot rejection preserves files added after preview.'

    $confirmPreview = ((& powershell.exe -NoProfile -File $deleteScript -Paths $confirmPath 2>&1) | Out-String)
    $confirmToken = Get-PlanToken -Text $confirmPreview
    $confirmCommand = "`$ConfirmPreference='Medium'; & '" + $deleteScript.Replace("'", "''") + "' -Paths '" + $confirmPath.Replace("'", "''") + "' -PlanToken '" + $confirmToken.Replace("'", "''") + "' -Execute"
    $confirmResult = ((& powershell.exe -NoProfile -NonInteractive -Command $confirmCommand 2>&1) | Out-String)
    Assert-True ($confirmResult -match '(?m)^DELETED\s+') 'Execute remains noninteractive when caller ConfirmPreference is Medium.'
    Assert-True (-not [IO.File]::Exists($confirmPath)) 'Noninteractive execute verifies the fixture is gone.'
}
finally {
    Microsoft.PowerShell.Management\Remove-Item function:\global:Remove-Item -ErrorAction SilentlyContinue
    Microsoft.PowerShell.Management\Remove-Item function:\global:Get-ChildItem -ErrorAction SilentlyContinue
    Microsoft.PowerShell.Utility\Remove-Variable SafetyTestRemoveCalls -Scope Global -ErrorAction SilentlyContinue
    if ($junctionCreated -and [IO.Directory]::Exists($junctionPath)) {
        [IO.Directory]::Delete($junctionPath, $false)
    }
    if ($substCreated) {
        & subst.exe ($substLetter + ':') /D 2>$null
    }
    if ([IO.Directory]::Exists($testRoot)) {
        [IO.Directory]::Delete($testRoot, $true)
    }
}

if ($failures.Count -gt 0) {
    Write-Output ("FAILED: " + $failures.Count + " safety test(s)")
    exit 1
}

Write-Output 'PASSED: all safety tests'
exit 0
