# delete.ps1 - guarded deletion for explicitly approved FileSystem paths
# Preview: powershell -NoProfile -File delete.ps1 -Paths "C:\path"
# Execute: powershell -NoProfile -File delete.ps1 -Paths "C:\path" -PlanToken "<token>" -Execute

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Paths,

    [string[]]$ProtectedPaths = @(),

    [string]$PlanToken,

    [switch]$Execute
)

Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# Agent and automation hosts must never inherit a caller preference that triggers
# an interactive ShouldProcess prompt. -WhatIf remains supported.
$ConfirmPreference = 'High'

try {
    Add-Type -AssemblyName System.Security -ErrorAction Stop
} catch {
    Write-Output ('BLOCK  <batch>  ::  plan-token support is unavailable: ' + $_.Exception.Message)
    exit 2
}

function Test-SamePath {
    param([string]$Candidate, [string]$BasePath)

    if ([string]::IsNullOrWhiteSpace($Candidate) -or [string]::IsNullOrWhiteSpace($BasePath)) { return $false }
    return $Candidate.TrimEnd('\').Equals($BasePath.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}

function Test-SameOrChildPath {
    param([string]$Candidate, [string]$BasePath)

    if ([string]::IsNullOrWhiteSpace($Candidate) -or [string]::IsNullOrWhiteSpace($BasePath)) { return $false }
    $candidateValue = $Candidate.TrimEnd('\')
    $baseValue = $BasePath.TrimEnd('\')
    if ($candidateValue.Equals($baseValue, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $candidateValue.StartsWith($baseValue + '\', [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-CanonicalProtectionPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { return $null }
    try {
        $normalized = [IO.Path]::GetFullPath($Path)
        if ($normalized.StartsWith('\\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
        if (Test-Path -LiteralPath $Path) {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if ($item.PSProvider.Name -ne 'FileSystem') { return $null }
            $normalized = [IO.Path]::GetFullPath($item.FullName)
        }
        return $normalized
    } catch {
        return $null
    }
}

function Add-UniquePath {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )

    $canonical = ConvertTo-CanonicalProtectionPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($canonical)) { return }
    foreach ($existing in $List) {
        if (Test-SamePath -Candidate $canonical -BasePath $existing) { return }
    }
    $List.Add($canonical)
}

function Get-SpecialFolderPath {
    param([string]$Name)

    try {
        $folder = [Enum]::Parse([Environment+SpecialFolder], $Name)
        return [Environment]::GetFolderPath($folder)
    } catch {
        return $null
    }
}

function Get-ConfiguredDownloadsPath {
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders')
        if ($null -eq $key) { return $null }
        $value = $key.GetValue(
            '{374DE290-123F-4565-9164-39C4925E467B}',
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { return $null }
        return [Environment]::ExpandEnvironmentVariables($value)
    } catch {
        return $null
    } finally {
        if ($null -ne $key) { $key.Dispose() }
    }
}

function Get-SensitiveNameReason {
    param([string]$Name)

    if ($Name -match '^(?i:\.git|\.svn|\.hg|\.ssh|\.gnupg|\.claude|\.codex|\.config|\.aws|\.azure|\.kube|\.docker|\.terraform|\.idea|\.vscode|\.gitconfig|\.git-credentials|\.npmrc|\.pypirc|\.netrc|_netrc|\.env(?:\..+)?)$') {
        return ('sensitive configuration or repository marker: ' + $Name)
    }
    return $null
}

function Get-ProjectMarkerReason {
    param([string]$Name)

    if ($Name -match '^(?i:package\.json|cargo\.toml|go\.mod|pom\.xml|build\.gradle(?:\.kts)?|settings\.gradle(?:\.kts)?|cmakelists\.txt|platformio\.ini|.*\.(?:sln|csproj|fsproj|vbproj|vcxproj|xcodeproj|uvprojx|ioc))$') {
        return ('project marker: ' + $Name)
    }
    return $null
}

function Get-CriticalRootReason {
    param([string]$FullPath)

    $root = [IO.Path]::GetPathRoot($FullPath)
    if ([string]::IsNullOrWhiteSpace($root)) { return $null }
    $relative = $FullPath.Substring($root.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relative)) { return $null }
    $parts = @($relative -split '\\')
    $first = $parts[0]

    $criticalRootTrees = @('System Volume Information', 'Recovery', 'Boot', 'EFI', '$Recycle.Bin')
    if ($criticalRootTrees -contains $first) {
        return ('critical root tree: ' + $first)
    }

    $criticalRootFiles = @('pagefile.sys', 'hiberfil.sys', 'swapfile.sys', 'bootmgr', 'bootnxt', 'bootsect.bak', 'ntldr', 'ntdetect.com')
    if ($parts.Count -eq 1 -and $criticalRootFiles -contains $first) {
        return ('critical root file: ' + $first)
    }
    return $null
}

function Get-ProtectedReason {
    param([string]$FullPath)

    $root = [IO.Path]::GetPathRoot($FullPath)
    if (Test-SamePath -Candidate $FullPath -BasePath $root) {
        return 'drive roots are protected'
    }

    $criticalReason = Get-CriticalRootReason -FullPath $FullPath
    if ($criticalReason) { return $criticalReason }

    $protectedTrees = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @(
        $env:SystemRoot,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        (Get-SpecialFolderPath -Name 'Windows'),
        (Get-SpecialFolderPath -Name 'ProgramFiles'),
        (Get-SpecialFolderPath -Name 'ProgramFilesX86'),
        (Get-SpecialFolderPath -Name 'CommonApplicationData'),
        (Get-SpecialFolderPath -Name 'Desktop'),
        (Get-SpecialFolderPath -Name 'MyDocuments'),
        (Get-SpecialFolderPath -Name 'MyPictures'),
        (Get-SpecialFolderPath -Name 'MyMusic'),
        (Get-SpecialFolderPath -Name 'MyVideos'),
        (Get-SpecialFolderPath -Name 'Favorites'),
        (Get-SpecialFolderPath -Name 'CommonDocuments'),
        (Get-SpecialFolderPath -Name 'CommonPictures'),
        (Get-SpecialFolderPath -Name 'CommonMusic'),
        (Get-SpecialFolderPath -Name 'CommonVideos')
    )) {
        Add-UniquePath -List $protectedTrees -Path $path
    }

    foreach ($protected in $protectedTrees) {
        if (Test-SameOrChildPath -Candidate $FullPath -BasePath $protected) {
            return ('protected tree: ' + $protected)
        }
        if (Test-SameOrChildPath -Candidate $protected -BasePath $FullPath) {
            return ('target contains protected tree: ' + $protected)
        }
    }

    $protectedRoots = [System.Collections.Generic.List[string]]::new()
    $profilePaths = [System.Collections.Generic.List[string]]::new()
    $profileParentPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($profilePath in @($env:USERPROFILE, (Get-SpecialFolderPath -Name 'UserProfile'))) {
        Add-UniquePath -List $profilePaths -Path $profilePath
    }
    foreach ($profilePath in $profilePaths) {
        Add-UniquePath -List $protectedRoots -Path $profilePath
        $profileParent = Split-Path -Parent $profilePath
        Add-UniquePath -List $profileParentPaths -Path $profileParent
        Add-UniquePath -List $protectedRoots -Path $profileParent
        Add-UniquePath -List $protectedRoots -Path (Join-Path $profilePath 'Downloads')
    }
    foreach ($oneDrivePath in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
        Add-UniquePath -List $protectedRoots -Path $oneDrivePath
    }
    Add-UniquePath -List $protectedRoots -Path (Get-ConfiguredDownloadsPath)

    foreach ($protected in $protectedRoots) {
        if (Test-SamePath -Candidate $FullPath -BasePath $protected) {
            return ('protected personal-data root: ' + $protected)
        }
        if (Test-SameOrChildPath -Candidate $protected -BasePath $FullPath) {
            return ('target contains protected personal-data root: ' + $protected)
        }
    }

    foreach ($profileParent in $profileParentPaths) {
        if (-not (Test-SameOrChildPath -Candidate $FullPath -BasePath $profileParent)) { continue }
        $insideKnownProfile = $false
        foreach ($profilePath in $profilePaths) {
            if (Test-SameOrChildPath -Candidate $FullPath -BasePath $profilePath) {
                $insideKnownProfile = $true
                break
            }
        }
        if (-not $insideKnownProfile) {
            return ('other user profile tree is protected: ' + $FullPath)
        }
    }

    $segments = $FullPath -split '[\\/]'
    foreach ($segment in $segments) {
        $sensitiveReason = Get-SensitiveNameReason -Name $segment
        if ($sensitiveReason) { return $sensitiveReason }
        if ($segment -match '^(?i:keil.*|projects|code|work|dev)$') {
            return ('protected path segment: ' + $segment)
        }
    }

    $leafProjectReason = Get-ProjectMarkerReason -Name ([IO.Path]::GetFileName($FullPath))
    if ($leafProjectReason) { return $leafProjectReason }

    foreach ($protected in $script:NormalizedProtectedPaths) {
        if ((Test-SameOrChildPath -Candidate $FullPath -BasePath $protected) -or
            (Test-SameOrChildPath -Candidate $protected -BasePath $FullPath)) {
            return ('user-protected path overlaps target: ' + $protected)
        }
    }

    return $null
}

function Add-SnapshotRecord {
    param(
        [System.Security.Cryptography.HashAlgorithm]$Hasher,
        [byte[]]$Aggregate,
        [string]$Record
    )

    $digest = $Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Record))
    for ($index = 0; $index -lt $Aggregate.Length; $index++) {
        $Aggregate[$index] = $Aggregate[$index] -bxor $digest[$index]
    }
}

function ConvertTo-SnapshotHex {
    param([byte[]]$Bytes)
    return ([BitConverter]::ToString($Bytes).Replace('-', ''))
}

function Get-SnapshotRecord {
    param(
        [System.IO.FileSystemInfo]$Item,
        [string]$RelativePath
    )

    $kind = if ($Item.PSIsContainer) { 'D' } else { 'F' }
    $length = if ($Item.PSIsContainer) { 0 } else { [long]$Item.Length }
    return ($RelativePath + '|' + $kind + '|' + $length + '|' + $Item.LastWriteTimeUtc.Ticks + '|' + $Item.CreationTimeUtc.Ticks + '|' + [int]$Item.Attributes)
}

function Test-TreeSafety {
    param([System.IO.FileSystemInfo]$Item)

    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return [pscustomobject]@{ Safe=$false; Reason='target is a junction, symlink, or other reparse point'; ItemCount=0; Snapshot=$null }
    }

    $hasher = [Security.Cryptography.SHA256]::Create()
    [byte[]]$aggregate = New-Object byte[] 32
    try {
        Add-SnapshotRecord -Hasher $hasher -Aggregate $aggregate -Record (Get-SnapshotRecord -Item $Item -RelativePath '.')
        if (-not $Item.PSIsContainer) {
            Add-SnapshotRecord -Hasher $hasher -Aggregate $aggregate -Record 'COUNT|1'
            return [pscustomobject]@{ Safe=$true; Reason=$null; ItemCount=1; Snapshot=(ConvertTo-SnapshotHex -Bytes $aggregate) }
        }

        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push($Item.FullName)
        $count = 0
        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            try {
                $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
            } catch {
                return [pscustomobject]@{ Safe=$false; Reason=('cannot fully inspect ' + $current + ': ' + $_.Exception.Message); ItemCount=$count; Snapshot=$null }
            }

            $isTopLevel = $current.Equals($Item.FullName, [StringComparison]::OrdinalIgnoreCase)
            foreach ($child in $children) {
                $count++
                $relativePath = $child.FullName.Substring($Item.FullName.TrimEnd('\').Length).TrimStart('\')
                Add-SnapshotRecord -Hasher $hasher -Aggregate $aggregate -Record (Get-SnapshotRecord -Item $child -RelativePath $relativePath)

                $sensitiveReason = Get-SensitiveNameReason -Name $child.Name
                if ($sensitiveReason) {
                    return [pscustomobject]@{ Safe=$false; Reason=($sensitiveReason + ' at ' + $child.FullName); ItemCount=$count; Snapshot=$null }
                }
                if ($isTopLevel) {
                    $projectReason = Get-ProjectMarkerReason -Name $child.Name
                    if ($projectReason) {
                        return [pscustomobject]@{ Safe=$false; Reason=($projectReason + ' at ' + $child.FullName); ItemCount=$count; Snapshot=$null }
                    }
                }
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    return [pscustomobject]@{ Safe=$false; Reason=('contains reparse point: ' + $child.FullName); ItemCount=$count; Snapshot=$null }
                }
                if ($child.PSIsContainer) {
                    $stack.Push($child.FullName)
                }
            }
        }

        Add-SnapshotRecord -Hasher $hasher -Aggregate $aggregate -Record ('COUNT|' + $count)
        return [pscustomobject]@{ Safe=$true; Reason=$null; ItemCount=$count; Snapshot=(ConvertTo-SnapshotHex -Bytes $aggregate) }
    } finally {
        $hasher.Dispose()
    }
}

function Test-DeleteTarget {
    param([string]$Path)

    if ($script:ProtectedPathsError) {
        return [pscustomobject]@{ Safe=$false; Path=$Path; Reason=('invalid ProtectedPaths: ' + $script:ProtectedPathsError); ItemCount=0; Snapshot=$null }
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Safe=$false; Path=$Path; Reason='empty paths are not allowed'; ItemCount=0; Snapshot=$null }
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Safe=$false; Path=$Path; Reason=('path cannot be resolved: ' + $_.Exception.Message); ItemCount=0; Snapshot=$null }
    }

    if ($item.PSProvider.Name -ne 'FileSystem') {
        return [pscustomobject]@{ Safe=$false; Path=$Path; Reason=('only the FileSystem provider is allowed; got ' + $item.PSProvider.Name); ItemCount=0; Snapshot=$null }
    }
    if (-not [IO.Path]::IsPathRooted($Path)) {
        return [pscustomobject]@{ Safe=$false; Path=$Path; Reason='relative paths are not allowed'; ItemCount=0; Snapshot=$null }
    }

    $fullPath = [IO.Path]::GetFullPath($item.FullName)
    if ($fullPath.StartsWith('\\', [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Safe=$false; Path=$fullPath; Reason='UNC and network paths are not allowed'; ItemCount=0; Snapshot=$null }
    }
    try {
        $driveInfo = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($fullPath))
        if ($driveInfo.DriveType -eq [IO.DriveType]::Network) {
            return [pscustomobject]@{ Safe=$false; Path=$fullPath; Reason='network drives are not allowed'; ItemCount=0; Snapshot=$null }
        }
    } catch {
        return [pscustomobject]@{ Safe=$false; Path=$fullPath; Reason=('drive type cannot be verified: ' + $_.Exception.Message); ItemCount=0; Snapshot=$null }
    }

    $protectedReason = Get-ProtectedReason -FullPath $fullPath
    if ($protectedReason) {
        return [pscustomobject]@{ Safe=$false; Path=$fullPath; Reason=$protectedReason; ItemCount=0; Snapshot=$null }
    }

    $tree = Test-TreeSafety -Item $item
    return [pscustomobject]@{ Safe=$tree.Safe; Path=$fullPath; Reason=$tree.Reason; ItemCount=$tree.ItemCount; Snapshot=$tree.Snapshot }
}

