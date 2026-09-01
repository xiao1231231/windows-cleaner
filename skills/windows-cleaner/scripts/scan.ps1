# scan.ps1 - read-only logical-size scanner for FileSystem paths
# Uses streaming .NET enumeration to avoid per-directory PowerShell cmdlet overhead.
# Usage: powershell -NoProfile -File scan.ps1 -Paths "C:\path"

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Paths,

    [ValidateRange(0, 100)]
    [int]$ErrorSampleLimit = 5
)

Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'scan-common.ps1')

$hadInvalid = $false
$hadPartial = $false
foreach ($requestedPath in $Paths) {
    if ([string]::IsNullOrWhiteSpace($requestedPath) -or -not [IO.Path]::IsPathRooted($requestedPath)) {
        Write-Output ('INVALID  ' + $requestedPath + '  ::  an absolute FileSystem path is required')
        $hadInvalid = $true
        continue
    }

    try {
        $fullPath = [IO.Path]::GetFullPath($requestedPath)
    } catch {
        Write-Output ('INVALID  ' + $requestedPath + '  ::  ' + $_.Exception.Message)
        $hadInvalid = $true
        continue
    }

    if ($fullPath.StartsWith('\\', [StringComparison]::OrdinalIgnoreCase)) {
        Write-Output ('INVALID  ' + $fullPath + '  ::  UNC and network paths are not allowed')
        $hadInvalid = $true
        continue
    }
    try {
        $driveInfo = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($fullPath))
        if ($driveInfo.DriveType -eq [IO.DriveType]::Network) {
            Write-Output ('INVALID  ' + $fullPath + '  ::  network drives are not allowed')
            $hadInvalid = $true
            continue
        }
    } catch {
        Write-Output ('INVALID  ' + $fullPath + '  ::  drive type cannot be verified: ' + $_.Exception.Message)
        $hadInvalid = $true
        continue
    }

    $pathValidation = Test-WindowsCleanerPathChain -FullPath $fullPath
    if (-not $pathValidation.Safe) {
        Write-Output ('INVALID  ' + $pathValidation.Path + '  ::  ' + $pathValidation.Reason)
        $hadInvalid = $true
        continue
    }
    $item = $pathValidation.Item
    $fullPath = [IO.Path]::GetFullPath($item.FullName)

    if (-not $item.PSIsContainer) {
        [long]$logicalBytes = [long]$item.Length
        [long]$fileCount = 1
        [long]$directoryCount = 0
        [long]$skippedReparse = 0
        [long]$errors = 0
        $errorSamples = @()
    } else {
        $measurement = Measure-WindowsCleanerTree -FullPath $fullPath -ErrorSampleLimit $ErrorSampleLimit
        [long]$logicalBytes = [long]$measurement.LogicalBytes
        [long]$fileCount = [long]$measurement.FileCount
        [long]$directoryCount = [long]$measurement.DirectoryCount
        [long]$skippedReparse = [long]$measurement.SkippedReparse
        [long]$errors = [long]$measurement.Errors
        $errorSamples = @($measurement.ErrorSamples)
    }

    $status = if ($errors -eq 0) { 'COMPLETE' } else { 'PARTIAL' }
    if ($errors -gt 0) { $hadPartial = $true }
    Write-Output (('{0}  {1}  ::  logical={2:N1} MB ({3:N2} GB) files={4} dirs={5} skipped_reparse={6} errors={7}' -f
        $status, $fullPath, ($logicalBytes / 1MB), ($logicalBytes / 1GB), $fileCount, $directoryCount, $skippedReparse, $errors))
    foreach ($sample in $errorSamples) {
        Write-Output ('ERROR_SAMPLE  ' + $sample.Path + '  ::  ' + $sample.Reason)
    }
}

exit (Get-WindowsCleanerScanExitCode -HadInvalid $hadInvalid -HadPartial $hadPartial)
