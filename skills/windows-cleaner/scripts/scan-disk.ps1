# scan-disk.ps1 - one-pass, read-only summary of a local FileSystem drive.
# Usage: powershell -NoProfile -File scan-disk.ps1 -Drive "C:\" [-Top 30] [-Threads 1..8]

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Drive,

    [ValidateRange(0, 10000)]
    [int]$Top = 0,

    [ValidateRange(1, 8)]
    [int]$Threads = [Math]::Min(8, [Math]::Max(1, [Environment]::ProcessorCount)),

    [ValidateRange(0, 100)]
    [int]$ErrorSampleLimit = 5,

    [switch]$NoProgress
)

Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'scan-common.ps1')

if ([string]::IsNullOrWhiteSpace($Drive) -or -not [IO.Path]::IsPathRooted($Drive)) {
    Write-Output ('INVALID  ' + $Drive + '  ::  an absolute local FileSystem drive root is required')
    exit 2
}

try {
    $fullPath = [IO.Path]::GetFullPath($Drive)
} catch {
    Write-Output ('INVALID  ' + $Drive + '  ::  ' + $_.Exception.Message)
    exit 2
}

if ($fullPath.StartsWith('\\', [StringComparison]::OrdinalIgnoreCase)) {
    Write-Output ('INVALID  ' + $fullPath + '  ::  UNC and network paths are not allowed')
    exit 2
}

