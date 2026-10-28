#requires -Version 7.0
<#
.SYNOPSIS
Assembles the portable viewer release bundle with its matching CLI.

.DESCRIPTION
viewer/spec.md section 11 requires this script to put the full runner bundle and
the matching CLI in target/viewer-release/, write hashes and check a launch from
a path containing spaces and non-ASCII characters.

The script builds the Flutter Windows release bundle by default, adds the matching
`tasks.exe`, validates every bundled Bella clip against the committed catalog
and provenance manifest, refuses to ship an ElevenLabs API key, writes
SHA256SUMS.txt plus bundle-metadata.json and then launch-tests a copy that lives
under a path with spaces and non-ASCII characters.

The launch test is headless on purpose. It exercises the `--startup` opt-out
exit path (a saved `start_with_windows: false` launch must return before any
window exists), the argument-error path and the packaged CLI, and it fails when
a process does not exit by itself. It never delivers keyboard or mouse input,
so it is safe to run on a workstation that is in use. Opening the real window
and the NVDA walkthroughs stay manual and are not claimed here.

.EXAMPLE
pwsh -NoProfile -File viewer/tool/package.ps1

.EXAMPLE
pwsh -NoProfile -File viewer/tool/package.ps1 -EvidenceRoot target/evidence/viewer/run/package
#>
[CmdletBinding()]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '',
    Justification = 'The repository keeps PowerShell sources in UTF-8 without a BOM; the packaged launch test needs a real non-ASCII path.')]
param(
    [string]$ViewerRoot = (Split-Path -Parent $PSScriptRoot),

    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),

    [string]$OutputRoot,

    [string]$CliTargetDirectory,

    [string]$PackageParentRoot,

    [string]$PackageSourceRoot,

    [string]$CliExecutable,

    [string]$FfprobePath,

    [string]$AnnouncementToolPath,

    [string]$EvidenceRoot,

    [string]$WorkingRoot,

    [int]$LaunchTimeoutSeconds = 60,

    [switch]$KeepLaunchRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'tool-paths.ps1')

function Write-PackageMessage {
    <#
    .SYNOPSIS
    Writes one progress line to the host without polluting function output.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    Write-Information -MessageData $Message -InformationAction Continue
}

function Resolve-PackageOutputRoot {
    <#
    .SYNOPSIS
    Validates that the package output stays inside the repository target tree.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$AllowedRoot
    )

    $allowedFull = [System.IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\', '/')
    $targetFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $requiredPrefix = $allowedFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $targetFull.StartsWith($requiredPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use '$targetFull': the package output must stay inside '$allowedFull'."
    }

    return Assert-ToolOutputPath -Path $targetFull
}

function Get-BundleRelativePath {
    <#
    .SYNOPSIS
    Returns the slash-separated path of one file inside the bundle root.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "File '$pathFull' is not inside the bundle root '$rootFull'."
    }

    return $pathFull.Substring($rootFull.Length).Replace('\', '/')
}

function Assert-BundlePath {
    <#
    .SYNOPSIS
    Rejects bundle paths redirected by any reparse point in their ancestry.
    #>
    param([Parameter(Mandatory)][string]$Path)
    try { $null = Assert-ToolOutputPath -Path $Path }
    catch { throw "Refusing bundle '$Path': $($_.Exception.Message)" }
}

function Get-BundleFile {
    <#
    .SYNOPSIS
    Lists every file of one bundle, sorted by path, optionally excluding one.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [string]$ExcludedPath
    )

    $excludedFull = ''
    if (-not [string]::IsNullOrWhiteSpace($ExcludedPath)) {
        $excludedFull = [System.IO.Path]::GetFullPath($ExcludedPath)
    }

    # Materialize the whole traversal before returning any file. Never follow links.
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    Assert-BundlePath -Path $rootFull
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($rootFull)
    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    while ($pending.Count -gt 0) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "Refusing bundle '$rootFull': reparse point '$($item.FullName)' is not allowed."
            }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            elseif ($item.FullName -ne $excludedFull) { $files.Add($item) }
        }
    }
    return @($files | Sort-Object -Property FullName)
}

