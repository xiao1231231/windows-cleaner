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

    [switch]$Execute,

    [ValidateSet('Text', 'Json')]
    [string]$OutputFormat = 'Text'
)

Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'scan-common.ps1')
# Agent and automation hosts must never inherit a caller preference that triggers
# an interactive ShouldProcess prompt. -WhatIf remains supported.
$ConfirmPreference = 'High'

$script:DeleteEvents = [System.Collections.Generic.List[object]]::new()
$script:OutputPlanToken = $null

function Add-DeleteEvent {
    param(
        [Parameter(Mandatory=$true)][string]$Status,
        [string]$Path,
        [string]$Reason,
        [Nullable[long]]$ChildCount,
        [Nullable[long]]$CheckedItems,
        [string]$Snapshot,
        [string]$Token
    )

    $event = [ordered]@{
        status = $Status
        path = $Path
        reason = $Reason
        child_count = $ChildCount
        checked_items = $CheckedItems
        snapshot = $Snapshot
    }
    $script:DeleteEvents.Add([pscustomobject]$event)
    if ($Status -eq 'PLAN_TOKEN') {
        $script:OutputPlanToken = $Token
    }
    if ($OutputFormat -eq 'Json') { return }

    switch ($Status) {
        'PLAN' {
            Write-Output ('PLAN   ' + $Path + '  ::  child_count=' + $ChildCount + ' snapshot=' + $Snapshot + ' (no deletion performed)')
        }
        'PLAN_TOKEN' { Write-Output ('PLAN_TOKEN  ' + $Token) }
        'ACCESS_OK' {
            Write-Output ('ACCESS_OK  ' + $Path + '  ::  checked_items=' + $CheckedItems + ' (no deletion performed)')
        }
        'DELETED' { Write-Output ('DELETED  ' + $Path) }
        default {
            $padding = if ($Status -eq 'SKIP') { '   ' } else { '  ' }
            $line = $Status + $padding + $Path
            if (-not [string]::IsNullOrWhiteSpace($Reason)) { $line += '  ::  ' + $Reason }
            Write-Output $line
        }
    }
}

function Complete-DeleteOutput {
    param(
        [int]$Planned,
        [int]$Deleted,
        [int]$Blocked,
        [int]$Failed
    )

    if ($OutputFormat -eq 'Json') {
        $response = [ordered]@{
            schema_version = 1
            mode = $(if ($Execute) { 'execute' } else { 'preview' })
            events = @($script:DeleteEvents)
            plan_token = $script:OutputPlanToken
            summary = [ordered]@{
                planned = $Planned
                deleted = $Deleted
                blocked = $Blocked
                failed = $Failed
            }
        }
        Write-Output ($response | ConvertTo-Json -Depth 6)
    } else {
        Write-Output ('--- done: PLAN=' + $Planned + ' DELETED=' + $Deleted + ' BLOCK=' + $Blocked + ' FAILED=' + $Failed)
    }
}

try {
    Add-Type -AssemblyName System.Security -ErrorAction Stop
} catch {
    Add-DeleteEvent -Status 'BLOCK' -Path '<batch>' -Reason ('plan-token support is unavailable: ' + $_.Exception.Message)
    Complete-DeleteOutput -Planned 0 -Deleted 0 -Blocked 1 -Failed 0
    exit 2
}

