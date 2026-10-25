#requires -Version 7.0
# Shared path checks for lane-owned tooling outputs. No writes on import.

function Assert-ToolOutputPath {
    param([Parameter(Mandatory)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $ancestor = $full
    while (-not [string]::IsNullOrEmpty($ancestor)) {
        $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing output '$full': reparse point '$ancestor' could redirect writes."
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    return $full
}

function Resolve-ToolCliTarget {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$CliTargetDirectory
    )

    if ([string]::IsNullOrWhiteSpace($CliTargetDirectory)) {
        $CliTargetDirectory = Join-Path $RepositoryRoot 'target/verify-cli'
    }
    $full = Assert-ToolOutputPath -Path $CliTargetDirectory
    $installedTarget = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'target')).TrimEnd('\', '/')
    if ($full.Equals($installedTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing CLI target '$full': this replaces the installed CLI. Use a lane target directory."
    }
    return $full
}
