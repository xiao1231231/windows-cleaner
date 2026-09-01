[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$deleteScript = Join-Path $skillRoot 'scripts\delete.ps1'
$scanCommonScript = Join-Path $skillRoot 'scripts\scan-common.ps1'
$scanScript = Join-Path $skillRoot 'scripts\scan.ps1'
$diskScanScript = Join-Path $skillRoot 'scripts\scan-disk.ps1'
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

function ConvertFrom-TestJson {
    param([string]$Text)
    try {
        return ($Text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("windows-cleaner-test-" + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$commaPath = Join-Path $testRoot 'cache,old.tmp'
[IO.File]::WriteAllText($commaPath, 'fixture')
$executePath = Join-Path $testRoot 'execute.tmp'
[IO.File]::WriteAllText($executePath, 'fixture')
$jsonExecutePath = Join-Path $testRoot 'json-execute.tmp'
[IO.File]::WriteAllText($jsonExecutePath, 'fixture')
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
$countTree = Join-Path $testRoot 'count-tree'
$countTreeChild = Join-Path $countTree 'child'
[IO.Directory]::CreateDirectory($countTreeChild) | Out-Null
[IO.File]::WriteAllText((Join-Path $countTreeChild 'one.tmp'), 'fixture')
$lockedTree = Join-Path $testRoot 'locked-tree'
$lockedFile = Join-Path $lockedTree 'locked.tmp'
[IO.Directory]::CreateDirectory($lockedTree) | Out-Null
[IO.File]::WriteAllText($lockedFile, 'fixture')
$aclDeleteTree = Join-Path $testRoot 'acl-delete-tree'
$aclDeleteFile = Join-Path $aclDeleteTree 'denied.tmp'
[IO.Directory]::CreateDirectory($aclDeleteTree) | Out-Null
[IO.File]::WriteAllText($aclDeleteFile, 'fixture')
$aclInspectTree = Join-Path $testRoot 'acl-inspect-tree'
[IO.Directory]::CreateDirectory($aclInspectTree) | Out-Null
[IO.File]::WriteAllText((Join-Path $aclInspectTree 'hidden.tmp'), 'fixture')
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
$substParallelA = Join-Path $substRoot 'parallel-a'
$substParallelB = Join-Path $substRoot 'parallel-b'
[IO.Directory]::CreateDirectory($substParallelA) | Out-Null
[IO.Directory]::CreateDirectory($substParallelB) | Out-Null
[IO.File]::WriteAllText((Join-Path $substParallelA 'a.tmp'), 'fixture-a')
[IO.File]::WriteAllText((Join-Path $substParallelB 'b.tmp'), 'fixture-b')
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
    Assert-True ($preview -match 'child_count=0') 'Preview reports a file target with an explicit child_count of zero.'
    $countPreview = Invoke-Text { & $deleteScript -Paths $countTree }
    Assert-True ($countPreview -match 'child_count=2') 'Preview child_count includes directory descendants but excludes the target root.'

    $jsonPreviewText = Invoke-Text { & $deleteScript -Paths $commaPath -OutputFormat Json }
    $jsonPreview = ConvertFrom-TestJson -Text $jsonPreviewText
    Assert-True ($null -ne $jsonPreview) 'JSON preview output is valid JSON.'
    if ($null -ne $jsonPreview) {
        Assert-True ($jsonPreview.schema_version -eq 1) 'JSON preview declares schema version 1.'
        Assert-True ($jsonPreview.mode -eq 'preview') 'JSON preview identifies preview mode.'
        Assert-True ($jsonPreview.events[0].status -eq 'PLAN') 'JSON preview exposes a structured PLAN event.'
        Assert-True ($jsonPreview.events[0].child_count -eq 0) 'JSON preview uses child_count for snapshot traversal.'
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$jsonPreview.plan_token)) 'JSON preview exposes the PlanToken as a top-level field.'
        Assert-True ($jsonPreview.summary.planned -eq 1) 'JSON preview exposes structured summary counts.'
    }

    $global:SafetyTestRemoveCalls.Clear()
    $provider = Invoke-Text { & $deleteScript -Paths 'HKCU:\Environment' }
    Assert-True ($provider -match 'BLOCK.*FileSystem') 'Delete rejects non-FileSystem providers.'
    Assert-True ($global:SafetyTestRemoveCalls.Count -eq 0) 'Provider rejection never calls Remove-Item.'
    $jsonBlockedText = Invoke-Text { & $deleteScript -Paths 'HKCU:\Environment' -OutputFormat Json }
    $jsonBlocked = ConvertFrom-TestJson -Text $jsonBlockedText
    Assert-True ($null -ne $jsonBlocked -and $jsonBlocked.summary.blocked -gt 0) 'JSON output remains valid for a blocked preview.'

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
        $junctionDescendant = Join-Path $junctionPath 'target-data.tmp'
        $junctionDescendantDeleteResult = Invoke-Text { & $deleteScript -Paths $junctionDescendant }
        Assert-True ($junctionDescendantDeleteResult -match 'BLOCK.*path contains.*reparse point') 'Delete rejects a regular target reached through a reparse-point ancestor.'
        $junctionParentResult = Invoke-Text { & $deleteScript -Paths $junctionParent }
        Assert-True ($junctionParentResult -match 'BLOCK.*contains reparse point') 'Delete rejects a tree containing a reparse point.'
        Assert-True ($global:SafetyTestRemoveCalls.Count -eq 0) 'Reparse-point rejection never calls Remove-Item.'
    }

    $aclInspectSddl = $null
    $aclInspectApplied = $false
    try {
        $aclInspectAcl = Get-Acl -LiteralPath $aclInspectTree
        $aclInspectSddl = $aclInspectAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $inspectDeny = New-Object Security.AccessControl.FileSystemAccessRule(
            $currentSid,
            [Security.AccessControl.FileSystemRights]::ReadData,
            [Security.AccessControl.InheritanceFlags]::None,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Deny
        )
        $aclInspectAcl.AddAccessRule($inspectDeny)
        Set-Acl -LiteralPath $aclInspectTree -AclObject $aclInspectAcl
        $probeEnumerator = $null
        try {
            $probeEnumerator = [IO.DirectoryInfo]::new($aclInspectTree).EnumerateFileSystemInfos().GetEnumerator()
            $null = $probeEnumerator.MoveNext()
            $aclInspectApplied = $false
        } catch [UnauthorizedAccessException] {
            $aclInspectApplied = $true
        } finally {
            if ($null -ne $probeEnumerator) { $probeEnumerator.Dispose() }
        }
        if ($aclInspectApplied) {
            $inspectionFailure = Invoke-Text { & $deleteScript -Paths $aclInspectTree }
            Assert-True ($inspectionFailure -match 'BLOCK.*cannot fully inspect') 'Delete fails closed when streaming tree inspection is denied by an ACL.'
            . $scanCommonScript
            $sampledMeasurement = Measure-WindowsCleanerTree -FullPath $aclInspectTree -ErrorSampleLimit 1
            $unsampledMeasurement = Measure-WindowsCleanerTree -FullPath $aclInspectTree -ErrorSampleLimit 0
            Assert-True ($sampledMeasurement.Errors -gt 0) 'A denied scan increments the complete error counter.'
            Assert-True (@($sampledMeasurement.ErrorSamples).Count -eq 1) 'A denied scan returns a bounded error sample with its path and reason.'
            Assert-True (@($unsampledMeasurement.ErrorSamples).Count -eq 0) 'Error samples can be disabled without disabling error counting.'
            Assert-True ($sampledMeasurement.Errors -eq $unsampledMeasurement.Errors) 'Error sampling does not change the total error count.'
        } else {
            Write-Output 'SKIP  The filesystem did not enforce the temporary list-directory deny ACL.'
        }
    } catch {
        Write-Output ('SKIP  The list-directory deny ACL fixture could not be established: ' + $_.Exception.Message)
    } finally {
        if ($null -ne $aclInspectSddl) {
            try {
                $restoreAcl = Get-Acl -LiteralPath $aclInspectTree
                $restoreAcl.SetSecurityDescriptorSddlForm($aclInspectSddl)
                Set-Acl -LiteralPath $aclInspectTree -AclObject $restoreAcl
            } catch {
                Write-Output ('FAIL  The list-directory fixture ACL could not be restored: ' + $_.Exception.Message)
                $failures.Add('The list-directory fixture ACL could not be restored.')
            }
        }
    }

    $scanProvider = Invoke-Text { & $scanScript -Paths 'HKCU:\Environment' }
    Assert-True ($scanProvider -match 'INVALID.*FileSystem') 'Scan rejects non-FileSystem providers.'

    $scanComma = Invoke-Text { & $scanScript -Paths $commaPath }
    Assert-True ($scanComma -match 'COMPLETE') 'Scan accepts a literal path containing a comma.'
    Assert-True ($scanComma -notmatch 'INVALID|MISSING') 'Scan does not split a comma-containing path.'
    Assert-True ($scanComma -match 'files=1 dirs=0 skipped_reparse=0 errors=0') 'Scan reports exact counters for a regular file.'

    $scanCompleteProcess = ((& powershell.exe -NoProfile -File $scanScript -Paths $commaPath 2>&1) | Out-String)
    $scanCompleteExit = $LASTEXITCODE
    Assert-True ($scanCompleteProcess -match 'COMPLETE') 'A complete scan reports COMPLETE in a child process.'
    Assert-True ($scanCompleteExit -eq 0) 'A complete scan returns exit code 0.'

    $scanRelative = Invoke-Text { & $scanScript -Paths 'relative-cache.tmp' }
    Assert-True ($scanRelative -match 'INVALID.*absolute FileSystem path') 'Scan rejects relative paths.'

    $scanInvalidProcess = ((& powershell.exe -NoProfile -File $scanScript -Paths 'relative-cache.tmp' 2>&1) | Out-String)
    $scanInvalidExit = $LASTEXITCODE
    Assert-True ($scanInvalidProcess -match 'INVALID') 'An invalid scan reports INVALID in a child process.'
    Assert-True ($scanInvalidExit -eq 2) 'An invalid scan returns exit code 2.'

    if ($junctionCreated) {
        $scanJunctionTarget = Invoke-Text { & $scanScript -Paths $junctionPath }
        Assert-True ($scanJunctionTarget -match 'INVALID.*target is a junction') 'Scan rejects a reparse-point target.'
        $junctionDescendant = Join-Path $junctionPath 'target-data.tmp'
        $scanJunctionDescendant = Invoke-Text { & $scanScript -Paths $junctionDescendant }
        Assert-True ($scanJunctionDescendant -match 'INVALID.*path contains.*reparse point') 'Scan rejects a regular target reached through a reparse-point ancestor.'
        $scanJunctionParent = Invoke-Text { & $scanScript -Paths $junctionParent }
        Assert-True ($scanJunctionParent -match 'COMPLETE.*files=0 dirs=0 skipped_reparse=1 errors=0') 'Scan skips a child reparse point without traversing its target.'
    }

    $diskScanRelative = Invoke-Text { & $diskScanScript -Drive 'relative-drive' }
    Assert-True ($diskScanRelative -match 'INVALID.*absolute local FileSystem drive root') 'Disk scan rejects relative paths.'
    $diskInvalidProcess = ((& powershell.exe -NoProfile -File $diskScanScript -Drive 'relative-drive' 2>&1) | Out-String)
    $diskInvalidExit = $LASTEXITCODE
    Assert-True ($diskInvalidProcess -match 'INVALID') 'An invalid disk scan reports INVALID in a child process.'
    Assert-True ($diskInvalidExit -eq 2) 'An invalid disk scan returns exit code 2.'
    $diskScanDirectory = Invoke-Text { & $diskScanScript -Drive $testRoot }
    Assert-True ($diskScanDirectory -match 'INVALID.*only a drive root') 'Disk scan rejects a non-root directory.'
    $diskScanProvider = Invoke-Text { & $diskScanScript -Drive 'HKCU:\Environment' }
    Assert-True ($diskScanProvider -match 'INVALID.*FileSystem') 'Disk scan rejects non-FileSystem providers.'
    if ($substCreated) {
        $diskScanRoot = Invoke-Text { & $diskScanScript -Drive ($substLetter + ':\') }
        Assert-True ($diskScanRoot -match 'COMPLETE.*scope=disk.*files=3 dirs=2 skipped_reparse=0 errors=0') 'Disk scan measures a local drive root in one pass.'
        Assert-True ($diskScanRoot -match '(?m)^PROGRESS\s+') 'Disk scan reports bounded main-thread progress.'
        Assert-True ($diskScanRoot -match 'ENTRY\s+COMPLETE.*pagefile\.sys.*files=1 dirs=0 skipped_reparse=0 errors=0') 'Disk scan reports root entries without deleting or hiding protected filenames.'
        $diskScanQuiet = Invoke-Text { & $diskScanScript -Drive ($substLetter + ':\') -NoProgress }
        Assert-True ($diskScanQuiet -notmatch '(?m)^PROGRESS\s+') 'Disk scan progress can be disabled for automation.'
        $savedErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $diskParallelProcess = ((& powershell.exe -NoProfile -File $diskScanScript -Drive ($substLetter + ':\') -Threads 2 2>&1) | Out-String)
            $diskParallelExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }
        Assert-True ($diskParallelProcess -match 'COMPLETE.*scope=disk.*files=3 dirs=2 skipped_reparse=0 errors=0 workers=2') 'Disk scan reports and honors an explicit parallel worker count.'
        Assert-True ($diskParallelExit -eq 0) 'A parallel disk scan returns exit code 0 for a complete scan.'
    }

    . $scanCommonScript
    $exitCodeHelper = Get-Command Get-WindowsCleanerScanExitCode -ErrorAction SilentlyContinue
    Assert-True ($null -ne $exitCodeHelper) 'Scan common code exposes a shared exit-code policy.'
    if ($null -ne $exitCodeHelper) {
        Assert-True ((Get-WindowsCleanerScanExitCode -HadInvalid $false -HadPartial $false) -eq 0) 'Exit-code policy maps complete scans to 0.'
        Assert-True ((Get-WindowsCleanerScanExitCode -HadInvalid $true -HadPartial $false) -eq 2) 'Exit-code policy maps invalid scans to 2.'
        Assert-True ((Get-WindowsCleanerScanExitCode -HadInvalid $false -HadPartial $true) -eq 3) 'Exit-code policy maps partial scans to 3.'
        Assert-True ((Get-WindowsCleanerScanExitCode -HadInvalid $true -HadPartial $true) -eq 2) 'Invalid takes precedence over partial in the exit-code policy.'
    }

    $skillText = [IO.File]::ReadAllText((Join-Path $skillRoot 'SKILL.md'), [Text.Encoding]::UTF8)
    Assert-True ($skillText -notmatch 'Remove-Item\s+-LiteralPath') 'SKILL.md does not provide a raw Remove-Item recipe.'
    Assert-True ($skillText -notmatch '(?i)powershell[^\r\n]*-ExecutionPolicy\s+Bypass') 'SKILL.md does not recommend ExecutionPolicy Bypass.'
    Assert-True ($skillText -match 'PLAN_TOKEN') 'SKILL.md documents the preview token protocol.'
    $samePersistentTerminalText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('5ZCM5LiA5Liq5oyB5LmF57uI56uv'))
    Assert-True ($skillText -match [regex]::Escape($samePersistentTerminalText)) 'SKILL.md prefers preview and execute in one built-in persistent terminal.'
    Assert-True ($skillText -match 'ACCESS_OK') 'SKILL.md documents the batch delete-access preflight.'
    Assert-True ($skillText -match '\-Threads 1') 'SKILL.md documents the serial fallback for disk scanning.'
    Assert-True ($skillText -match 'ERROR_SAMPLE') 'SKILL.md documents bounded scan error samples.'
    Assert-True ($skillText -match 'child_count') 'SKILL.md documents snapshot child-count semantics.'
    Assert-True ($skillText -match 'checked_items') 'SKILL.md documents delete-access checked-item semantics.'
    Assert-True ($skillText -match 'OutputFormat Json') 'SKILL.md documents structured JSON deletion output.'

    $directExecute = ((& powershell.exe -NoProfile -File $deleteScript -Paths $directExecutePath -Execute 2>&1) | Out-String)
    Assert-True ($directExecute -match 'BLOCK.*PlanToken') 'Execute refuses to run without a preview PlanToken.'
    Assert-True ([IO.File]::Exists($directExecutePath)) 'Missing-token rejection leaves the fixture unchanged.'

    $foreignContextToken = [Convert]::ToBase64String([byte[]](1..64))
    $foreignContextResult = ((& powershell.exe -NoProfile -File $deleteScript -Paths $tamperedTokenPath -PlanToken $foreignContextToken -Execute 2>&1) | Out-String)
    Assert-True ($foreignContextResult -match 'BLOCK.*same.*terminal|BLOCK.*host context') 'An undecryptable PlanToken explains that preview and execute must share a host context.'
    Assert-True ([IO.File]::Exists($tamperedTokenPath)) 'Host-context token rejection leaves the fixture unchanged.'

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

    $jsonExecutePreviewText = ((& powershell.exe -NoProfile -File $deleteScript -Paths $jsonExecutePath -OutputFormat Json 2>&1) | Out-String)
    $jsonExecutePreview = ConvertFrom-TestJson -Text $jsonExecutePreviewText
    $jsonExecuteToken = if ($null -ne $jsonExecutePreview) { [string]$jsonExecutePreview.plan_token } else { '' }
    $jsonExecuteText = ((& powershell.exe -NoProfile -File $deleteScript -Paths $jsonExecutePath -PlanToken $jsonExecuteToken -Execute -OutputFormat Json 2>&1) | Out-String)
    $jsonExecute = ConvertFrom-TestJson -Text $jsonExecuteText
    Assert-True ($null -ne $jsonExecute) 'JSON execute output is valid JSON.'
    if ($null -ne $jsonExecute) {
        Assert-True ($jsonExecute.mode -eq 'execute') 'JSON execute identifies execute mode.'
        Assert-True (@($jsonExecute.events | Where-Object { $_.status -eq 'ACCESS_OK' -and $_.checked_items -eq 1 }).Count -eq 1) 'JSON execute reports checked_items for ACCESS_OK.'
        Assert-True (@($jsonExecute.events | Where-Object { $_.status -eq 'DELETED' }).Count -eq 1) 'JSON execute exposes a structured DELETED event.'
        Assert-True ($jsonExecute.summary.deleted -eq 1) 'JSON execute exposes structured deletion counts.'
    }
    Assert-True (-not [IO.File]::Exists($jsonExecutePath)) 'JSON execute verifies the fixture is gone.'

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

    $lockedPreview = ((& powershell.exe -NoProfile -File $deleteScript -Paths $lockedTree 2>&1) | Out-String)
    $lockedToken = Get-PlanToken -Text $lockedPreview
    $lockStream = [IO.File]::Open($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $lockedResult = ((& powershell.exe -NoProfile -File $deleteScript -Paths $lockedTree -PlanToken $lockedToken -Execute 2>&1) | Out-String)
    } finally {
        $lockStream.Dispose()
    }
    Assert-True ($lockedResult -match 'BLOCK.*delete-access preflight') 'Execute blocks the whole batch when a target is locked or lacks delete access.'
    Assert-True ($lockedResult -notmatch 'PARTIAL_OR_FAILED') 'Delete-access preflight avoids entering partial deletion for a known access failure.'
    Assert-True ([IO.File]::Exists($lockedFile)) 'Delete-access preflight leaves a locked fixture unchanged.'

    $aclDeleteTreeSddl = $null
    $aclDeleteFileSddl = $null
    try {
        $aclDeleteTreeAcl = Get-Acl -LiteralPath $aclDeleteTree
        $aclDeleteFileAcl = Get-Acl -LiteralPath $aclDeleteFile
        $aclDeleteTreeSddl = $aclDeleteTreeAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
        $aclDeleteFileSddl = $aclDeleteFileAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $fileDeleteDeny = New-Object Security.AccessControl.FileSystemAccessRule($currentSid, [Security.AccessControl.FileSystemRights]::Delete, [Security.AccessControl.AccessControlType]::Deny)
        $parentDeleteChildDeny = New-Object Security.AccessControl.FileSystemAccessRule($currentSid, [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles, [Security.AccessControl.AccessControlType]::Deny)
        $aclDeleteFileAcl.AddAccessRule($fileDeleteDeny)
        $aclDeleteTreeAcl.AddAccessRule($parentDeleteChildDeny)
        Set-Acl -LiteralPath $aclDeleteFile -AclObject $aclDeleteFileAcl
        Set-Acl -LiteralPath $aclDeleteTree -AclObject $aclDeleteTreeAcl

        $aclPreview = ((& powershell.exe -NoProfile -File $deleteScript -Paths $aclDeleteFile 2>&1) | Out-String)
        $aclToken = Get-PlanToken -Text $aclPreview
        $aclResult = ((& powershell.exe -NoProfile -File $deleteScript -Paths $aclDeleteFile -PlanToken $aclToken -Execute 2>&1) | Out-String)
        Assert-True ($aclResult -match 'BLOCK.*delete-access preflight') 'A real delete deny ACL blocks the whole batch before mutation.'
        Assert-True ($aclResult -notmatch 'PARTIAL_OR_FAILED') 'A real delete deny ACL never enters partial deletion.'
        Assert-True ([IO.File]::Exists($aclDeleteFile)) 'A real delete deny ACL leaves the fixture unchanged.'
    } catch {
        Write-Output ('SKIP  The delete deny ACL fixture could not be established: ' + $_.Exception.Message)
    } finally {
        if ($null -ne $aclDeleteTreeSddl) {
            try {
                $restoreTreeAcl = Get-Acl -LiteralPath $aclDeleteTree
                $restoreTreeAcl.SetSecurityDescriptorSddlForm($aclDeleteTreeSddl)
                Set-Acl -LiteralPath $aclDeleteTree -AclObject $restoreTreeAcl
            } catch {
                Write-Output ('FAIL  The delete fixture parent ACL could not be restored: ' + $_.Exception.Message)
                $failures.Add('The delete fixture parent ACL could not be restored.')
            }
        }
        if ($null -ne $aclDeleteFileSddl) {
            try {
                $restoreFileAcl = Get-Acl -LiteralPath $aclDeleteFile
                $restoreFileAcl.SetSecurityDescriptorSddlForm($aclDeleteFileSddl)
                Set-Acl -LiteralPath $aclDeleteFile -AclObject $restoreFileAcl
            } catch {
                Write-Output ('FAIL  The delete fixture file ACL could not be restored: ' + $_.Exception.Message)
                $failures.Add('The delete fixture file ACL could not be restored.')
            }
        }
    }

    $confirmPreview = ((& powershell.exe -NoProfile -File $deleteScript -Paths $confirmPath 2>&1) | Out-String)
    $confirmToken = Get-PlanToken -Text $confirmPreview
    $confirmCommand = "`$ConfirmPreference='Medium'; & '" + $deleteScript.Replace("'", "''") + "' -Paths '" + $confirmPath.Replace("'", "''") + "' -PlanToken '" + $confirmToken.Replace("'", "''") + "' -Execute"
    $confirmResult = ((& powershell.exe -NoProfile -NonInteractive -Command $confirmCommand 2>&1) | Out-String)
    Assert-True ($confirmResult -match '(?m)^DELETED\s+') 'Execute remains noninteractive when caller ConfirmPreference is Medium.'
    Assert-True (-not [IO.File]::Exists($confirmPath)) 'Noninteractive execute verifies the fixture is gone.'
}
finally {
    Microsoft.PowerShell.Management\Remove-Item function:\global:Remove-Item -ErrorAction SilentlyContinue
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