if ($null -eq ('WindowsCleaner.NativeDeleteAccess' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace WindowsCleaner
{
    public sealed class DeleteAccessProbeResult
    {
        public bool Success { get; private set; }
        public int ErrorCode { get; private set; }
        public string Message { get; private set; }

        public DeleteAccessProbeResult(bool success, int errorCode, string message)
        {
            Success = success;
            ErrorCode = errorCode;
            Message = message;
        }
    }

    public static class NativeDeleteAccess
    {
        private const uint Delete = 0x00010000;
        private const uint FileDeleteChild = 0x00000040;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateFileW")]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        private static string ToExtendedPath(string path)
        {
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) return path;
            return @"\\?\" + path;
        }

        private static DeleteAccessProbeResult Probe(string path, bool directory, uint desiredAccess)
        {
            uint flags = FileFlagOpenReparsePoint;
            if (directory) flags |= FileFlagBackupSemantics;
            using (SafeFileHandle handle = CreateFile(
                ToExtendedPath(path),
                desiredAccess,
                FileShareRead | FileShareWrite | FileShareDelete,
                IntPtr.Zero,
                OpenExisting,
                flags,
                IntPtr.Zero))
            {
                if (!handle.IsInvalid) return new DeleteAccessProbeResult(true, 0, String.Empty);
                int error = Marshal.GetLastWin32Error();
                return new DeleteAccessProbeResult(false, error, new Win32Exception(error).Message);
            }
        }

        public static DeleteAccessProbeResult ProbeDelete(string path, bool directory)
        {
            return Probe(path, directory, Delete);
        }

        public static DeleteAccessProbeResult ProbeDeleteChild(string directoryPath)
        {
            return Probe(directoryPath, true, FileDeleteChild);
        }
    }
}
'@ -ErrorAction Stop
    } catch {
        Add-DeleteEvent -Status 'BLOCK' -Path '<batch>' -Reason ('delete-access preflight support is unavailable: ' + $_.Exception.Message)
        Complete-DeleteOutput -Planned 0 -Deleted 0 -Blocked 1 -Failed 0
        exit 2
    }
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
        $appDataRoot = Join-Path $profilePath 'AppData'
        Add-UniquePath -List $protectedRoots -Path $appDataRoot
        Add-UniquePath -List $protectedRoots -Path (Join-Path $appDataRoot 'Local')
        Add-UniquePath -List $protectedRoots -Path (Join-Path $appDataRoot 'Roaming')
        Add-UniquePath -List $protectedRoots -Path (Join-Path $appDataRoot 'LocalLow')
    }
    foreach ($applicationDataPath in @(
        (Get-SpecialFolderPath -Name 'ApplicationData'),
        (Get-SpecialFolderPath -Name 'LocalApplicationData')
    )) {
        Add-UniquePath -List $protectedRoots -Path $applicationDataPath
        if (-not [string]::IsNullOrWhiteSpace($applicationDataPath)) {
            $appDataParent = Split-Path -Parent $applicationDataPath
            Add-UniquePath -List $protectedRoots -Path $appDataParent
            Add-UniquePath -List $protectedRoots -Path (Join-Path $appDataParent 'LocalLow')
        }
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

    $isDirectory = (($Item.Attributes -band [IO.FileAttributes]::Directory) -ne 0)
    $kind = if ($isDirectory) { 'D' } else { 'F' }
    $length = if ($isDirectory) { 0 } else { [long]$Item.Length }
    return ($RelativePath + '|' + $kind + '|' + $length + '|' + $Item.LastWriteTimeUtc.Ticks + '|' + $Item.CreationTimeUtc.Ticks + '|' + [int]$Item.Attributes)
}