$rootPath = [IO.Path]::GetPathRoot($fullPath)
$trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$normalizedInput = $fullPath.TrimEnd($trimChars)
$normalizedRoot = $rootPath.TrimEnd($trimChars)
if (-not [string]::Equals($normalizedInput, $normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Output ('INVALID  ' + $fullPath + '  ::  scan-disk accepts only a drive root such as C:\')
    exit 2
}

try {
    $driveInfo = [IO.DriveInfo]::new($rootPath)
    if ($driveInfo.DriveType -eq [IO.DriveType]::Network) {
        Write-Output ('INVALID  ' + $fullPath + '  ::  network drives are not allowed')
        exit 2
    }
    if (-not $driveInfo.IsReady) {
        Write-Output ('INVALID  ' + $fullPath + '  ::  drive is not ready')
        exit 2
    }
} catch {
    Write-Output ('INVALID  ' + $fullPath + '  ::  drive type cannot be verified: ' + $_.Exception.Message)
    exit 2
}

$pathValidation = Test-WindowsCleanerPathChain -FullPath $fullPath
if (-not $pathValidation.Safe) {
    Write-Output ('INVALID  ' + $pathValidation.Path + '  ::  ' + $pathValidation.Reason)
    exit 2
}
$item = $pathValidation.Item
$fullPath = [IO.Path]::GetFullPath($item.FullName)
if (-not $item.PSIsContainer) {
    Write-Output ('INVALID  ' + $fullPath + '  ::  a directory drive root is required')
    exit 2
}

$results = [System.Collections.Generic.List[object]]::new()
$rootDirectories = [System.Collections.Generic.List[string]]::new()
$rootSkipped = [System.Collections.Generic.List[string]]::new()
$rootErrorSamples = [System.Collections.Generic.List[object]]::new()
[long]$rootErrors = 0
$addRootErrorSample = {
    param([string]$Path, [string]$Reason)
    if ($rootErrorSamples.Count -lt $ErrorSampleLimit) {
        $rootErrorSamples.Add([pscustomobject]@{ Path=$Path; Reason=$Reason })
    }
}
$rootEnumerator = $null
try {
    $rootDirectory = [IO.DirectoryInfo]::new($fullPath)
    $rootEnumerator = $rootDirectory.EnumerateFileSystemInfos().GetEnumerator()
} catch {
    $rootErrors++
    & $addRootErrorSample $fullPath $_.Exception.Message
}

if ($null -ne $rootEnumerator) {
    try {
        while ($true) {
            try {
                $hasNext = $rootEnumerator.MoveNext()
            } catch {
                $rootErrors++
                & $addRootErrorSample $fullPath $_.Exception.Message
                break
            }
            if (-not $hasNext) {
                break
            }

            $child = $rootEnumerator.Current
            try {
                $attributes = $child.Attributes
            } catch {
                $rootErrors++
                $samplePath = try { $child.FullName } catch { $fullPath }
                & $addRootErrorSample $samplePath $_.Exception.Message
                continue
            }

            if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
                $rootSkipped.Add($child.FullName)
                continue
            }

            if ($attributes -band [IO.FileAttributes]::Directory) {
                $rootDirectories.Add($child.FullName)
                continue
            }

            try {
                $length = [long]$child.Length
                $fileErrors = 0
            } catch {
                $length = 0
                $fileErrors = 1
                $fileErrorSamples = @([pscustomobject]@{ Path=$child.FullName; Reason=$_.Exception.Message })
            }
            if ($fileErrors -eq 0) { $fileErrorSamples = @() }
            $results.Add([pscustomobject]@{
                FullPath = $child.FullName
                IsDirectory = $false
                LogicalBytes = $length
                FileCount = [long]1
                DirectoryCount = [long]0
                SkippedReparse = [long]0
                Errors = [long]$fileErrors
                ErrorSamples = @($fileErrorSamples)
            })
        }
    } finally {
        $rootEnumerator.Dispose()
    }
}

$completedCount = 0
if ($Threads -eq 1 -or $rootDirectories.Count -le 1) {
    foreach ($directoryPath in $rootDirectories) {
        $measurement = Measure-WindowsCleanerTree -FullPath $directoryPath -ErrorSampleLimit $ErrorSampleLimit
        $results.Add([pscustomobject]@{
            FullPath = $directoryPath
            IsDirectory = $true
            LogicalBytes = [long]$measurement.LogicalBytes
            FileCount = [long]$measurement.FileCount
            DirectoryCount = [long]$measurement.DirectoryCount
            SkippedReparse = [long]$measurement.SkippedReparse
            Errors = [long]$measurement.Errors
            ErrorSamples = @($measurement.ErrorSamples)
        })
        $completedCount++
        if (-not $NoProgress) {
            Write-Output ('PROGRESS  completed=' + $completedCount + ' total=' + $rootDirectories.Count + ' path=' + $directoryPath)
        }
    }
} else {
    $workerScript = @'
param($CommonScript, $DirectoryPath, $WorkerErrorSampleLimit)
. $CommonScript
$measurement = Measure-WindowsCleanerTree -FullPath $DirectoryPath -ErrorSampleLimit $WorkerErrorSampleLimit
[pscustomobject]@{
    FullPath = $DirectoryPath
    IsDirectory = $true
    LogicalBytes = [long]$measurement.LogicalBytes
    FileCount = [long]$measurement.FileCount
    DirectoryCount = [long]$measurement.DirectoryCount
    SkippedReparse = [long]$measurement.SkippedReparse
    Errors = [long]$measurement.Errors
    ErrorSamples = @($measurement.ErrorSamples)
}
'@
    $commonScript = Join-Path $PSScriptRoot 'scan-common.ps1'
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $Threads)
    $pending = [System.Collections.Generic.List[object]]::new()
    try {
        $pool.Open()
        foreach ($directoryPath in $rootDirectories) {
            $pipeline = [PowerShell]::Create()
            $pipeline.RunspacePool = $pool
            $null = $pipeline.AddScript($workerScript).AddArgument($commonScript).AddArgument($directoryPath).AddArgument($ErrorSampleLimit)
            try {
                $handle = $pipeline.BeginInvoke()
                $pending.Add([pscustomobject]@{
                    FullPath = $directoryPath
                    Pipeline = $pipeline
                    Handle = $handle
                })
            } catch {
                $launchError = $_.Exception.Message
                $pipeline.Dispose()
                $results.Add([pscustomobject]@{
                    FullPath = $directoryPath
                    IsDirectory = $true
                    LogicalBytes = [long]0
                    FileCount = [long]0
                    DirectoryCount = [long]0
                    SkippedReparse = [long]0
                    Errors = [long]1
                    ErrorSamples = @([pscustomobject]@{ Path=$directoryPath; Reason=$launchError })
                })
                $completedCount++
                if (-not $NoProgress) {
                    Write-Output ('PROGRESS  completed=' + $completedCount + ' total=' + $rootDirectories.Count + ' path=' + $directoryPath)
                }
            }
        }

        while ($pending.Count -gt 0) {
            $foundCompleted = $false
            for ($jobIndex = $pending.Count - 1; $jobIndex -ge 0; $jobIndex--) {
                $job = $pending[$jobIndex]
                if (-not $job.Handle.IsCompleted) { continue }
                $foundCompleted = $true
                try {
                    $workerResults = @($job.Pipeline.EndInvoke($job.Handle))
                    if ($workerResults.Count -ne 1) {
                        throw 'parallel scan worker returned an unexpected result count'
                    }
                    $results.Add($workerResults[0])
                } catch {
                    $workerError = $_.Exception.Message
                    $results.Add([pscustomobject]@{
                        FullPath = $job.FullPath
                        IsDirectory = $true
                        LogicalBytes = [long]0
                        FileCount = [long]0
                        DirectoryCount = [long]0
                        SkippedReparse = [long]0
                        Errors = [long]1
                        ErrorSamples = @([pscustomobject]@{ Path=$job.FullPath; Reason=$workerError })
                    })
                } finally {
                    $job.Pipeline.Dispose()
                    $pending.RemoveAt($jobIndex)
                }
                $completedCount++
                if (-not $NoProgress) {
                    Write-Output ('PROGRESS  completed=' + $completedCount + ' total=' + $rootDirectories.Count + ' path=' + $job.FullPath)
                }
            }
            if (-not $foundCompleted -and $pending.Count -gt 0) {
                Start-Sleep -Milliseconds 50
            }
        }
    } finally {
        $pool.Close()
        $pool.Dispose()
    }
}