function Copy-PackageFile {
    <#
    .SYNOPSIS
    Copies only unnamed-stream bytes to a new file and hashes the same buffers.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )
    $sourceFull = [System.IO.Path]::GetFullPath($SourcePath)
    $destinationFull = [System.IO.Path]::GetFullPath($DestinationPath)
    foreach ($path in @($sourceFull, $destinationFull)) {
        if ($path.Substring([System.IO.Path]::GetPathRoot($path).Length).Contains(':')) {
            throw "Only an unnamed data stream may be copied: '$path'."
        }
    }
    Assert-BundlePath -Path $sourceFull
    $null = Assert-ToolOutputPath -Path $destinationFull
    if (Test-Path -LiteralPath $destinationFull) {
        throw "Refusing to reuse '$destinationFull': destination already exists; a new file is required."
    }
    $readStream = $null
    $writeStream = $null
    $hasher = [System.Security.Cryptography.IncrementalHash]::CreateHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $readStream = [System.IO.FileStream]::new($sourceFull, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $writeStream = [System.IO.FileStream]::new($destinationFull, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = [byte[]]::new(81920)
        while (($count = $readStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $writeStream.Write($buffer, 0, $count)
            $hasher.AppendData($buffer, 0, $count)
        }
        $writeStream.Flush()
        $copiedHash = [BitConverter]::ToString($hasher.GetHashAndReset()).Replace('-', '').ToLowerInvariant()
        if (-not [string]::Equals($copiedHash, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing '$destinationFull': copied bundle manifest mismatch for '$sourceFull' (hash while copying)."
        }
    }
    finally {
        if ($null -ne $writeStream) { $writeStream.Dispose() }
        if ($null -ne $readStream) { $readStream.Dispose() }
        $hasher.Dispose()
    }
}

function Copy-PackageBundle {
    <#
    .SYNOPSIS
    Copies the Flutter runner bundle and the matching CLI into the output root.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$CliExecutable,

        [Parameter(Mandatory)]
        [string]$DestinationRoot,

        [string[]]$ExpectedManifest
    )

    $files = @(Get-BundleFile -Root $SourceRoot)
    $suppliedManifest = $null -ne $ExpectedManifest -and $ExpectedManifest.Count -gt 0
    if (-not $suppliedManifest) {
        $ExpectedManifest = @(Get-PackageBundleManifest -Root $SourceRoot -IncludeStamp)
    }
    $expected = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($line in $ExpectedManifest) {
        $parts = $line -split '  ', 2
        $expected.Add($parts[1], $parts[0])
    }
    $cliKey = @($expected.Keys | Where-Object { $_ -ieq 'tasks.exe' } | Select-Object -First 1)
    $cliRelative = if ($cliKey.Count -gt 0) { $cliKey[0] } else { 'tasks.exe' }
    if (-not $suppliedManifest) {
        $expected[$cliRelative] = (Get-FileHash -LiteralPath $CliExecutable -Algorithm SHA256).Hash
    }
    if (-not $expected.ContainsKey($cliRelative)) {
        throw 'The copied bundle manifest does not cover the selected CLI.'
    }
    $destinationFull = Assert-ToolOutputPath -Path $DestinationRoot
    New-Item -ItemType Directory -Force -Path $destinationFull | Out-Null
    foreach ($file in $files) {
        $relative = Get-BundleRelativePath -Root $SourceRoot -Path $file.FullName
        # The selected CLI replaces any root-level CLI from the source bundle.
        if ($relative -ieq 'tasks.exe') { continue }
        if (-not $expected.ContainsKey($relative)) {
            throw "Refusing '$relative': copied bundle manifest mismatch (unexpected source file)."
        }
        $destination = Join-Path $destinationFull $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-PackageFile -SourcePath $file.FullName -DestinationPath $destination -ExpectedSha256 $expected[$relative]
    }

    Copy-PackageFile -SourcePath $CliExecutable -DestinationPath (Join-Path $destinationFull $cliRelative) -ExpectedSha256 $expected[$cliRelative]
}

function Find-BundleCredential {
    <#
    .SYNOPSIS
    Scans every bundled byte for an ElevenLabs credential marker.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $markers = @('ELEVENLABS_API_KEY', 'xi-api-key')
    $findings = [System.Collections.Generic.List[string]]::new()
    foreach ($file in Get-BundleFile -Root $Root) {
        $text = [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes($file.FullName))
        foreach ($marker in $markers) {
            if ($text.Contains($marker, [System.StringComparison]::OrdinalIgnoreCase)) {
                $relative = Get-BundleRelativePath -Root $Root -Path $file.FullName
                $findings.Add("Bundled file '$relative' contains the credential marker '$marker'.")
            }
        }
    }

    return $findings
}

function Write-BundleHashFile {
    <#
    .SYNOPSIS
    Writes a sha256sum-compatible hash list for every other bundled file.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$HashPath
    )

    $lines = foreach ($file in Get-BundleFile -Root $Root -ExcludedPath $HashPath) {
        '{0}  {1}' -f (Get-FileSha256 -Path $file.FullName), (Get-BundleRelativePath -Root $Root -Path $file.FullName)
    }
    Set-Content -LiteralPath $HashPath -Value @($lines) -Encoding utf8NoBOM
}

