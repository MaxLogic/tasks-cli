#requires -Version 7.0
<#
.SYNOPSIS
Uploads native Windows/Linux debug symbols for tasks-cli and tasks-viewer to Sentry.

.DESCRIPTION
Reads Sentry credentials from environment variables (`SENTRY_AUTH_TOKEN`,
`SENTRY_ORG`, `SENTRY_URL`) or, for local maintainer builds, from the untracked
`.private/integration/sentry-auth.env` and `.private/integration/sentry.json`
overlay files. Never prints the auth token. When no auth token is configured,
exits 0 cleanly unless `-FailIfUnconfigured` is specified so public fork and PR
builds remain green without secrets.
#>
[CmdletBinding()]
param(
    [ValidateSet('viewer', 'cli', 'all')]
    [string]$Component = 'all',

    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),

    [string]$ViewerRoot = (Split-Path -Parent $PSScriptRoot),

    [string]$CliTargetDirectory,

    [string]$FlutterRoot,

    [string]$SentryCliPath,

    [switch]$DryRun,

    [switch]$FailIfUnconfigured
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-SentryEnvFile {
    <#
    .SYNOPSIS
    Parses simple KEY=VALUE lines from a local private .env file.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $values = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $values
    }
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }
        $idx = $trimmed.IndexOf('=')
        if ($idx -le 0) {
            continue
        }
        $key = $trimmed.Substring(0, $idx).Trim()
        $val = $trimmed.Substring($idx + 1).Trim().Trim('"').Trim("'")
        $values[$key] = $val
    }
    return $values
}