[long]$totalBytes = 0
[long]$totalFiles = 0
[long]$totalDirectories = 0
[long]$totalSkippedReparse = $rootSkipped.Count
[long]$totalErrors = $rootErrors
$errorSamples = [System.Collections.Generic.List[object]]::new()
foreach ($sample in $rootErrorSamples) {
    if ($errorSamples.Count -ge $ErrorSampleLimit) { break }
    $errorSamples.Add($sample)
}
foreach ($result in $results) {
    $totalBytes += [long]$result.LogicalBytes
    $totalFiles += [long]$result.FileCount
    $totalDirectories += [long]$result.DirectoryCount
    if ($result.IsDirectory) {
        $totalDirectories++
    }
    $totalSkippedReparse += [long]$result.SkippedReparse
    $totalErrors += [long]$result.Errors
    foreach ($sample in @($result.ErrorSamples)) {
        if ($errorSamples.Count -ge $ErrorSampleLimit) { break }
        $errorSamples.Add($sample)
    }
}

$diskStatus = if ($totalErrors -eq 0) { 'COMPLETE' } else { 'PARTIAL' }
Write-Output (('{0}  {1}  ::  scope=disk logical={2:N1} MB ({3:N2} GB) files={4} dirs={5} skipped_reparse={6} errors={7} workers={8}' -f
    $diskStatus, $fullPath, ($totalBytes / 1MB), ($totalBytes / 1GB), $totalFiles, $totalDirectories, $totalSkippedReparse, $totalErrors, $Threads))

$ordered = @($results | Sort-Object -Property @{Expression='LogicalBytes';Descending=$true}, @{Expression='FullPath';Descending=$false})
if ($Top -gt 0 -and $ordered.Count -gt $Top) {
    $selected = [System.Collections.Generic.List[object]]::new()
    $selectedPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($result in ($ordered | Select-Object -First $Top)) {
        $selected.Add($result)
        $null = $selectedPaths.Add($result.FullPath)
    }
    foreach ($result in $ordered) {
        if ($result.Errors -gt 0 -and -not $selectedPaths.Contains($result.FullPath)) {
            $selected.Add($result)
        }
    }
    $ordered = @($selected)
}

foreach ($result in $ordered) {
    $entryStatus = if ($result.Errors -eq 0) { 'COMPLETE' } else { 'PARTIAL' }
    Write-Output (('ENTRY  {0}  {1}  ::  logical={2:N1} MB ({3:N2} GB) files={4} dirs={5} skipped_reparse={6} errors={7}' -f
        $entryStatus, $result.FullPath, ($result.LogicalBytes / 1MB), ($result.LogicalBytes / 1GB),
        $result.FileCount, $result.DirectoryCount, $result.SkippedReparse, $result.Errors))
}

foreach ($skippedPath in $rootSkipped) {
    Write-Output ('SKIPPED  ' + $skippedPath + '  ::  reparse point was not traversed')
}

foreach ($sample in $errorSamples) {
    Write-Output ('ERROR_SAMPLE  ' + $sample.Path + '  ::  ' + $sample.Reason)
}

exit (Get-WindowsCleanerScanExitCode -HadInvalid $false -HadPartial ($totalErrors -gt 0))