function Get-CurrentScriptHash {
    $stream = [IO.File]::OpenRead($PSCommandPath)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return (ConvertTo-SnapshotHex -Bytes $hasher.ComputeHash($stream))
    } finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

function New-PlanToken {
    param(
        [string[]]$CanonicalPaths,
        [string[]]$CanonicalProtectedPaths,
        [string[]]$Snapshots
    )

    $payload = [ordered]@{
        Version = 1
        ScriptSha256 = Get-CurrentScriptHash
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        Paths = @($CanonicalPaths)
        ProtectedPaths = @($CanonicalProtectedPaths)
        Snapshots = @($Snapshots)
    }
    $json = $payload | ConvertTo-Json -Compress -Depth 4
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($json)
    $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
        $plainBytes,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Convert]::ToBase64String($protectedBytes)
}

function Read-PlanToken {
    param([string]$Token)

    try {
        $protectedBytes = [Convert]::FromBase64String($Token)
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $json = [Text.Encoding]::UTF8.GetString($plainBytes)
        return ($json | ConvertFrom-Json)
    } catch {
        throw ('invalid PlanToken: ' + $_.Exception.Message)
    }
}

function Test-StringArrayEqual {
    param(
        [object[]]$Left,
        [object[]]$Right
    )

    $leftValues = @($Left)
    $rightValues = @($Right)
    if ($leftValues.Count -ne $rightValues.Count) { return $false }
    for ($index = 0; $index -lt $leftValues.Count; $index++) {
        if (-not ([string]$leftValues[$index]).Equals([string]$rightValues[$index], [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}

$script:NormalizedProtectedPaths = @()
$script:ProtectedPathsError = $null
foreach ($protectedPath in $ProtectedPaths) {
    try {
        if ([string]::IsNullOrWhiteSpace($protectedPath)) {
            throw 'empty protected paths are not allowed'
        }
        if (-not [IO.Path]::IsPathRooted($protectedPath)) {
            throw ('relative protected path is not allowed: ' + $protectedPath)
        }

        $normalized = [IO.Path]::GetFullPath($protectedPath)
        if ($normalized.StartsWith('\\', [StringComparison]::OrdinalIgnoreCase)) {
            throw ('UNC or network protected path is not allowed: ' + $protectedPath)
        }
        $protectedDrive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($normalized))
        if ($protectedDrive.DriveType -eq [IO.DriveType]::Network) {
            throw ('network protected path is not allowed: ' + $protectedPath)
        }

        if (Test-Path -LiteralPath $protectedPath) {
            $protectedItem = Get-Item -LiteralPath $protectedPath -Force -ErrorAction Stop
            if ($protectedItem.PSProvider.Name -ne 'FileSystem') {
                throw ('protected path is not a FileSystem path: ' + $protectedPath)
            }
            $normalized = [IO.Path]::GetFullPath($protectedItem.FullName)
        }
        $script:NormalizedProtectedPaths += $normalized.TrimEnd('\')
    } catch {
        $script:ProtectedPathsError = $_.Exception.Message
        break
    }
}

if ($Execute -and [string]::IsNullOrWhiteSpace($PlanToken)) {
    Write-Output 'BLOCK  <batch>  ::  Execute requires the PlanToken emitted by an approved preview'
    Write-Output '--- done: PLAN=0 DELETED=0 BLOCK=1 FAILED=0'
    exit 2
}

$tokenPayload = $null
if ($Execute) {
    try {
        $tokenPayload = Read-PlanToken -Token $PlanToken
    } catch {
        Write-Output ('BLOCK  <batch>  ::  ' + $_.Exception.Message)
        Write-Output '--- done: PLAN=0 DELETED=0 BLOCK=1 FAILED=0'
        exit 2
    }
}

$planned = 0
$deleted = 0
$blocked = 0
$failed = 0
$validations = [System.Collections.Generic.List[object]]::new()

foreach ($requestedPath in $Paths) {
    $validation = Test-DeleteTarget -Path $requestedPath
    if (-not $validation.Safe) {
        Write-Output ('BLOCK  ' + $validation.Path + '  ::  ' + $validation.Reason)
        $blocked++
    } else {
        $validations.Add($validation)
    }
}

if (-not $Execute) {
    foreach ($validation in $validations) {
        Write-Output ('PLAN   ' + $validation.Path + '  ::  items=' + $validation.ItemCount + ' snapshot=' + $validation.Snapshot + ' (no deletion performed)')
        $planned++
    }
    if ($blocked -eq 0) {
        try {
            $token = New-PlanToken `
                -CanonicalPaths @($validations | ForEach-Object { $_.Path }) `
                -CanonicalProtectedPaths @($script:NormalizedProtectedPaths) `
                -Snapshots @($validations | ForEach-Object { $_.Snapshot })
            Write-Output ('PLAN_TOKEN  ' + $token)
        } catch {
            Write-Output ('BLOCK  <batch>  ::  could not create PlanToken: ' + $_.Exception.Message)
            $blocked++
        }
    } else {
        Write-Output 'BLOCK  <batch>  ::  PlanToken was not issued because at least one target was blocked'
    }
    Write-Output ('--- done: PLAN=' + $planned + ' DELETED=0 BLOCK=' + $blocked + ' FAILED=0')
    if ($blocked -gt 0) { exit 2 }
    exit 0
}

if ($blocked -gt 0) {
    Write-Output ('--- done: PLAN=0 DELETED=0 BLOCK=' + $blocked + ' FAILED=0')
    exit 2
}

try {
    if ([int]$tokenPayload.Version -ne 1) { throw 'unsupported PlanToken version' }
    if (-not ([string]$tokenPayload.ScriptSha256).Equals((Get-CurrentScriptHash), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'the deletion script changed after preview'
    }

    $canonicalPaths = @($validations | ForEach-Object { $_.Path })
    $currentSnapshots = @($validations | ForEach-Object { $_.Snapshot })
    if (-not (Test-StringArrayEqual -Left @($tokenPayload.Paths) -Right $canonicalPaths)) {
        throw 'Paths do not match the approved preview'
    }
    if (-not (Test-StringArrayEqual -Left @($tokenPayload.ProtectedPaths) -Right @($script:NormalizedProtectedPaths))) {
        throw 'ProtectedPaths do not match the approved preview'
    }
    if (-not (Test-StringArrayEqual -Left @($tokenPayload.Snapshots) -Right $currentSnapshots)) {
        throw 'one or more targets changed since preview'
    }
} catch {
    Write-Output ('BLOCK  <batch>  ::  ' + $_.Exception.Message)
    Write-Output '--- done: PLAN=0 DELETED=0 BLOCK=1 FAILED=0'
    exit 2
}

for ($targetIndex = 0; $targetIndex -lt $validations.Count; $targetIndex++) {
    $validation = $validations[$targetIndex]

    # Revalidate immediately before the destructive operation and compare the
    # metadata snapshot again to narrow the preview-to-delete race window.
    $finalValidation = Test-DeleteTarget -Path $validation.Path
    if (-not $finalValidation.Safe) {
        Write-Output ('BLOCK  ' + $finalValidation.Path + '  ::  revalidation failed: ' + $finalValidation.Reason)
        $blocked++
        continue
    }
    if (-not ([string]$finalValidation.Snapshot).Equals([string]@($tokenPayload.Snapshots)[$targetIndex], [StringComparison]::OrdinalIgnoreCase)) {
        Write-Output ('BLOCK  ' + $finalValidation.Path + '  ::  target changed since preview')
        $blocked++
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($finalValidation.Path, 'Permanently delete approved path')) {
        Write-Output ('SKIP   ' + $finalValidation.Path + '  ::  ShouldProcess declined')
        $failed++
        continue
    }

    try {
        Remove-Item -LiteralPath $finalValidation.Path -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $finalValidation.Path) {
            Write-Output ('PARTIAL_OR_FAILED  ' + $finalValidation.Path + '  ::  target still exists after Remove-Item')
            $failed++
        } else {
            Write-Output ('DELETED  ' + $finalValidation.Path)
            $deleted++
        }
    } catch {
        if (Test-Path -LiteralPath $finalValidation.Path) {
            Write-Output ('PARTIAL_OR_FAILED  ' + $finalValidation.Path + '  ::  ' + $_.Exception.Message)
        } else {
            Write-Output ('DELETED_WITH_ERROR  ' + $finalValidation.Path + '  ::  ' + $_.Exception.Message)
        }
        $failed++
    }
}

Write-Output ('--- done: PLAN=0 DELETED=' + $deleted + ' BLOCK=' + $blocked + ' FAILED=' + $failed)
if ($blocked -gt 0 -or $failed -gt 0) { exit 2 }
exit 0