function Resolve-SentryUploadConfiguration {
    <#
    .SYNOPSIS
    Resolves Sentry URL, org, and auth token from environment or local private overlay.
    #>
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [hashtable]$EnvironmentOverride
    )

    $envMap = if ($null -ne $EnvironmentOverride) {
        $EnvironmentOverride
    }
    else {
        @{
            SENTRY_URL        = $env:SENTRY_URL
            SENTRY_ORG        = $env:SENTRY_ORG
            SENTRY_AUTH_TOKEN = $env:SENTRY_AUTH_TOKEN
            TASKS_SENTRY_USE_PRIVATE_OVERLAY = $env:TASKS_SENTRY_USE_PRIVATE_OVERLAY
        }
    }

    $url = [string]$envMap['SENTRY_URL']
    $org = [string]$envMap['SENTRY_ORG']
    $token = [string]$envMap['SENTRY_AUTH_TOKEN']

    $allowPrivate = ([string]$envMap['TASKS_SENTRY_USE_PRIVATE_OVERLAY']) -ne '0'
    if ($allowPrivate) {
        $authEnvPath = Join-Path -Path $RepositoryRoot -ChildPath '.private/integration/sentry-auth.env'
        $fromEnvFile = Read-SentryEnvFile -Path $authEnvPath
        if ([string]::IsNullOrWhiteSpace($url) -and $fromEnvFile.ContainsKey('SENTRY_URL')) {
            $url = $fromEnvFile['SENTRY_URL']
        }
        if ([string]::IsNullOrWhiteSpace($org) -and $fromEnvFile.ContainsKey('SENTRY_ORG')) {
            $org = $fromEnvFile['SENTRY_ORG']
        }
        if ([string]::IsNullOrWhiteSpace($token) -and $fromEnvFile.ContainsKey('SENTRY_AUTH_TOKEN')) {
            $token = $fromEnvFile['SENTRY_AUTH_TOKEN']
        }

        $sentryJsonPath = Join-Path -Path $RepositoryRoot -ChildPath '.private/integration/sentry.json'
        if (Test-Path -LiteralPath $sentryJsonPath -PathType Leaf) {
            $meta = Get-Content -LiteralPath $sentryJsonPath -Raw | ConvertFrom-Json
            if ([string]::IsNullOrWhiteSpace($url) -and -not [string]::IsNullOrWhiteSpace($meta.region_url)) {
                $url = [string]$meta.region_url
            }
            if ([string]::IsNullOrWhiteSpace($org) -and -not [string]::IsNullOrWhiteSpace($meta.org)) {
                $org = [string]$meta.org
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($url)) {
        $url = 'https://de.sentry.io/'
    }
    if (-not $url.EndsWith('/')) {
        $url = "$url/"
    }

    return [pscustomobject]@{
        Url        = $url
        Org        = $org.Trim()
        AuthToken  = $token.Trim()
        Configured = (-not [string]::IsNullOrWhiteSpace($token)) -and (-not [string]::IsNullOrWhiteSpace($org))
    }
}

function Resolve-SentryCliExecutable {
    <#
    .SYNOPSIS
    Locates sentry-cli on PATH or in the standard user tool directory.
    #>
    param([string]$ExplicitPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        if (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($ExplicitPath)
        }
        throw "Configured sentry-cli path '$ExplicitPath' does not exist."
    }

    $cmd = Get-Command -Name 'sentry-cli' -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        return $cmd.Source
    }

    $candidates = @()
    if ($IsWindows -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates += (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'MaxLogic/tools/sentry-cli.exe')
        $candidates += (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'sentry-cli/sentry-cli.exe')
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
        $candidates += (Join-Path -Path $env:HOME -ChildPath '.local/bin/sentry-cli')
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    return $null
}

function Get-SentryDebugSymbolPaths {
    <#
    .SYNOPSIS
    Collects existing symbol and native binary paths for one component.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('viewer', 'cli')][string]$Component,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ViewerRoot,
        [string]$CliTargetDirectory,
        [string]$FlutterRoot
    )

    $paths = [System.Collections.Generic.List[string]]::new()
    if ($Component -eq 'cli') {
        $targetDir = if ([string]::IsNullOrWhiteSpace($CliTargetDirectory)) {
            Join-Path -Path $RepositoryRoot -ChildPath 'target'
        }
        else {
            $CliTargetDirectory
        }
        $releaseDir = Join-Path -Path $targetDir -ChildPath 'release'
        foreach ($leaf in @('tasks.exe', 'tasks.pdb', 'tasks', 'tasks-server.exe', 'tasks-server.pdb', 'tasks-server')) {
            $candidate = Join-Path -Path $releaseDir -ChildPath $leaf
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $paths.Add([System.IO.Path]::GetFullPath($candidate))
            }
        }
        return @($paths)
    }

    # Viewer symbols (Windows release runner + PDBs + matching Flutter engine PDB).
    $symbolsDir = Join-Path -Path $ViewerRoot -ChildPath 'build/windows/x64/symbols/Release'
    if (Test-Path -LiteralPath $symbolsDir -PathType Container) {
        foreach ($pdb in Get-ChildItem -LiteralPath $symbolsDir -Filter '*.pdb' -File) {
            $paths.Add($pdb.FullName)
        }
    }
    $runnerReleaseDir = Join-Path -Path $ViewerRoot -ChildPath 'build/windows/x64/runner/Release'
    if (Test-Path -LiteralPath $runnerReleaseDir -PathType Container) {
        foreach ($binary in Get-ChildItem -LiteralPath $runnerReleaseDir -File | Where-Object { $_.Extension -in @('.exe', '.dll', '.pdb') }) {
            $paths.Add($binary.FullName)
        }
        $appSo = Join-Path -Path $runnerReleaseDir -ChildPath 'data/app.so'
        if (Test-Path -LiteralPath $appSo -PathType Leaf) {
            $paths.Add($appSo)
        }
    }

    $resolvedFlutter = $FlutterRoot
    if ([string]::IsNullOrWhiteSpace($resolvedFlutter)) {
        $resolvedFlutter = $env:FLUTTER_ROOT
    }
    if ([string]::IsNullOrWhiteSpace($resolvedFlutter)) {
        $flutterCmd = Get-Command -Name 'flutter.bat' -ErrorAction SilentlyContinue
        if ($null -eq $flutterCmd) {
            $flutterCmd = Get-Command -Name 'flutter' -ErrorAction SilentlyContinue
        }
        if ($null -ne $flutterCmd) {
            $resolvedFlutter = Split-Path -Parent (Split-Path -Parent $flutterCmd.Source)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedFlutter)) {
        $enginePdb = Join-Path -Path $resolvedFlutter -ChildPath 'bin/cache/artifacts/engine/windows-x64-release/flutter_windows.dll.pdb'
        if (Test-Path -LiteralPath $enginePdb -PathType Leaf) {
            $paths.Add([System.IO.Path]::GetFullPath($enginePdb))
        }
    }

    return @($paths | Select-Object -Unique)
}