function Test-TreeSafety {
    param([System.IO.FileSystemInfo]$Item)

    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return [pscustomobject]@{ Safe=$false; Reason='target is a junction, symlink, or other reparse point'; ChildCount=0; Snapshot=$null }
    }

    $hasher = [Security.Cryptography.SHA256]::Create()
    [byte[]]$aggregate = New-Object byte[] 32
    try {
        Add-SnapshotRecord -Hasher $hasher -Aggregate $aggregate -Record (Get-SnapshotRecord -Item $Item -RelativePath '.')
        if (-not ($Item.Attributes -band [IO.FileAttributes]::Directory)) {
            Add-SnapshotRecord -Hasher $hasher -Aggregate $aggregate -Record 'COUNT|0'
            return [pscustomobject]@{ Safe=$true; Reason=$null; ChildCount=0; Snapshot=(ConvertTo-SnapshotHex -Bytes $aggregate) }
        }

        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push($Item.FullName)
        $count = 0
        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            $enumerator = $null
            try {
                $directory = [IO.DirectoryInfo]::new($current)
                $enumerator = $directory.EnumerateFileSystemInfos().GetEnumerator()
                $isTopLevel = $current.Equals($Item.FullName, [StringComparison]::OrdinalIgnoreCase)
                while ($true) {
                    try {
                        $hasNext = $enumerator.MoveNext()
                    } catch {
                        return [pscustomobject]@{ Safe=$false; Reason=('cannot fully inspect ' + $current + ': ' + $_.Exception.Message); ChildCount=$count; Snapshot=$null }
                    }
                    if (-not $hasNext) { break }

                    $child = $enumerator.Current
                    try {
                        $childFullName = $child.FullName
                        $childName = $child.Name
                        $childAttributes = $child.Attributes
                        $relativePath = $childFullName.Substring($Item.FullName.TrimEnd('\').Length).TrimStart('\')
                        $snapshotRecord = Get-SnapshotRecord -Item $child -RelativePath $relativePath
                    } catch {
                        return [pscustomobject]@{ Safe=$false; Reason=('cannot fully inspect an item under ' + $current + ': ' + $_.Exception.Message); ChildCount=$count; Snapshot=$null }
                    }

                    $count++
                    Add-SnapshotRecord -Hasher $hasher -Aggregate $aggregate -Record $snapshotRecord

                    $sensitiveReason = Get-SensitiveNameReason -Name $childName
                    if ($sensitiveReason) {
                        return [pscustomobject]@{ Safe=$false; Reason=($sensitiveReason + ' at ' + $childFullName); ChildCount=$count; Snapshot=$null }
                    }
                    if ($isTopLevel) {
                        $projectReason = Get-ProjectMarkerReason -Name $childName
                        if ($projectReason) {
                            return [pscustomobject]@{ Safe=$false; Reason=($projectReason + ' at ' + $childFullName); ChildCount=$count; Snapshot=$null }
                        }
                    }
                    if ($childAttributes -band [IO.FileAttributes]::ReparsePoint) {
                        return [pscustomobject]@{ Safe=$false; Reason=('contains reparse point: ' + $childFullName); ChildCount=$count; Snapshot=$null }
                    }
                    if ($childAttributes -band [IO.FileAttributes]::Directory) {
                        $stack.Push($childFullName)
                    }
                }
            } catch {
                return [pscustomobject]@{ Safe=$false; Reason=('cannot fully inspect ' + $current + ': ' + $_.Exception.Message); ChildCount=$count; Snapshot=$null }
            } finally {
                if ($null -ne $enumerator) { $enumerator.Dispose() }
            }
        }

        Add-SnapshotRecord -Hasher $hasher -Aggregate $aggregate -Record ('COUNT|' + $count)
        return [pscustomobject]@{ Safe=$true; Reason=$null; ChildCount=$count; Snapshot=(ConvertTo-SnapshotHex -Bytes $aggregate) }
    } finally {
        $hasher.Dispose()
    }
}

