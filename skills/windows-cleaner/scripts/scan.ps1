# scan.ps1 - read-only logical-size scanner for FileSystem paths
# Usage: powershell -NoProfile -File scan.ps1 -Paths "C:\path"

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Paths
)

Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

foreach ($requestedPath in $Paths) {
    if ([string]::IsNullOrWhiteSpace($requestedPath) -or -not [IO.Path]::IsPathRooted($requestedPath)) {
        Write-Output ('INVALID  ' + $requestedPath + '  ::  an absolute FileSystem path is required')
        continue
    }

    try {
        $item = Get-Item -LiteralPath $requestedPath -Force -ErrorAction Stop
    } catch {
        Write-Output ('INVALID  ' + $requestedPath + '  ::  ' + $_.Exception.Message)
        continue
    }

    if ($item.PSProvider.Name -ne 'FileSystem') {
        Write-Output ('INVALID  ' + $requestedPath + '  ::  only the FileSystem provider is allowed; got ' + $item.PSProvider.Name)
        continue
    }

    $fullPath = [IO.Path]::GetFullPath($item.FullName)
    if ($fullPath.StartsWith('\\', [StringComparison]::OrdinalIgnoreCase)) {
        Write-Output ('INVALID  ' + $fullPath + '  ::  UNC and network paths are not allowed')
        continue
    }
    try {
        $driveInfo = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($fullPath))
        if ($driveInfo.DriveType -eq [IO.DriveType]::Network) {
            Write-Output ('INVALID  ' + $fullPath + '  ::  network drives are not allowed')
            continue
        }
    } catch {
        Write-Output ('INVALID  ' + $fullPath + '  ::  drive type cannot be verified: ' + $_.Exception.Message)
        continue
    }

    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Write-Output ('INVALID  ' + $fullPath + '  ::  target is a junction, symlink, or other reparse point')
        continue
    }

    [long]$logicalBytes = 0
    [long]$fileCount = 0
    [long]$directoryCount = 0
    [long]$skippedReparse = 0
    [long]$errors = 0

    if (-not $item.PSIsContainer) {
        $logicalBytes = [long]$item.Length
        $fileCount = 1
    } else {
        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push($fullPath)
        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            try {
                $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
            } catch {
                $errors++
                continue
            }

            foreach ($child in $children) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    $skippedReparse++
                    continue
                }
                if ($child.PSIsContainer) {
                    $directoryCount++
                    $stack.Push($child.FullName)
                } else {
                    $fileCount++
                    $logicalBytes += [long]$child.Length
                }
            }
        }
    }

    $status = if ($errors -eq 0) { 'COMPLETE' } else { 'PARTIAL' }
    Write-Output (('{0}  {1}  ::  logical={2:N1} MB ({3:N2} GB) files={4} dirs={5} skipped_reparse={6} errors={7}' -f
        $status, $fullPath, ($logicalBytes / 1MB), ($logicalBytes / 1GB), $fileCount, $directoryCount, $skippedReparse, $errors))
}