function Invoke-SentrySymbolUpload {
    <#
    .SYNOPSIS
    Uploads collected debug files to Sentry for the requested component(s).
    #>
    param(
        [ValidateSet('viewer', 'cli', 'all')]
        [string]$Component = 'all',
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ViewerRoot,
        [string]$CliTargetDirectory,
        [string]$FlutterRoot,
        [string]$SentryCliPath,
        [switch]$DryRun,
        [switch]$FailIfUnconfigured
    )

    $config = Resolve-SentryUploadConfiguration -RepositoryRoot $RepositoryRoot
    if (-not $config.Configured) {
        if ($FailIfUnconfigured) {
            throw 'Sentry symbol upload is not configured (missing SENTRY_AUTH_TOKEN or SENTRY_ORG).'
        }
        return [pscustomobject]@{
            Ok      = $true
            Skipped = $true
            Reason  = 'Sentry upload credentials are not configured; skipping symbol upload.'
            Uploads = @()
        }
    }

    $cli = Resolve-SentryCliExecutable -ExplicitPath $SentryCliPath
    if ([string]::IsNullOrWhiteSpace($cli)) {
        if ($FailIfUnconfigured) {
            throw 'sentry-cli executable not found on PATH or in %LOCALAPPDATA%\MaxLogic\tools\sentry-cli.exe.'
        }
        return [pscustomobject]@{
            Ok      = $true
            Skipped = $true
            Reason  = 'sentry-cli is not installed on this machine; skipping symbol upload.'
            Uploads = @()
        }
    }

    $components = if ($Component -eq 'all') { @('cli', 'viewer') } else { @($Component) }
    $uploads = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $components) {
        $project = if ($item -eq 'viewer') { 'tasks-viewer' } else { 'tasks-cli' }
        $files = @(Get-SentryDebugSymbolPaths -Component $item -RepositoryRoot $RepositoryRoot `
                -ViewerRoot $ViewerRoot -CliTargetDirectory $CliTargetDirectory -FlutterRoot $FlutterRoot)
        if ($files.Count -eq 0) {
            $uploads.Add([pscustomobject]@{
                    Component = $item
                    Project   = $project
                    FileCount = 0
                    Skipped   = $true
                    ExitCode  = 0
                })
            continue
        }

        if ($DryRun) {
            $uploads.Add([pscustomobject]@{
                    Component = $item
                    Project   = $project
                    FileCount = $files.Count
                    Files     = $files
                    Skipped   = $false
                    DryRun    = $true
                    ExitCode  = 0
                })
            continue
        }

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $cli
        $startInfo.WorkingDirectory = $RepositoryRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Environment['SENTRY_URL'] = $config.Url
        $startInfo.Environment['SENTRY_ORG'] = $config.Org
        $startInfo.Environment['SENTRY_AUTH_TOKEN'] = $config.AuthToken

        foreach ($arg in @('debug-files', 'upload', '--org', $config.Org, '--project', $project)) {
            [void]$startInfo.ArgumentList.Add($arg)
        }
        foreach ($file in $files) {
            [void]$startInfo.ArgumentList.Add($file)
        }

        $process = [System.Diagnostics.Process]::Start($startInfo)
        try {
            $stdOut = $process.StandardOutput.ReadToEndAsync()
            $stdErr = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) {
                throw "sentry-cli debug-files upload failed for $project (exit $($process.ExitCode)): $($stdErr.Result)"
            }
            $uploads.Add([pscustomobject]@{
                    Component = $item
                    Project   = $project
                    FileCount = $files.Count
                    Skipped   = $false
                    DryRun    = $false
                    ExitCode  = $process.ExitCode
                    Summary   = $stdOut.Result.Trim()
                })
        }
        finally {
            $process.Dispose()
        }
    }

    return [pscustomobject]@{
        Ok      = $true
        Skipped = $false
        Reason  = $null
        Uploads = @($uploads)
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-SentrySymbolUpload -Component $Component -RepositoryRoot $RepositoryRoot `
            -ViewerRoot $ViewerRoot -CliTargetDirectory $CliTargetDirectory `
            -FlutterRoot $FlutterRoot -SentryCliPath $SentryCliPath `
            -DryRun:$DryRun -FailIfUnconfigured:$FailIfUnconfigured
        if ($result.Skipped) {
            Write-Information -MessageData "sentry-symbols: skipped ($($result.Reason))" -InformationAction Continue
        }
        else {
            foreach ($entry in $result.Uploads) {
                Write-Information -MessageData ("sentry-symbols: {0} -> {1} ({2} files, exit {3})" -f `
                        $entry.Component, $entry.Project, $entry.FileCount, $entry.ExitCode) -InformationAction Continue
            }
        }
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}