function Test-OneDeleteAccess {
    param([System.IO.FileSystemInfo]$Item)

    try {
        $attributes = $Item.Attributes
    } catch {
        return [pscustomobject]@{ Safe=$false; Reason=('attributes cannot be inspected: ' + $_.Exception.Message) }
    }
    $isDirectory = (($attributes -band [IO.FileAttributes]::Directory) -ne 0)
    $directProbe = [WindowsCleaner.NativeDeleteAccess]::ProbeDelete($Item.FullName, $isDirectory)
    if ($directProbe.Success) {
        return [pscustomobject]@{ Safe=$true; Reason=$null }
    }

    # A sharing or lock violation is not overridden by DELETE_CHILD permission
    # on the parent. Report it before any destructive operation begins.
    if ($directProbe.ErrorCode -eq 32 -or $directProbe.ErrorCode -eq 33) {
        return [pscustomobject]@{
            Safe = $false
            Reason = ('target is locked or does not share delete access: ' + $directProbe.Message + ' (Win32=' + $directProbe.ErrorCode + ')')
        }
    }

    $parentPath = [IO.Path]::GetDirectoryName($Item.FullName.TrimEnd('\'))
    if ([string]::IsNullOrWhiteSpace($parentPath)) {
        return [pscustomobject]@{
            Safe = $false
            Reason = ('DELETE access is unavailable: ' + $directProbe.Message + ' (Win32=' + $directProbe.ErrorCode + ')')
        }
    }

    $parentProbe = [WindowsCleaner.NativeDeleteAccess]::ProbeDeleteChild($parentPath)
    if ($parentProbe.Success) {
        return [pscustomobject]@{ Safe=$true; Reason=$null }
    }
    return [pscustomobject]@{
        Safe = $false
        Reason = ('neither target DELETE nor parent DELETE_CHILD access is available; target={0} (Win32={1}), parent={2} (Win32={3})' -f
            $directProbe.Message, $directProbe.ErrorCode, $parentProbe.Message, $parentProbe.ErrorCode)
    }
}

function Test-DeleteAccessTree {
    param([System.IO.FileSystemInfo]$Item)

    try {
        $rootAttributes = $Item.Attributes
    } catch {
        return [pscustomobject]@{ Safe=$false; Path=$Item.FullName; Reason=('attributes cannot be inspected: ' + $_.Exception.Message); CheckedItems=0 }
    }
    if ($rootAttributes -band [IO.FileAttributes]::ReparsePoint) {
        return [pscustomobject]@{ Safe=$false; Path=$Item.FullName; Reason='reparse point appeared before delete-access preflight'; CheckedItems=0 }
    }
    $rootAccess = Test-OneDeleteAccess -Item $Item
    if (-not $rootAccess.Safe) {
        return [pscustomobject]@{ Safe=$false; Path=$Item.FullName; Reason=$rootAccess.Reason; CheckedItems=0 }
    }

    [long]$count = 1
    if (-not ($rootAttributes -band [IO.FileAttributes]::Directory)) {
        return [pscustomobject]@{ Safe=$true; Path=$Item.FullName; Reason=$null; CheckedItems=$count }
    }

    # Store only directories. Files are probed while their parent enumerator is
    # open, avoiding a potentially huge in-memory stack for flat directories.
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Item.FullName)
    while ($stack.Count -gt 0) {
        $currentPath = $stack.Pop()
        try {
            $currentAttributes = [IO.File]::GetAttributes($currentPath)
        } catch {
            return [pscustomobject]@{ Safe=$false; Path=$currentPath; Reason=('attributes cannot be inspected: ' + $_.Exception.Message); CheckedItems=$count }
        }
        if ($currentAttributes -band [IO.FileAttributes]::ReparsePoint) {
            return [pscustomobject]@{ Safe=$false; Path=$currentPath; Reason='reparse point appeared before delete-access preflight'; CheckedItems=$count }
        }

        $enumerator = $null
        try {
            $directory = [IO.DirectoryInfo]::new($currentPath)
            $enumerator = $directory.EnumerateFileSystemInfos().GetEnumerator()
            while ($true) {
                try {
                    $hasNext = $enumerator.MoveNext()
                } catch {
                    return [pscustomobject]@{ Safe=$false; Path=$currentPath; Reason=('cannot fully enumerate for delete-access preflight: ' + $_.Exception.Message); CheckedItems=$count }
                }
                if (-not $hasNext) { break }

                $child = $enumerator.Current
                try {
                    $childAttributes = $child.Attributes
                } catch {
                    return [pscustomobject]@{ Safe=$false; Path=$child.FullName; Reason=('attributes cannot be inspected: ' + $_.Exception.Message); CheckedItems=$count }
                }
                if ($childAttributes -band [IO.FileAttributes]::ReparsePoint) {
                    return [pscustomobject]@{ Safe=$false; Path=$child.FullName; Reason='reparse point appeared before delete-access preflight'; CheckedItems=$count }
                }

                $childAccess = Test-OneDeleteAccess -Item $child
                if (-not $childAccess.Safe) {
                    return [pscustomobject]@{ Safe=$false; Path=$child.FullName; Reason=$childAccess.Reason; CheckedItems=$count }
                }
                $count++
                if ($childAttributes -band [IO.FileAttributes]::Directory) {
                    $stack.Push($child.FullName)
                }
            }
        } catch {
            return [pscustomobject]@{ Safe=$false; Path=$currentPath; Reason=('cannot start delete-access preflight enumeration: ' + $_.Exception.Message); CheckedItems=$count }
        } finally {
            if ($null -ne $enumerator) { $enumerator.Dispose() }
        }
    }

    return [pscustomobject]@{ Safe=$true; Path=$Item.FullName; Reason=$null; CheckedItems=$count }
}

function Test-DeleteTarget {
    param([string]$Path)

    if ($script:ProtectedPathsError) {
        return [pscustomobject]@{ Safe=$false; Path=$Path; Reason=('invalid ProtectedPaths: ' + $script:ProtectedPathsError); ChildCount=0; Snapshot=$null }
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Safe=$false; Path=$Path; Reason='empty paths are not allowed'; ChildCount=0; Snapshot=$null }
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Safe=$false; Path=$Path; Reason=('path cannot be resolved: ' + $_.Exception.Message); ChildCount=0; Snapshot=$null }
    }

    if ($item.PSProvider.Name -ne 'FileSystem') {
        return [pscustomobject]@{ Safe=$false; Path=$Path; Reason=('only the FileSystem provider is allowed; got ' + $item.PSProvider.Name); ChildCount=0; Snapshot=$null }
    }
    if (-not [IO.Path]::IsPathRooted($Path)) {
        return [pscustomobject]@{ Safe=$false; Path=$Path; Reason='relative paths are not allowed'; ChildCount=0; Snapshot=$null }
    }

    $fullPath = [IO.Path]::GetFullPath($item.FullName)
    if ($fullPath.StartsWith('\\', [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Safe=$false; Path=$fullPath; Reason='UNC and network paths are not allowed'; ChildCount=0; Snapshot=$null }
    }

    $pathValidation = Test-WindowsCleanerPathChain -FullPath $fullPath
    if (-not $pathValidation.Safe) {
        return [pscustomobject]@{ Safe=$false; Path=$pathValidation.Path; Reason=$pathValidation.Reason; ChildCount=0; Snapshot=$null }
    }
    $item = $pathValidation.Item
    $fullPath = [IO.Path]::GetFullPath($item.FullName)

    try {
        $driveInfo = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($fullPath))
        if ($driveInfo.DriveType -eq [IO.DriveType]::Network) {
            return [pscustomobject]@{ Safe=$false; Path=$fullPath; Reason='network drives are not allowed'; ChildCount=0; Snapshot=$null }
        }
    } catch {
        return [pscustomobject]@{ Safe=$false; Path=$fullPath; Reason=('drive type cannot be verified: ' + $_.Exception.Message); ChildCount=0; Snapshot=$null }
    }

    $protectedReason = Get-ProtectedReason -FullPath $fullPath
    if ($protectedReason) {
        return [pscustomobject]@{ Safe=$false; Path=$fullPath; Reason=$protectedReason; ChildCount=0; Snapshot=$null }
    }

    $tree = Test-TreeSafety -Item $item
    return [pscustomobject]@{ Safe=$tree.Safe; Path=$fullPath; Reason=$tree.Reason; ChildCount=$tree.ChildCount; Snapshot=$tree.Snapshot }
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
    } catch {
        throw ('invalid PlanToken encoding: ' + $_.Exception.Message)
    }

    try {
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
    } catch [Security.Cryptography.CryptographicException] {
        throw 'invalid PlanToken for this host context: run preview again in the same persistent terminal and Windows identity that will execute; prefer the client built-in terminal when it has target write access'
    } catch {
        throw ('invalid PlanToken: ' + $_.Exception.Message)
    }

    try {
        $json = [Text.Encoding]::UTF8.GetString($plainBytes)
        return ($json | ConvertFrom-Json)
    } catch {
        throw ('invalid PlanToken payload: ' + $_.Exception.Message)
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
    Add-DeleteEvent -Status 'BLOCK' -Path '<batch>' -Reason 'Execute requires the PlanToken emitted by an approved preview'
    Complete-DeleteOutput -Planned 0 -Deleted 0 -Blocked 1 -Failed 0
    exit 2
}