function Invoke-CapturedProcess {
    <#
    .SYNOPSIS
    Runs one process with captured output and a hard timeout.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdOutTask = $process.StandardOutput.ReadToEndAsync()
        $stdErrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(10000)
            return [pscustomobject]@{
                TimedOut = $true
                ExitCode = -1
                StdOut   = ''
                StdErr   = "The process did not exit within $TimeoutSeconds s and was killed."
            }
        }

        $process.WaitForExit()
        return [pscustomobject]@{
            TimedOut = $false
            ExitCode = $process.ExitCode
            StdOut   = $stdOutTask.Result
            StdErr   = $stdErrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-BundleSettingsRoot {
    <#
    .SYNOPSIS
    Creates the throwaway settings root that proves the startup opt-out path.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $settingsRoot = Join-Path -Path $Root -ChildPath 'settings'
    New-Item -ItemType Directory -Force -Path $settingsRoot | Out-Null
    $document = [ordered]@{
        schema_version     = 1
        start_with_windows = $false
    }
    Set-Content -LiteralPath (Join-Path -Path $settingsRoot -ChildPath 'viewer-settings.json') `
        -Value ($document | ConvertTo-Json) -Encoding utf8NoBOM
    return $settingsRoot
}

function Invoke-BundleLaunchTest {
    <#
    .SYNOPSIS
    Launch-tests a copied bundle from a path with spaces and non-ASCII characters.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BundleRoot,

        [Parameter(Mandatory)]
        [string]$WorkingRoot,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $launchRoot = Join-Path -Path $WorkingRoot -ChildPath ("Maks Zaźółć gęślą jaźń {0}" -f [guid]::NewGuid().ToString('n').Substring(0, 8))
    $copyRoot = Join-Path -Path $launchRoot -ChildPath 'bundle'
    New-Item -ItemType Directory -Force -Path $copyRoot | Out-Null
    Copy-PackageBundle -SourceRoot $BundleRoot -CliExecutable (Join-Path $BundleRoot 'tasks.exe') -DestinationRoot $copyRoot

    $settingsRoot = Get-BundleSettingsRoot -Root $launchRoot
    $viewerExe = Join-Path -Path $copyRoot -ChildPath 'tasks_viewer.exe'
    $cliExe = Join-Path -Path $copyRoot -ChildPath 'tasks.exe'
    $cases = [System.Collections.Generic.List[object]]::new()

    $optOut = Invoke-CapturedProcess -FilePath $viewerExe `
        -Arguments @('--startup', '--settings-root', $settingsRoot) `
        -WorkingDirectory $copyRoot -TimeoutSeconds $TimeoutSeconds
    $cases.Add([pscustomobject]@{
            Name     = 'startup-opt-out'
            TimedOut = $optOut.TimedOut
            ExitCode = $optOut.ExitCode
            Ok       = (-not $optOut.TimedOut) -and ($optOut.ExitCode -eq 0)
        })

    $badArgs = Invoke-CapturedProcess -FilePath $viewerExe -Arguments @('--test-mode') `
        -WorkingDirectory $copyRoot -TimeoutSeconds $TimeoutSeconds
    $cases.Add([pscustomobject]@{
            Name     = 'argument-error'
            TimedOut = $badArgs.TimedOut
            ExitCode = $badArgs.ExitCode
            Ok       = (-not $badArgs.TimedOut) -and ($badArgs.ExitCode -eq 2) -and
                $badArgs.StdErr.Contains('Test mode requires', [System.StringComparison]::Ordinal)
        })

    $version = Invoke-CapturedProcess -FilePath $cliExe -Arguments @('--version') `
        -WorkingDirectory $copyRoot -TimeoutSeconds $TimeoutSeconds
    $cases.Add([pscustomobject]@{
            Name     = 'cli-version'
            TimedOut = $version.TimedOut
            ExitCode = $version.ExitCode
            Ok       = (-not $version.TimedOut) -and ($version.ExitCode -eq 0) -and
                (-not [string]::IsNullOrWhiteSpace($version.StdOut))
        })

    $info = Invoke-CapturedProcess -FilePath $cliExe -Arguments @('--format', 'json', 'viewer', 'info') `
        -WorkingDirectory $copyRoot -TimeoutSeconds $TimeoutSeconds
    $protocolVersion = -1
    if (-not $info.TimedOut -and $info.ExitCode -eq 0) {
        $parsed = $info.StdOut | ConvertFrom-Json
        $protocolVersion = [int]$parsed.data.protocol_version
    }
    $cases.Add([pscustomobject]@{
            Name     = 'cli-viewer-info'
            TimedOut = $info.TimedOut
            ExitCode = $info.ExitCode
            Ok       = (-not $info.TimedOut) -and ($info.ExitCode -eq 0) -and ($protocolVersion -ge 1)
        })

    return [pscustomobject]@{
        LaunchRoot      = $launchRoot
        BundleRoot      = $copyRoot
        SettingsRoot    = $settingsRoot
        ProtocolVersion = $protocolVersion
        Cases           = @($cases)
        Ok              = -not ($cases | Where-Object { -not $_.Ok })
    }
}

function Get-SourceIdentity {
    <#
    .SYNOPSIS
    Reads the source commit and dirty flag recorded in the bundle metadata.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $commit = $null
    $dirty = $null
    try {
        $commit = (& git -C $RepositoryRoot rev-parse HEAD 2>$null | Select-Object -First 1)
        $status = & git -C $RepositoryRoot status --porcelain 2>$null
        $dirty = -not [string]::IsNullOrWhiteSpace(($status -join ''))
    }
    catch {
        $commit = $null
        $dirty = $null
    }

    return [pscustomobject]@{ Commit = $commit; Dirty = $dirty }
}

function Get-ViewerSourceFingerprint {
    <#
    .SYNOPSIS
    Hashes versioned and unignored viewer build inputs, including dirty edits.
    #>
    param([string]$ViewerRoot)
    $paths = @(& git -c core.quotepath=false -C $ViewerRoot ls-files --cached --others --exclude-standard -- lib windows assets 'pubspec.*')
    if ($LASTEXITCODE -ne 0 -or $paths.Count -eq 0) {
        throw "Cannot enumerate viewer inputs in '$ViewerRoot'; packaging requires a Git checkout."
    }
    $lines = foreach ($path in $paths | Sort-Object -Unique) {
        $file = Join-Path $ViewerRoot $path
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            "$path $((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant())"
        }
        else { "$path MISSING" }
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}

function Get-PackageBundleManifest {
    <#
    .SYNOPSIS
    Records every bundle file except the build stamp, sorted by relative path.
    #>
    param([Parameter(Mandatory)][string]$Root, [switch]$IncludeStamp)
    $stampPath = if ($IncludeStamp) { '' } else { Join-Path $Root 'viewer-build-stamp.json' }
    $files = [System.Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($file in Get-BundleFile -Root $Root -ExcludedPath $stampPath) {
        $relative = Get-BundleRelativePath -Root $Root -Path $file.FullName
        $files.Add($relative, (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())
    }
    foreach ($entry in $files.GetEnumerator()) {
        "$($entry.Value)  $($entry.Key)"
    }
}

function Get-PackageCopyManifest {
    <#
    .SYNOPSIS
    Adds the stamp and selected CLI to the verified Flutter payload manifest.
    #>
    param([string[]]$PayloadManifest, [string]$SourceRoot, [string]$CliExecutable)
    $files = [System.Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($line in $PayloadManifest) {
        $parts = $line -split '  ', 2
        $files.Add($parts[1], $parts[0])
    }
    $stamp = Join-Path $SourceRoot 'viewer-build-stamp.json'
    $files.Add('viewer-build-stamp.json', (Get-FileHash -LiteralPath $stamp -Algorithm SHA256).Hash.ToLowerInvariant())
    $cliKey = @($files.Keys | Where-Object { $_ -ieq 'tasks.exe' } | Select-Object -First 1)
    $cliPath = if ($cliKey.Count -gt 0) { $cliKey[0] } else { 'tasks.exe' }
    $files[$cliPath] = (Get-FileHash -LiteralPath $CliExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
    foreach ($entry in $files.GetEnumerator()) { "$($entry.Value)  $($entry.Key)" }
}

function Invoke-PackageFlutterBuild {
    <#
    .SYNOPSIS
    Uses the verifier's launcher and release flags without importing its helpers into the caller.
    #>
    param([string]$ViewerRoot, [string]$EvidenceRoot)
    $result = & {
        param($buildViewerRoot)
        . (Join-Path $PSScriptRoot 'verify-windows.ps1')
        $launcher = Resolve-FlutterLauncher
        Invoke-FlutterCommand -Launcher $launcher -Arguments @('build', 'windows', '--release') `
            -WorkingDirectory $buildViewerRoot -TimeoutSeconds 1800
    } $ViewerRoot
    $log = "flutter build windows --release`nexit: $($result.ExitCode)`ntimed_out: $($result.TimedOut)`n$($result.StdOut)`n$($result.StdErr)"
    if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $EvidenceRoot 'package-flutter-build.log') -Value $log -Encoding utf8NoBOM
    }
    Write-PackageMessage -Message $log
    if ($result.TimedOut -or $result.ExitCode -ne 0) {
        throw "Flutter release build failed (exit $($result.ExitCode), timeout $($result.TimedOut)); no bundle was packaged."
    }
}

function Invoke-PackageTool {
    <#
    .SYNOPSIS
    Runs the packaging batch and returns its structured result.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ViewerRoot,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [string]$OutputRoot,

        [string]$CliTargetDirectory,

        [string]$PackageParentRoot,

        [string]$PackageSourceRoot,

        [string]$CliExecutable,

        [string]$FfprobePath,

        [string]$AnnouncementToolPath,

        [string]$EvidenceRoot,

        [string]$WorkingRoot,

        [int]$LaunchTimeoutSeconds = 60,

        [switch]$KeepLaunchRoot
    )

    $findings = [System.Collections.Generic.List[string]]::new()
    $viewerFull = [System.IO.Path]::GetFullPath($ViewerRoot)
    $repositoryFull = [System.IO.Path]::GetFullPath($RepositoryRoot)
    if ([string]::IsNullOrWhiteSpace($PackageParentRoot)) {
        $PackageParentRoot = Join-Path $repositoryFull 'target'
    }
    $targetRoot = Assert-ToolOutputPath -Path $PackageParentRoot
    if ([string]::IsNullOrWhiteSpace($CliTargetDirectory)) {
        $CliTargetDirectory = Join-Path $repositoryFull 'target'
    }
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $OutputRoot = Join-Path -Path $targetRoot -ChildPath 'viewer-release'
    }
    if ([string]::IsNullOrWhiteSpace($CliExecutable)) {
        $CliExecutable = Join-Path -Path $CliTargetDirectory -ChildPath 'release/tasks.exe'
    }
    if ([string]::IsNullOrWhiteSpace($WorkingRoot)) {
        $WorkingRoot = [System.IO.Path]::GetTempPath()
    }
    if ([string]::IsNullOrWhiteSpace($AnnouncementToolPath)) {
        $AnnouncementToolPath = Join-Path -Path $PSScriptRoot -ChildPath 'generate-announcements.ps1'
    }

    $outputFull = Resolve-PackageOutputRoot -Path $OutputRoot -AllowedRoot $targetRoot
    $buildFlutter = [string]::IsNullOrWhiteSpace($PackageSourceRoot)
    if ($buildFlutter) {
        $PackageSourceRoot = Join-Path $viewerFull 'build/windows/x64/runner/Release'
    }
    $bundleSource = [System.IO.Path]::GetFullPath($PackageSourceRoot)
    Assert-BundlePath -Path $bundleSource
    if (Test-Path -LiteralPath $bundleSource -PathType Container) {
        $null = @(Get-BundleFile -Root $bundleSource)
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        $EvidenceRoot = Assert-ToolOutputPath -Path $EvidenceRoot
    }
    $sourceIdentity = Get-SourceIdentity -RepositoryRoot $repositoryFull
    if ([string]::IsNullOrWhiteSpace($sourceIdentity.Commit)) {
        throw 'Cannot resolve the current source commit; packaging requires a Git checkout.'
    }
    $sourceFingerprint = Get-ViewerSourceFingerprint -ViewerRoot $viewerFull
    $stampPath = Join-Path $bundleSource 'viewer-build-stamp.json'
    if ($buildFlutter) {
        # Invalidate a previous successful stamp before attempting the new build.
        if (Test-Path -LiteralPath $stampPath) { Remove-Item -LiteralPath $stampPath -Force }
        Write-PackageMessage -Message 'package: building Flutter Windows release'
        Invoke-PackageFlutterBuild -ViewerRoot $viewerFull -EvidenceRoot $EvidenceRoot
        if ($sourceFingerprint -ne (Get-ViewerSourceFingerprint -ViewerRoot $viewerFull)) {
            throw 'Viewer inputs changed during the Flutter build; run packaging again on stable sources.'
        }
        $builtViewer = Join-Path $bundleSource 'tasks_viewer.exe'
        if (-not (Test-Path -LiteralPath $builtViewer -PathType Leaf)) {
            throw "Flutter release build did not produce '$builtViewer'; no bundle was packaged."
        }
        $bundleManifest = @(Get-PackageBundleManifest -Root $bundleSource)
        [ordered]@{
            source_commit = $sourceIdentity.Commit
            source_fingerprint = $sourceFingerprint
            generated_utc = (Get-Date).ToUniversalTime().ToString('o')
            bundle_files = $bundleManifest
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stampPath -Encoding utf8NoBOM
    }
    else {
        if (-not (Test-Path -LiteralPath $stampPath -PathType Leaf)) {
            throw "Refusing prebuilt bundle '$bundleSource': missing viewer-build-stamp.json. Run package.ps1 without -PackageSourceRoot to build and stamp it."
        }
        try {
            $stamp = Get-Content -LiteralPath $stampPath -Raw | ConvertFrom-Json
            if ([string]::IsNullOrWhiteSpace($stamp.source_commit) -or [string]::IsNullOrWhiteSpace($stamp.source_fingerprint)) {
                throw 'Incomplete build stamp.'
            }
        }
        catch { throw "Refusing prebuilt bundle '$bundleSource': invalid build stamp. Rebuild with package.ps1." }
        if ($stamp.source_commit -ne $sourceIdentity.Commit -or $stamp.source_fingerprint -ne $sourceFingerprint) {
            throw "Refusing prebuilt bundle '$bundleSource': stale build stamp (commit or viewer inputs differ). Run package.ps1 without -PackageSourceRoot."
        }
        $manifestProperty = $stamp.PSObject.Properties['bundle_files']
        if ($null -eq $manifestProperty -or @($manifestProperty.Value).Count -eq 0) {
            throw "Refusing prebuilt bundle '$bundleSource': missing bundle manifest in the build stamp. Rebuild with package.ps1."
        }
        $bundleManifest = @($manifestProperty.Value)
        $actualManifest = @(Get-PackageBundleManifest -Root $bundleSource)
        if (-not [string]::Equals(($manifestProperty.Value -join "`n"), ($actualManifest -join "`n"), [StringComparison]::Ordinal)) {
            throw "Refusing prebuilt bundle '$bundleSource': bundle manifest mismatch (modified, missing or extra file). Rebuild with package.ps1."
        }
    }
    $announcementsDirectory = Join-Path -Path $viewerFull -ChildPath 'assets/announcements'
    $catalogPath = Join-Path -Path $announcementsDirectory -ChildPath 'catalog.json'

    foreach ($required in @(
            [pscustomobject]@{ Path = $bundleSource; Kind = 'Container'; Hint = 'run: flutter build windows --release' }
            [pscustomobject]@{ Path = $CliExecutable; Kind = 'Leaf'; Hint = 'run: cargo build --release --locked' }
            [pscustomobject]@{ Path = $catalogPath; Kind = 'Leaf'; Hint = 'the committed announcement catalog is missing' }
            [pscustomobject]@{ Path = $AnnouncementToolPath; Kind = 'Leaf'; Hint = 'generate-announcements.ps1 is missing' }
        )) {
        if (-not (Test-Path -LiteralPath $required.Path -PathType $required.Kind)) {
            $findings.Add("Required input '$($required.Path)' does not exist ($($required.Hint)).")
        }
    }
    if ($findings.Count -gt 0) {
        return [pscustomobject]@{
            Ok         = $false
            Findings   = @($findings)
            OutputRoot = $outputFull
        }
    }

    . $AnnouncementToolPath
    $ffprobeExecutable = Resolve-FfprobeExecutable -FfprobePath $FfprobePath

    Write-PackageMessage -Message "package: verifying bundled clips against '$catalogPath'"
    $clipResult = Test-AnnouncementBundle -AnnouncementsDirectory $announcementsDirectory `
        -CatalogPath $catalogPath -FfprobeExecutable $ffprobeExecutable
    foreach ($clipFinding in $clipResult.Findings) {
        $findings.Add("Bella clips: $clipFinding")
    }
    $clipBytes = ($clipResult.Verified | Measure-Object -Property Bytes -Sum).Sum
    if ($null -eq $clipBytes) {
        $clipBytes = 0
    }

    $stageFull = Join-Path $targetRoot ('.viewer-package-stage-' + [guid]::NewGuid().ToString('n'))
    $stageFull = Assert-ToolOutputPath -Path $stageFull
    try {
        $expectedCopy = @(Get-PackageCopyManifest -PayloadManifest $bundleManifest -SourceRoot $bundleSource -CliExecutable $CliExecutable)
        Write-PackageMessage -Message "package: copying '$bundleSource' and '$CliExecutable' to staging '$stageFull'"
        Copy-PackageBundle -SourceRoot $bundleSource -CliExecutable $CliExecutable -DestinationRoot $stageFull -ExpectedManifest $expectedCopy
        $copiedManifest = @(Get-PackageBundleManifest -Root $stageFull -IncludeStamp)
        if (-not [string]::Equals(($expectedCopy -join "`n"), ($copiedManifest -join "`n"), [StringComparison]::Ordinal)) {
            throw "Refusing to replace '$outputFull': copied bundle manifest mismatch (modified, missing or extra file)."
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputFull) | Out-Null
        if (Test-Path -LiteralPath $outputFull -PathType Container) {
            # A running viewer locks its DLLs, so deleting the folder would fail
            # halfway and leave that viewer without its data folder.
            $outputPrefix = $outputFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
            $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
                    $null -ne $_.Path -and $_.Path.StartsWith($outputPrefix, [System.StringComparison]::OrdinalIgnoreCase)
                })
            if ($running.Count -gt 0) {
                $names = ($running | ForEach-Object { "$($_.ProcessName) (pid $($_.Id))" }) -join ', '
                throw "Cannot replace '$outputFull' while $names runs from it; close it and package again."
            }
            Write-PackageMessage -Message "package: replacing '$outputFull'"
            Remove-Item -LiteralPath $outputFull -Recurse -Force
        }

        Move-Item -LiteralPath $stageFull -Destination $outputFull
    }
    finally {
        if (Test-Path -LiteralPath $stageFull) {
            # Validate our exact owned staging root before recursive cleanup.
            $null = @(Get-BundleFile -Root $stageFull)
            Remove-Item -LiteralPath $stageFull -Recurse -Force
        }
    }

    $viewerExe = Join-Path -Path $outputFull -ChildPath 'tasks_viewer.exe'
    $packagedCli = Join-Path -Path $outputFull -ChildPath 'tasks.exe'
    $metadataPath = Join-Path -Path $outputFull -ChildPath 'bundle-metadata.json'
    $hashPath = Join-Path -Path $outputFull -ChildPath 'SHA256SUMS.txt'
    $metadata = [ordered]@{
        schema_version    = 1
        generated_utc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        source_commit     = $sourceIdentity.Commit
        source_dirty      = $sourceIdentity.Dirty
        viewer_source_fingerprint = $sourceFingerprint
        viewer_exe_sha256 = Get-FileSha256 -Path $viewerExe
        cli_exe_sha256    = Get-FileSha256 -Path $packagedCli
        clip_count        = $clipResult.Verified.Count
        clip_bytes        = $clipBytes
        catalog_sha256    = Get-FileSha256 -Path $catalogPath
        manifest_sha256   = Get-FileSha256 -Path (Join-Path -Path $announcementsDirectory -ChildPath 'manifest.json')
        launch_test       = 'pending'
    }

    Write-PackageMessage -Message 'package: scanning the bundle for credentials'
    foreach ($credentialFinding in Find-BundleCredential -Root $outputFull) {
        $findings.Add($credentialFinding)
    }

    $launchResult = $null
    if ($findings.Count -eq 0) {
        Write-PackageMessage -Message 'package: launch-testing the copy from a path with spaces and non-ASCII characters'
        try {
            $launchResult = Invoke-BundleLaunchTest -BundleRoot $outputFull -WorkingRoot $WorkingRoot -TimeoutSeconds $LaunchTimeoutSeconds
            foreach ($case in $launchResult.Cases) {
                $state = if ($case.Ok) { 'ok' } else { 'FAILED' }
                Write-PackageMessage -Message ("package: launch case {0}: {1} (exit {2})" -f $case.Name, $state, $case.ExitCode)
                if (-not $case.Ok) {
                    $findings.Add("Launch case '$($case.Name)' failed with exit code $($case.ExitCode).")
                }
            }
        }
        finally {
            if ($null -ne $launchResult -and -not $KeepLaunchRoot) {
                Remove-Item -LiteralPath $launchResult.LaunchRoot -Recurse -Force
            }
        }
    }

    if ($null -ne $launchResult -and $launchResult.Ok) {
        $metadata.launch_test = 'passed'
    }
    else {
        $metadata.launch_test = 'not-run-or-failed'
    }
    $metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $metadataPath -Encoding utf8NoBOM
    Write-BundleHashFile -Root $outputFull -HashPath $hashPath

    $bundleFiles = Get-BundleFile -Root $outputFull
    $result = [pscustomobject]@{
        Ok              = ($findings.Count -eq 0)
        Findings        = @($findings)
        OutputRoot      = $outputFull
        FileCount       = $bundleFiles.Count
        TotalBytes      = ($bundleFiles | Measure-Object -Property Length -Sum).Sum
        ClipCount       = $clipResult.Verified.Count
        ClipBytes       = $clipBytes
        ViewerExeSha256 = $metadata.viewer_exe_sha256
        CliExeSha256    = $metadata.cli_exe_sha256
        HashPath        = $hashPath
        MetadataPath    = $metadataPath
        SourceCommit    = $sourceIdentity.Commit
        SourceDirty     = $sourceIdentity.Dirty
        LaunchTest      = $launchResult
    }

    if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
        $result | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath (Join-Path -Path $EvidenceRoot -ChildPath 'package-summary.json') -Encoding utf8NoBOM
    }

    return $result
}

if ($MyInvocation.InvocationName -ne '.') {
    $toolExitCode = 1
    try {
        $toolResult = Invoke-PackageTool -ViewerRoot $ViewerRoot -RepositoryRoot $RepositoryRoot `
            -OutputRoot $OutputRoot -CliTargetDirectory $CliTargetDirectory `
            -PackageParentRoot $PackageParentRoot -PackageSourceRoot $PackageSourceRoot `
            -CliExecutable $CliExecutable -FfprobePath $FfprobePath `
            -AnnouncementToolPath $AnnouncementToolPath -EvidenceRoot $EvidenceRoot `
            -WorkingRoot $WorkingRoot -LaunchTimeoutSeconds $LaunchTimeoutSeconds -KeepLaunchRoot:$KeepLaunchRoot
        foreach ($finding in $toolResult.Findings) {
            Write-PackageMessage -Message "package: $finding"
        }
        if ($toolResult.Ok) {
            Write-PackageMessage -Message ("package: OK - {0} files, {1} bytes, {2} clips, {3} bytes of clips" -f `
                    $toolResult.FileCount, $toolResult.TotalBytes, $toolResult.ClipCount, $toolResult.ClipBytes)
            Write-PackageMessage -Message "package: bundle '$($toolResult.OutputRoot)'"
            Write-PackageMessage -Message "package: hashes '$($toolResult.HashPath)'"
            $toolExitCode = 0
        }
        else {
            Write-PackageMessage -Message "package: FAILED - $($toolResult.Findings.Count) problem(s)"
        }
    }
    catch {
        Write-PackageMessage -Message "error: $($_.Exception.Message)"
        $toolExitCode = 1
    }

    exit $toolExitCode
}
