#requires -Version 7.0
<#
.SYNOPSIS
Assembles the portable viewer release bundle with its matching CLI.

.DESCRIPTION
viewer/spec.md section 11 requires this script to put the full runner bundle and
the matching CLI in target/viewer-release/, write hashes and check a launch from
a path containing spaces and non-ASCII characters.

The script copies the Flutter Windows release bundle, adds the matching
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

    return $targetFull
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

    $files = Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        Where-Object { $_.FullName -ne $excludedFull } |
        Sort-Object -Property FullName
    return @($files)
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
        [string]$DestinationRoot
    )

    New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $SourceRoot -Force | Sort-Object -Property Name) {
        Copy-Item -LiteralPath $item.FullName -Destination $DestinationRoot -Recurse -Force
    }

    Copy-Item -LiteralPath $CliExecutable -Destination (Join-Path -Path $DestinationRoot -ChildPath 'tasks.exe') -Force
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
    foreach ($item in Get-ChildItem -LiteralPath $BundleRoot -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $copyRoot -Recurse -Force
    }

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
    $targetRoot = Join-Path -Path $repositoryFull -ChildPath 'target'
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $OutputRoot = Join-Path -Path $targetRoot -ChildPath 'viewer-release'
    }
    if ([string]::IsNullOrWhiteSpace($CliExecutable)) {
        $CliExecutable = Join-Path -Path $targetRoot -ChildPath 'release/tasks.exe'
    }
    if ([string]::IsNullOrWhiteSpace($WorkingRoot)) {
        $WorkingRoot = [System.IO.Path]::GetTempPath()
    }
    if ([string]::IsNullOrWhiteSpace($AnnouncementToolPath)) {
        $AnnouncementToolPath = Join-Path -Path $PSScriptRoot -ChildPath 'generate-announcements.ps1'
    }

    $outputFull = Resolve-PackageOutputRoot -Path $OutputRoot -AllowedRoot $targetRoot
    $bundleSource = Join-Path -Path $viewerFull -ChildPath 'build/windows/x64/runner/Release'
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

    Write-PackageMessage -Message "package: copying '$bundleSource' and '$CliExecutable'"
    Copy-PackageBundle -SourceRoot $bundleSource -CliExecutable $CliExecutable -DestinationRoot $outputFull

    $sourceIdentity = Get-SourceIdentity -RepositoryRoot $repositoryFull
    $viewerExe = Join-Path -Path $outputFull -ChildPath 'tasks_viewer.exe'
    $packagedCli = Join-Path -Path $outputFull -ChildPath 'tasks.exe'
    $metadataPath = Join-Path -Path $outputFull -ChildPath 'bundle-metadata.json'
    $hashPath = Join-Path -Path $outputFull -ChildPath 'SHA256SUMS.txt'
    $metadata = [ordered]@{
        schema_version    = 1
        generated_utc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        source_commit     = $sourceIdentity.Commit
        source_dirty      = $sourceIdentity.Dirty
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
            -OutputRoot $OutputRoot -CliExecutable $CliExecutable -FfprobePath $FfprobePath `
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