$tokenPayload = $null
if ($Execute) {
    try {
        $tokenPayload = Read-PlanToken -Token $PlanToken
    } catch {
        Add-DeleteEvent -Status 'BLOCK' -Path '<batch>' -Reason $_.Exception.Message
        Complete-DeleteOutput -Planned 0 -Deleted 0 -Blocked 1 -Failed 0
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
        Add-DeleteEvent -Status 'BLOCK' -Path $validation.Path -Reason $validation.Reason -ChildCount $validation.ChildCount
        $blocked++
    } else {
        $validations.Add($validation)
    }
}

if (-not $Execute) {
    foreach ($validation in $validations) {
        Add-DeleteEvent -Status 'PLAN' -Path $validation.Path -ChildCount $validation.ChildCount -Snapshot $validation.Snapshot
        $planned++
    }
    if ($blocked -eq 0) {
        try {
            $token = New-PlanToken `
                -CanonicalPaths @($validations | ForEach-Object { $_.Path }) `
                -CanonicalProtectedPaths @($script:NormalizedProtectedPaths) `
                -Snapshots @($validations | ForEach-Object { $_.Snapshot })
            Add-DeleteEvent -Status 'PLAN_TOKEN' -Token $token
        } catch {
            Add-DeleteEvent -Status 'BLOCK' -Path '<batch>' -Reason ('could not create PlanToken: ' + $_.Exception.Message)
            $blocked++
        }
    } else {
        Add-DeleteEvent -Status 'BLOCK' -Path '<batch>' -Reason 'PlanToken was not issued because at least one target was blocked'
    }
    Complete-DeleteOutput -Planned $planned -Deleted 0 -Blocked $blocked -Failed 0
    if ($blocked -gt 0) { exit 2 }
    exit 0
}

if ($blocked -gt 0) {
    Complete-DeleteOutput -Planned 0 -Deleted 0 -Blocked $blocked -Failed 0
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
    Add-DeleteEvent -Status 'BLOCK' -Path '<batch>' -Reason $_.Exception.Message
    Complete-DeleteOutput -Planned 0 -Deleted 0 -Blocked 1 -Failed 0
    exit 2
}

# Check the complete batch for effective delete access and sharing locks before
# the first mutation. This cannot eliminate races after the probe, but it avoids
# predictable partial deletion when the current host cannot delete a target.
foreach ($validation in $validations) {
    try {
        $accessItem = Get-Item -LiteralPath $validation.Path -Force -ErrorAction Stop
        $accessResult = Test-DeleteAccessTree -Item $accessItem
    } catch {
        $accessResult = [pscustomobject]@{ Safe=$false; Path=$validation.Path; Reason=$_.Exception.Message; CheckedItems=0 }
    }

    if (-not $accessResult.Safe) {
        Add-DeleteEvent -Status 'BLOCK' -Path $validation.Path -Reason ('delete-access preflight failed at ' + $accessResult.Path + ': ' + $accessResult.Reason) -CheckedItems $accessResult.CheckedItems
        $blocked++
    } else {
        Add-DeleteEvent -Status 'ACCESS_OK' -Path $validation.Path -CheckedItems $accessResult.CheckedItems
    }
}

if ($blocked -gt 0) {
    Complete-DeleteOutput -Planned 0 -Deleted 0 -Blocked $blocked -Failed 0
    exit 2
}

for ($targetIndex = 0; $targetIndex -lt $validations.Count; $targetIndex++) {
    $validation = $validations[$targetIndex]

    # Revalidate immediately before the destructive operation and compare the
    # metadata snapshot again to narrow the preview-to-delete race window.
    $finalValidation = Test-DeleteTarget -Path $validation.Path
    if (-not $finalValidation.Safe) {
        Add-DeleteEvent -Status 'BLOCK' -Path $finalValidation.Path -Reason ('revalidation failed: ' + $finalValidation.Reason) -ChildCount $finalValidation.ChildCount
        $blocked++
        continue
    }
    if (-not ([string]$finalValidation.Snapshot).Equals([string]@($tokenPayload.Snapshots)[$targetIndex], [StringComparison]::OrdinalIgnoreCase)) {
        Add-DeleteEvent -Status 'BLOCK' -Path $finalValidation.Path -Reason 'target changed since preview' -ChildCount $finalValidation.ChildCount
        $blocked++
        continue
    }

    # ShouldProcess writes its own human-readable WhatIf message before
    # returning. In JSON mode, handle WhatIf directly so stdout remains a
    # single parseable JSON document.
    if ($OutputFormat -eq 'Json' -and $WhatIfPreference) {
        Add-DeleteEvent -Status 'SKIP' -Path $finalValidation.Path -Reason 'ShouldProcess declined by WhatIf'
        $failed++
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($finalValidation.Path, 'Permanently delete approved path')) {
        Add-DeleteEvent -Status 'SKIP' -Path $finalValidation.Path -Reason 'ShouldProcess declined'
        $failed++
        continue
    }

    try {
        Remove-Item -LiteralPath $finalValidation.Path -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $finalValidation.Path) {
            Add-DeleteEvent -Status 'PARTIAL_OR_FAILED' -Path $finalValidation.Path -Reason 'target still exists after Remove-Item'
            $failed++
        } else {
            Add-DeleteEvent -Status 'DELETED' -Path $finalValidation.Path
            $deleted++
        }
    } catch {
        if (Test-Path -LiteralPath $finalValidation.Path) {
            Add-DeleteEvent -Status 'PARTIAL_OR_FAILED' -Path $finalValidation.Path -Reason $_.Exception.Message
        } else {
            Add-DeleteEvent -Status 'DELETED_WITH_ERROR' -Path $finalValidation.Path -Reason $_.Exception.Message
        }
        $failed++
    }
}

Complete-DeleteOutput -Planned 0 -Deleted $deleted -Blocked $blocked -Failed $failed
if ($blocked -gt 0 -or $failed -gt 0) { exit 2 }
exit 0
