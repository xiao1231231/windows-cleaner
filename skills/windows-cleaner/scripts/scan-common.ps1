# Shared read-only tree measurement for windows-cleaner scanners.

Set-StrictMode -Version 2.0

function Test-WindowsCleanerPathChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$FullPath
    )

    try {
        $rootPath = [IO.Path]::GetPathRoot($FullPath)
        if ([string]::IsNullOrWhiteSpace($rootPath)) {
            throw 'the path does not have a drive root'
        }

        $pathsToCheck = [System.Collections.Generic.List[string]]::new()
        $pathsToCheck.Add($rootPath)
        $relativePath = $FullPath.Substring($rootPath.Length)
        $currentPath = $rootPath
        $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        foreach ($segment in $relativePath.Split($trimChars, [StringSplitOptions]::RemoveEmptyEntries)) {
            $currentPath = [IO.Path]::Combine($currentPath, $segment)
            $pathsToCheck.Add($currentPath)
        }

        $finalItem = $null
        for ($index = 0; $index -lt $pathsToCheck.Count; $index++) {
            $pathToCheck = $pathsToCheck[$index]
            try {
                $item = Get-Item -LiteralPath $pathToCheck -Force -ErrorAction Stop
                $attributes = $item.Attributes
            } catch {
                return [pscustomobject]@{
                    Safe = $false
                    Path = $pathToCheck
                    Reason = ('path component cannot be inspected: ' + $_.Exception.Message)
                    Item = $null
                }
            }

            if ($item.PSProvider.Name -ne 'FileSystem') {
                return [pscustomobject]@{
                    Safe = $false
                    Path = $pathToCheck
                    Reason = ('only the FileSystem provider is allowed; got ' + $item.PSProvider.Name)
                    Item = $null
                }
            }
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
                $isFinalComponent = ($index -eq ($pathsToCheck.Count - 1))
                $reason = if ($isFinalComponent) {
                    'target is a junction, symlink, or other reparse point'
                } else {
                    ('path contains a junction, symlink, or other reparse point at ' + $pathToCheck)
                }
                return [pscustomobject]@{
                    Safe = $false
                    Path = $pathToCheck
                    Reason = $reason
                    Item = $null
                }
            }
            $finalItem = $item
        }

        return [pscustomobject]@{
            Safe = $true
            Path = $FullPath
            Reason = $null
            Item = $finalItem
        }
    } catch {
        return [pscustomobject]@{
            Safe = $false
            Path = $FullPath
            Reason = ('path chain cannot be validated: ' + $_.Exception.Message)
            Item = $null
        }
    }
}

function Get-WindowsCleanerScanExitCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [bool]$HadInvalid,

        [Parameter(Mandatory=$true)]
        [bool]$HadPartial
    )

    if ($HadInvalid) { return 2 }
    if ($HadPartial) { return 3 }
    return 0
}

function Measure-WindowsCleanerTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$FullPath,

        [ValidateRange(0, 100)]
        [int]$ErrorSampleLimit = 5
    )

    [long]$logicalBytes = 0
    [long]$fileCount = 0
    [long]$directoryCount = 0
    [long]$skippedReparse = 0
    [long]$errors = 0
    $errorSamples = [System.Collections.Generic.List[object]]::new()

    $addErrorSample = {
        param([string]$Path, [string]$Reason)
        if ($errorSamples.Count -lt $ErrorSampleLimit) {
            $errorSamples.Add([pscustomobject]@{ Path=$Path; Reason=$Reason })
        }
    }

    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($FullPath)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $enumerator = $null
        try {
            $currentAttributes = [IO.File]::GetAttributes($current)
            if ($currentAttributes -band [IO.FileAttributes]::ReparsePoint) {
                $skippedReparse++
                continue
            }
            $directory = [IO.DirectoryInfo]::new($current)
            $enumerator = $directory.EnumerateFileSystemInfos().GetEnumerator()
        } catch {
            $errors++
            & $addErrorSample $current $_.Exception.Message
            continue
        }

        try {
            while ($true) {
                try {
                    $hasNext = $enumerator.MoveNext()
                } catch {
                    $errors++
                    & $addErrorSample $current $_.Exception.Message
                    break
                }
                if (-not $hasNext) {
                    break
                }

                $child = $enumerator.Current
                try {
                    $attributes = $child.Attributes
                } catch {
                    $errors++
                    $samplePath = try { $child.FullName } catch { $current }
                    & $addErrorSample $samplePath $_.Exception.Message
                    continue
                }

                if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
                    $skippedReparse++
                    continue
                }
                if ($attributes -band [IO.FileAttributes]::Directory) {
                    $directoryCount++
                    $stack.Push($child.FullName)
                    continue
                }

                try {
                    $length = [long]$child.Length
                } catch {
                    $errors++
                    $samplePath = try { $child.FullName } catch { $current }
                    & $addErrorSample $samplePath $_.Exception.Message
                    continue
                }
                $fileCount++
                $logicalBytes += $length
            }
        } finally {
            if ($null -ne $enumerator) {
                $enumerator.Dispose()
            }
        }
    }

    [pscustomobject]@{
        LogicalBytes = $logicalBytes
        FileCount = $fileCount
        DirectoryCount = $directoryCount
        SkippedReparse = $skippedReparse
        Errors = $errors
        ErrorSamples = @($errorSamples)
    }
}
