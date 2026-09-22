#requires -Version 7.0
<#
.SYNOPSIS
Measures the viewer specification section 10 performance targets.

.DESCRIPTION
viewer/spec.md section 10 asks for `viewer/tool/measure.ps1`: deterministic
seeded fixtures, percentile timings over 30 runs after one warm-up, and
recorded raw samples. This script measures the release CLI round trips that
back the viewer's data layer, including CLI process startup, because the
viewer routes every list, detail and save through one `tasks.exe` process.

The fixtures come from `tasks-perf-fixture.exe`: 100 projects with 1000 tasks
each, one project with 100000 tasks (a 1 MiB body, 1000 dependency edges,
every status and priority, labels, Unicode and repeated sort values), and
1000 empty projects for the project-virtualization row. A tiny probe profile
is generated twice to prove that the recorded seed reproduces the same
logical content digest.

Rows that need a live windowed profile session or a screen reader stay
unavailable and are recorded as such, never as passed: profile-build frame
data over a 60-second scroll, release process working set, and the NVDA
enabled and disabled variants. The retained page and node bounds are proven
by the Flutter suite (see verify-windows.ps1 gate G05), not here.

Safety: every fixture lives in one unique temporary root outside the
repository. The script never opens the real default data root, never touches
the clipboard, never drives the desktop and never deletes anything except the
exact run-owned fixture root after checking its resolved path and generated
name. Cleanup happens only when the run created the root itself.

.EXAMPLE
pwsh -NoProfile -File viewer/tool/measure.ps1

.EXAMPLE
pwsh -NoProfile -File viewer/tool/measure.ps1 -EvidenceRoot viewer/target/evidence/viewer/2026-09-22-measure -KeepFixtureRoot
#>
[CmdletBinding()]
param(
    [string]$ViewerRoot = (Split-Path -Parent $PSScriptRoot),

    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),

    [string]$EvidenceRoot,

    [string]$CliExecutable,

    [string]$FixtureBinary,

    [string]$FixtureRoot,

    [string]$WorkingRoot = [System.IO.Path]::GetTempPath(),

    [ValidateRange(1, 1000)]
    [int]$Iterations = 30,

    [ValidateRange(0, 100)]
    [int]$Warmup = 1,

    [ValidateRange(10, 3600)]
    [int]$TimeoutSeconds = 300,

    [int]$Seed = 20260922,

    [switch]$SkipBuild,

    [switch]$KeepFixtureRoot
)

$ErrorActionPreference = 'Stop'

function Write-MeasureMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Information -MessageData ("measure: {0}" -f $Message) -InformationAction Continue
}

function Get-FileSha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-Utf8ByteCount {
    <#
    .SYNOPSIS
    Counts the UTF-8 bytes of a decoded string.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    return [System.Text.Encoding]::UTF8.GetByteCount($Text)
}

function Assert-PathInside {
    <#
    .SYNOPSIS
    Fails unless the resolved target stays inside the resolved parent.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Parent,

        [Parameter(Mandatory)]
        [string]$Purpose
    )

    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    $targetFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $requiredPrefix = $parentFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $targetFull.StartsWith($requiredPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use '$targetFull' for ${Purpose}: it must stay inside '$parentFull'."
    }

    return $targetFull
}

function Resolve-MeasureEvidenceRoot {
    <#
    .SYNOPSIS
    Resolves the run evidence directory inside the viewer target tree.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ViewerRoot,

        [string]$EvidenceRoot,

        [datetime]$Now = (Get-Date)
    )

    $evidenceParent = Join-Path -Path $ViewerRoot -ChildPath 'target/evidence/viewer'
    if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        $EvidenceRoot = Join-Path -Path $evidenceParent -ChildPath `
            ("{0}-measure" -f $Now.ToString('yyyy-MM-dd-HHmmss'))
    }

    return Assert-PathInside -Path $EvidenceRoot -Parent $evidenceParent -Purpose 'measurement evidence'
}

function Resolve-MeasureFixtureRoot {
    <#
    .SYNOPSIS
    Resolves the throwaway fixture root, which never lives in the repository.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$WorkingRoot,

        [string]$FixtureRoot,

        [string]$RepositoryRoot
    )

    if ([string]::IsNullOrWhiteSpace($FixtureRoot)) {
        $FixtureRoot = Join-Path -Path $WorkingRoot -ChildPath `
            ("tasks-viewer-perf-{0}" -f [guid]::NewGuid().ToString('n').Substring(0, 8))
    }
    $rootFull = Assert-PathInside -Path $FixtureRoot -Parent $WorkingRoot -Purpose 'performance fixture root'
    $leaf = Split-Path -Leaf $rootFull
    if (-not $leaf.StartsWith('tasks-viewer-perf-', [System.StringComparison]::Ordinal)) {
        throw "Refusing to use '$rootFull' as the fixture root: the name must start with 'tasks-viewer-perf-'."
    }
    $repositoryFull = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
    if ($rootFull.Equals($repositoryFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $rootFull.StartsWith($repositoryFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use '$rootFull' as the fixture root: fixtures never live inside the repository."
    }

    return $rootFull
}

function Initialize-MeasureFixtureRoot {
    <#
    .SYNOPSIS
    Creates the run-owned fixture root only when it does not exist yet.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FixtureRoot
    )

    if (Test-Path -LiteralPath $FixtureRoot) {
        $existing = @(Get-ChildItem -LiteralPath $FixtureRoot -Force)
        if ($existing.Count -gt 0) {
            throw "Refusing to reuse '$FixtureRoot': it already holds content, so the run cannot own it."
        }
        return $false
    }
    New-Item -ItemType Directory -Force -Path $FixtureRoot | Out-Null
    return $true
}

function Clear-MeasureFixture {
    <#
    .SYNOPSIS
    Removes the exact run-owned fixture root after re-checking its bounds.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FixtureRoot,

        [Parameter(Mandatory)]
        [string]$WorkingRoot,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $rootFull = Assert-PathInside -Path $FixtureRoot -Parent $WorkingRoot -Purpose 'fixture cleanup'
    $leaf = Split-Path -Leaf $rootFull
    if (-not $leaf.StartsWith('tasks-viewer-perf-', [System.StringComparison]::Ordinal)) {
        throw "Refusing to remove '$rootFull': the name must start with 'tasks-viewer-perf-'."
    }
    $repositoryFull = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
    if ($rootFull.StartsWith($repositoryFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove '$rootFull': it sits inside the repository."
    }
    [System.IO.Directory]::Delete($rootFull, $true)
}

function Invoke-CapturedProcess {
    <#
    .SYNOPSIS
    Runs one process with captured output, a hard timeout and a wall-clock time.
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

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdOutTask = $process.StandardOutput.ReadToEndAsync()
        $stdErrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(10000)
            $stopwatch.Stop()
            return [pscustomobject]@{
                TimedOut     = $true
                ExitCode     = -1
                StdOut       = ''
                StdErr       = "The process did not exit within $TimeoutSeconds s and was killed."
                Milliseconds = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 1)
            }
        }

        $process.WaitForExit()
        $stopwatch.Stop()
        return [pscustomobject]@{
            TimedOut     = $false
            ExitCode     = $process.ExitCode
            StdOut       = $stdOutTask.Result
            StdErr       = $stdErrTask.Result
            Milliseconds = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 1)
        }
    }
    finally {
        $process.Dispose()
    }
}

function Measure-CliJson {
    <#
    .SYNOPSIS
    Times one release CLI call and parses its JSON envelope.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$CliExecutable,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $result = Invoke-CapturedProcess -FilePath $CliExecutable -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
    $payload = $null
    $problem = ''
    if ($result.TimedOut) {
        $problem = "the CLI did not exit within $TimeoutSeconds s"
    }
    elseif ($result.ExitCode -ne 0) {
        $firstLine = ($result.StdErr -split "`n" | Select-Object -First 1)
        $problem = "exit $($result.ExitCode): $firstLine"
    }
    elseif ($result.StdOut.Trim().Length -eq 0) {
        $problem = 'the CLI printed no JSON'
    }
    else {
        try {
            $payload = $result.StdOut | ConvertFrom-Json
        }
        catch {
            $problem = 'the CLI output was not parseable JSON'
        }
    }

    return [pscustomobject]@{
        Milliseconds = $result.Milliseconds
        Payload      = $payload
        Problem      = $problem
        StdErr       = $result.StdErr
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$Value
    )

    Set-Content -LiteralPath $Path -Value ($Value | ConvertTo-Json -Depth 8 -Compress) -Encoding utf8NoBOM
}

function Get-Percentile {
    <#
    .SYNOPSIS
    Nearest-rank percentile over the samples (rank = ceil(p * n)).
    #>
    param(
        [Parameter(Mandatory)]
        [double[]]$Samples,

        [Parameter(Mandatory)]
        [double]$Percentile
    )

    if ($Samples.Count -eq 0) {
        throw 'Get-Percentile needs at least one sample.'
    }
    if ($Percentile -le 0 -or $Percentile -gt 1) {
        throw 'The percentile must sit in (0, 1].'
    }
    $sorted = @($Samples | Sort-Object)
    $rank = [math]::Ceiling($Percentile * $sorted.Count)
    if ($rank -lt 1) {
        $rank = 1
    }
    return [double]$sorted[$rank - 1]
}

function Get-MeasureStatistic {
    <#
    .SYNOPSIS
    Summarises the raw sample list without hiding any sample.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [double[]]$Samples
    )

    if ($Samples.Count -eq 0) {
        return [pscustomobject]@{
            Count = 0; Min = $null; P50 = $null; P95 = $null; Max = $null; Mean = $null
            Samples = @()
        }
    }
    $sorted = @($Samples | Sort-Object)
    return [pscustomobject]@{
        Count   = $sorted.Count
        Min     = [math]::Round($sorted[0], 1)
        P50     = [math]::Round((Get-Percentile -Samples $sorted -Percentile 0.5), 1)
        P95     = [math]::Round((Get-Percentile -Samples $sorted -Percentile 0.95), 1)
        Max     = [math]::Round($sorted[$sorted.Count - 1], 1)
        Mean    = [math]::Round((($sorted | Measure-Object -Average).Average), 1)
        Samples = $sorted
    }
}

function Get-MeasureStatus {
    <#
    .SYNOPSIS
    Classifies one measured row against its acceptance target.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$P95,

        [Parameter(Mandatory)]
        [int]$TargetMs,

        [Parameter(Mandatory)]
        [int]$Count,

        [Parameter(Mandatory)]
        [int]$ExpectedCount
    )

    if ($Count -lt $ExpectedCount) {
        return 'incomplete'
    }
    if ($null -eq $P95) {
        return 'incomplete'
    }
    if ([double]$P95 -le [double]$TargetMs) {
        return 'passed'
    }
    return 'failed'
}

function Invoke-SampleLoop {
    <#
    .SYNOPSIS
    Runs one measurement: discarded warm-ups, then timed validated samples.
    #>
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Sample,

        [Parameter(Mandatory)]
        [int]$Iterations,

        [Parameter(Mandatory)]
        [int]$Warmup
    )

    for ($index = 0; $index -lt $Warmup; $index++) {
        $warm = & $Sample
        if (-not $warm.Ok) {
            throw ("A warm-up run failed its validation: {0}" -f $warm.Detail)
        }
    }
    $samples = [System.Collections.Generic.List[double]]::new()
    $details = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $Iterations; $index++) {
        $run = & $Sample
        if (-not $run.Ok) {
            throw ("Iteration {0} failed its validation: {1}" -f ($index + 1), $run.Detail)
        }
        $samples.Add([double]$run.Milliseconds)
        $details.Add(("run {0}: {1} ms - {2}" -f ($index + 1), $run.Milliseconds, $run.Detail))
    }

    return [pscustomobject]@{
        Samples = $samples.ToArray()
        Details = $details.ToArray()
    }
}

function Get-HostReport {
    <#
    .SYNOPSIS
    Records the machine, toolchain and storage facts section 10 asks for.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FixtureRoot,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $report = [ordered]@{}
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        $report['cpu'] = ("{0} ({1} cores, {2} logical)" -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
    }
    catch {
        $report['cpu'] = $null
    }
    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem
        $report['ram_gib'] = [math]::Round($system.TotalPhysicalMemory / 1GB, 1)
    }
    catch {
        $report['ram_gib'] = $null
    }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $report['os'] = ("{0} build {1}" -f $os.Caption.Trim(), $os.BuildNumber)
    }
    catch {
        $report['os'] = [System.Environment]::OSVersion.VersionString
    }
    try {
        $report['power_scheme'] = ((powercfg /getactivescheme) -join ' ').Trim()
    }
    catch {
        $report['power_scheme'] = $null
    }
    try {
        $drive = (Get-Item -LiteralPath $FixtureRoot).PSDrive.Name
        $volume = Get-Volume -DriveLetter $drive | Select-Object -First 1
        $report['fixture_volume'] = ("{0} size {1} GiB free {2} GiB" -f $drive, [math]::Round($volume.Size / 1GB, 1), [math]::Round($volume.SizeRemaining / 1GB, 1))
    }
    catch {
        $report['fixture_volume'] = $null
    }
    $report['cargo'] = (cargo --version)
    $report['rustc'] = (rustc --version)
    $report['powershell'] = ($PSVersionTable.PSVersion.ToString())
    try {
        $report['source_commit'] = (git -C $RepositoryRoot rev-parse HEAD).Trim()
        $dirty = @(git -C $RepositoryRoot status --porcelain=v1)
        $report['source_dirty'] = ($dirty.Count -gt 0)
    }
    catch {
        $report['source_commit'] = $null
        $report['source_dirty'] = $null
    }
    $report['repository_root'] = $RepositoryRoot
    $report['generated_utc'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    return [pscustomobject]$report
}

function Invoke-PerfFixtureProfile {
    <#
    .SYNOPSIS
    Seeds one deterministic fixture profile and returns its recorded digest.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FixtureBinary,

        [Parameter(Mandatory)]
        [string]$FixtureRoot,

        [Parameter(Mandatory)]
        [string]$DataLeaf,

        [Parameter(Mandatory)]
        [string]$RootsLeaf,

        [Parameter(Mandatory)]
        [string]$FixtureProfile,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [int]$Seed,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory)]
        [System.Collections.Generic.List[string]]$Log
    )

    $dataRoot = Join-Path -Path $FixtureRoot -ChildPath $DataLeaf
    $rootsRoot = Join-Path -Path $FixtureRoot -ChildPath $RootsLeaf
    New-Item -ItemType Directory -Force -Path $dataRoot, $rootsRoot | Out-Null
    $result = Invoke-CapturedProcess -FilePath $FixtureBinary `
        -Arguments @('--data-root', $dataRoot, '--roots-root', $rootsRoot, '--profile', $FixtureProfile, '--seed', "$Seed") `
        -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
    foreach ($line in @($result.StdErr -split "`n")) {
        if ($line.Trim().Length -gt 0) {
            $Log.Add(("[{0}] {1}" -f $DataLeaf, $line.TrimEnd()))
        }
    }
    if ($result.TimedOut -or $result.ExitCode -ne 0) {
        $firstLine = ($result.StdErr -split "`n" | Select-Object -First 1)
        throw "fixture generation for $DataLeaf failed: exit $($result.ExitCode) $firstLine"
    }
    $jsonLine = ($result.StdOut -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($jsonLine)) {
        throw "fixture generation for $DataLeaf printed no JSON summary"
    }
    $payload = $jsonLine | ConvertFrom-Json
    $Log.Add(("[{0}] profile {1} seed {2} projects {3} tasks {4} dependencies {5} digest {6} in {7} ms" -f `
                $DataLeaf, $payload.profile, $payload.seed, $payload.projects, $payload.tasks, $payload.dependencies, $payload.digest, $result.Milliseconds))

    return [pscustomobject]@{
        DataLeaf     = $DataLeaf
        Profile      = [string]$payload.profile
        Seed         = [int]$payload.seed
        Projects     = [int]$payload.projects
        Tasks        = [int]$payload.tasks
        Dependencies = [int]$payload.dependencies
        Digest       = [string]$payload.digest
        Milliseconds = $result.Milliseconds
    }
}

function Initialize-MeasureFixture {
    <#
    .SYNOPSIS
    Copies the fixture binary into the run root and seeds every profile.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FixtureBinary,

        [Parameter(Mandatory)]
        [string]$FixtureRoot,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [int]$Seed,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $supportRoot = Join-Path -Path $FixtureRoot -ChildPath 'support'
    New-Item -ItemType Directory -Force -Path $supportRoot | Out-Null
    $fixtureCopy = Join-Path -Path $supportRoot -ChildPath 'tasks-perf-fixture.exe'
    Copy-Item -LiteralPath $FixtureBinary -Destination $fixtureCopy -Force
    $fixtureSha = Get-FileSha256 -Path $fixtureCopy

    $log = [System.Collections.Generic.List[string]]::new()
    $log.Add(("fixture binary: {0} sha256 {1}" -f $fixtureCopy, $fixtureSha))
    $runs = [System.Collections.Generic.List[object]]::new()
    $plan = @(
        [pscustomobject]@{ Data = 'probe-a'; Roots = 'probe-roots-a'; Profile = 'perf-probe' },
        [pscustomobject]@{ Data = 'probe-b'; Roots = 'probe-roots-b'; Profile = 'perf-probe' },
        [pscustomobject]@{ Data = 'data-100x1000'; Roots = 'roots-100x1000'; Profile = 'perf-100x1000' },
        [pscustomobject]@{ Data = 'data-100k'; Roots = 'roots-100k'; Profile = 'perf-100k' },
        [pscustomobject]@{ Data = 'data-empty-1000'; Roots = 'roots-empty-1000'; Profile = 'perf-empty-1000' }
    )
    foreach ($entry in $plan) {
        Write-MeasureMessage -Message ("seeding {0} into {1}" -f $entry.Profile, $entry.Data)
        $runs.Add((Invoke-PerfFixtureProfile -FixtureBinary $fixtureCopy -FixtureRoot $FixtureRoot `
                    -DataLeaf $entry.Data -RootsLeaf $entry.Roots -FixtureProfile $entry.Profile `
                    -WorkingDirectory $WorkingDirectory -Seed $Seed -TimeoutSeconds $TimeoutSeconds -Log $log))
    }

    $probeA = $runs | Where-Object { $_.DataLeaf -eq 'probe-a' }
    $probeB = $runs | Where-Object { $_.DataLeaf -eq 'probe-b' }
    if ($probeA.Digest -ne $probeB.Digest) {
        throw ("the seed does not reproduce the same logical content: probe-a {0} != probe-b {1}" -f $probeA.Digest, $probeB.Digest)
    }
    $log.Add(("determinism probe: probe-a digest equals probe-b digest ({0})" -f $probeA.Digest))

    return [pscustomobject]@{
        Runs             = $runs
        Log              = $log.ToArray()
        FixtureBinarySha = $fixtureSha
    }
}

function Write-MeasureEvidence {
    <#
    .SYNOPSIS
    Writes the machine-readable and human-readable measurement evidence.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EvidenceRoot,

        [Parameter(Mandatory)]
        [object]$HostReport,

        [Parameter(Mandatory)]
        [object]$FixtureReport,

        [Parameter(Mandatory)]
        [object]$CliIdentity,

        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]]$Rows,

        [Parameter(Mandatory)]
        [object[]]$Unavailable,

        [Parameter(Mandatory)]
        [string]$FixtureRoot,

        [Parameter(Mandatory)]
        [int]$Iterations,

        [Parameter(Mandatory)]
        [int]$Warmup
    )

    $rowJson = @(foreach ($row in $Rows) {
            [ordered]@{
                id        = $row.Id
                name      = $row.Name
                target_ms = $row.TargetMs
                status    = $row.Status
                p50_ms    = $row.Stats.P50
                p95_ms    = $row.Stats.P95
                min_ms    = $row.Stats.Min
                max_ms    = $row.Stats.Max
                mean_ms   = $row.Stats.Mean
                count     = $row.Stats.Count
                samples   = @($row.Stats.Samples)
                details   = @($row.Details)
            }
        })
    $summary = [ordered]@{
        generated_utc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        iterations       = $Iterations
        warmup           = $Warmup
        fixture_root     = $FixtureRoot
        cli              = $CliIdentity
        fixtures         = $FixtureReport
        host             = $HostReport
        rows             = $rowJson
        unavailable_rows = $Unavailable
    }
    Set-Content -LiteralPath (Join-Path -Path $EvidenceRoot -ChildPath 'measure-summary.json') `
        -Value ($summary | ConvertTo-Json -Depth 12) -Encoding utf8NoBOM

    $markdown = [System.Collections.Generic.List[string]]::new()
    $markdown.Add('# viewer performance measurements - measure.ps1')
    $markdown.Add('')
    $markdown.Add(("generated_utc: {0}" -f $summary.generated_utc))
    $markdown.Add(("fixture_root: {0}" -f $FixtureRoot))
    $markdown.Add(("iterations: {0} timed runs after {1} discarded warm-up run(s)" -f $Iterations, $Warmup))
    $markdown.Add(("cli: {0} sha256 {1}" -f $CliIdentity.shipped_path, $CliIdentity.shipped_sha256))
    $markdown.Add(("fixture binary sha256: {0}" -f $FixtureReport.FixtureBinarySha))
    $markdown.Add(("determinism probe: probe-a digest {0}" -f (($FixtureReport.Runs | Where-Object { $_.DataLeaf -eq 'probe-a' }).Digest)))
    $markdown.Add('')
    $markdown.Add('## Fixtures')
    $markdown.Add('')
    $markdown.Add('| Data root | Profile | Seed | Projects | Tasks | Dependencies | Digest |')
    $markdown.Add('| --- | --- | --- | --- | --- | --- | --- |')
    foreach ($run in $FixtureReport.Runs) {
        $markdown.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f $run.DataLeaf, $run.Profile, $run.Seed, $run.Projects, $run.Tasks, $run.Dependencies, $run.Digest))
    }
    $markdown.Add('')
    $markdown.Add('## Measured rows')
    $markdown.Add('')
    $markdown.Add('| Id | Row | Target p95 | p50 | p95 | max | status |')
    $markdown.Add('| --- | --- | --- | --- | --- | --- | --- |')
    foreach ($row in $Rows) {
        $markdown.Add(("| {0} | {1} | {2} ms | {3} ms | {4} ms | {5} ms | {6} |" -f `
                    $row.Id, $row.Name, $row.TargetMs, $row.Stats.P50, $row.Stats.P95, $row.Stats.Max, $row.Status))
    }
    $markdown.Add('')
    $unresolved = @($Rows | Where-Object { $_.Status -ne 'passed' })
    if ($unresolved.Count -gt 0) {
        $markdown.Add('### Rows that did not pass')
        $markdown.Add('')
        foreach ($row in $unresolved) {
            $markdown.Add(("- {0} {1} (status {2})" -f $row.Id, $row.Name, $row.Status))
            foreach ($entry in $row.Details) {
                $markdown.Add(("  - {0}" -f $entry))
            }
        }
        $markdown.Add('')
    }
    $markdown.Add('## Unavailable rows')
    $markdown.Add('')
    foreach ($row in $Unavailable) {
        $markdown.Add(("- {0} {1}: {2}" -f $row.Id, $row.Name, $row.Reason))
    }
    $markdown.Add('')
    $markdown.Add('## Host and toolchain')
    $markdown.Add('')
    foreach ($property in $HostReport.PSObject.Properties) {
        $markdown.Add(("- {0}: {1}" -f $property.Name, $property.Value))
    }
    Set-Content -LiteralPath (Join-Path -Path $EvidenceRoot -ChildPath 'measure-summary.md') `
        -Value ($markdown -join "`n") -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path -Path $EvidenceRoot -ChildPath '02-fixtures.txt') `
        -Value (($FixtureReport.Log) -join "`n") -Encoding utf8NoBOM
    $rawRows = @(foreach ($row in $Rows) {
            [ordered]@{
                id      = $row.Id
                name    = $row.Name
                target  = $row.TargetMs
                status  = $row.Status
                samples = @($row.Stats.Samples)
                runs    = @($row.Details)
            }
        })
    Set-Content -LiteralPath (Join-Path -Path $EvidenceRoot -ChildPath '03-measurements.json') `
        -Value ($rawRows | ConvertTo-Json -Depth 8) -Encoding utf8NoBOM

    return (Join-Path -Path $EvidenceRoot -ChildPath 'measure-summary.md')
}

function Invoke-Measure {
    <#
    .SYNOPSIS
    Runs every headless measurement row and writes one evidence root.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ViewerRoot,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [string]$EvidenceRoot,

        [string]$CliExecutable,

        [string]$FixtureBinary,

        [string]$FixtureRoot,

        [Parameter(Mandatory)]
        [string]$WorkingRoot,

        [Parameter(Mandatory)]
        [int]$Iterations,

        [Parameter(Mandatory)]
        [int]$Warmup,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory)]
        [int]$Seed,

        [switch]$SkipBuild,

        [switch]$KeepFixtureRoot
    )

    $repositoryFull = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $evidence = Resolve-MeasureEvidenceRoot -ViewerRoot $ViewerRoot -EvidenceRoot $EvidenceRoot
    New-Item -ItemType Directory -Force -Path $evidence | Out-Null
    $fixtureResolved = Resolve-MeasureFixtureRoot -WorkingRoot $WorkingRoot -FixtureRoot $FixtureRoot -RepositoryRoot $repositoryFull
    $fixtureOwned = Initialize-MeasureFixtureRoot -FixtureRoot $fixtureResolved
    $rows = [System.Collections.Generic.List[object]]::new()
    $unavailable = @(
        [pscustomobject]@{ Id = 'M09'; Name = '60-second scroll frame time (profile build)'; Reason = 'needs a live windowed profile session; the headless test binding has no rasterizer, and this run never drives a window on an in-use desktop' },
        [pscustomobject]@{ Id = 'M10'; Name = 'release process peak working set'; Reason = 'needs the launched viewer process on a live desktop; the packaged launch test exercises only the no-window startup opt-out' },
        [pscustomobject]@{ Id = 'M11'; Name = 'frame and memory rows with NVDA enabled and disabled'; Reason = 'needs a live NVDA session; the automated semantics suites run headless in verify-windows.ps1 gate G05' }
    )
    $outcome = 1
    try {
        if (-not $SkipBuild) {
            $cargoPath = (Get-Command -Name cargo -ErrorAction Stop).Source
            $buildLog = [System.Collections.Generic.List[string]]::new()
            $buildPlan = @(
                [pscustomobject]@{ Args = @('build', '--release', '--locked', '--features', 'test-hooks'); Purpose = 'build the test-hooks fixture binary' },
                [pscustomobject]@{ Args = @('build', '--release', '--locked'); Purpose = 'restore the shipped CLI without test hooks' }
            )
            foreach ($target in $buildPlan) {
                Write-MeasureMessage -Message ("cargo {0} ({1})" -f ($target.Args -join ' '), $target.Purpose)
                $result = Invoke-CapturedProcess -FilePath $cargoPath -Arguments $target.Args `
                    -WorkingDirectory $repositoryFull -TimeoutSeconds 1800
                $buildLog.Add(("$ cargo {0}" -f ($target.Args -join ' ')))
                $buildLog.Add(("exit {0} in {1} ms" -f $result.ExitCode, $result.Milliseconds))
                foreach ($stream in @($result.StdOut, $result.StdErr)) {
                    foreach ($line in @($stream -split "`n")) {
                        if ($line.Trim().Length -gt 0) {
                            $buildLog.Add($line.TrimEnd())
                        }
                    }
                }
                if ($result.TimedOut -or $result.ExitCode -ne 0) {
                    Set-Content -LiteralPath (Join-Path -Path $evidence -ChildPath '01-build.txt') `
                        -Value ($buildLog -join "`n") -Encoding utf8NoBOM
                    throw ("cargo {0} failed with exit {1}" -f ($target.Args -join ' '), $result.ExitCode)
                }
            }
            Set-Content -LiteralPath (Join-Path -Path $evidence -ChildPath '01-build.txt') `
                -Value ($buildLog -join "`n") -Encoding utf8NoBOM
        }

        $shippedCli = if ([string]::IsNullOrWhiteSpace($CliExecutable)) {
            Join-Path -Path $repositoryFull -ChildPath 'target/release/tasks.exe'
        }
        else {
            [System.IO.Path]::GetFullPath($CliExecutable)
        }
        $fixtureTool = if ([string]::IsNullOrWhiteSpace($FixtureBinary)) {
            Join-Path -Path $repositoryFull -ChildPath 'target/release/tasks-perf-fixture.exe'
        }
        else {
            [System.IO.Path]::GetFullPath($FixtureBinary)
        }
        foreach ($tool in @($shippedCli, $fixtureTool)) {
            if (-not (Test-Path -LiteralPath $tool)) {
                throw "Required tool '$tool' is missing; run without -SkipBuild or build it first."
            }
        }
        $cliIdentity = [pscustomobject]@{
            shipped_path   = $shippedCli
            shipped_sha256 = (Get-FileSha256 -Path $shippedCli)
        }

        $hostReport = Get-HostReport -FixtureRoot $fixtureResolved -RepositoryRoot $repositoryFull
        $hostLines = [System.Collections.Generic.List[string]]::new()
        foreach ($property in $hostReport.PSObject.Properties) {
            $hostLines.Add(("{0}: {1}" -f $property.Name, $property.Value))
        }
        Set-Content -LiteralPath (Join-Path -Path $evidence -ChildPath '00-host.txt') `
            -Value ($hostLines -join "`n") -Encoding utf8NoBOM

        $fixtureReport = Initialize-MeasureFixture -FixtureBinary $fixtureTool -FixtureRoot $fixtureResolved `
            -WorkingDirectory $repositoryFull -Seed $Seed -TimeoutSeconds $TimeoutSeconds

        $data100 = Join-Path -Path $fixtureResolved -ChildPath 'data-100x1000'
        $data100k = Join-Path -Path $fixtureResolved -ChildPath 'data-100k'
        $dataEmpty = Join-Path -Path $fixtureResolved -ChildPath 'data-empty-1000'
        $requestRoot = Join-Path -Path $fixtureResolved -ChildPath 'requests'
        New-Item -ItemType Directory -Force -Path $requestRoot | Out-Null

        $projectsColdRequest = Join-Path -Path $requestRoot -ChildPath 'projects-cold.json'
        Write-JsonFile -Path $projectsColdRequest -Value ([ordered]@{ offset = 0; limit = 20 })
        $projectsAllRequest = Join-Path -Path $requestRoot -ChildPath 'projects-all.json'
        Write-JsonFile -Path $projectsAllRequest -Value ([ordered]@{ offset = 0; limit = 200 })
        $tasksPageRequest = Join-Path -Path $requestRoot -ChildPath 'tasks-page.json'
        Write-JsonFile -Path $tasksPageRequest -Value ([ordered]@{ offset = 0; limit = 50; scope = 'open' })
        $searchRequest = Join-Path -Path $requestRoot -ChildPath 'search-literal.json'
        Write-JsonFile -Path $searchRequest -Value ([ordered]@{ query = 'needle-%_'; scope = 'all'; limit = 50 })
        $emptyProjectsRequest = Join-Path -Path $requestRoot -ChildPath 'projects-empty.json'
        Write-JsonFile -Path $emptyProjectsRequest -Value ([ordered]@{ offset = 0; limit = 20 })

        Write-MeasureMessage -Message 'measuring M08 cold start (the first call against the 100-project fixture)'
        $cold = Measure-CliJson -CliExecutable $shippedCli `
            -Arguments @('--data-root', $data100, '--format', 'json', 'viewer', 'projects', '--request-file', $projectsColdRequest) `
            -WorkingDirectory $repositoryFull -TimeoutSeconds $TimeoutSeconds
        if ($cold.Problem) {
            throw "The cold-start call failed: $($cold.Problem)"
        }
        if ($cold.Payload.data.total_count -ne 100) {
            throw "The 100-project fixture reported $($cold.Payload.data.total_count) projects."
        }
        $coldStats = Get-MeasureStatistic -Samples @([double]$cold.Milliseconds)
        $rows.Add([pscustomobject]@{
                Id       = 'M08'
                Name     = 'cold start: first usable project list (100 projects)'
                TargetMs = 6000
                Status   = (Get-MeasureStatus -P95 $coldStats.P95 -TargetMs 6000 -Count 1 -ExpectedCount 1)
                Stats    = $coldStats
                Details  = @(("the first invocation after fixture creation reported total {0}" -f $cold.Payload.data.total_count))
            })

        $allProjects = Measure-CliJson -CliExecutable $shippedCli `
            -Arguments @('--data-root', $data100, '--format', 'json', 'viewer', 'projects', '--request-file', $projectsAllRequest) `
            -WorkingDirectory $repositoryFull -TimeoutSeconds $TimeoutSeconds
        if ($allProjects.Problem) {
            throw "The project discovery call failed: $($allProjects.Problem)"
        }
        $projectsByName = @{}
        foreach ($item in $allProjects.Payload.data.items) {
            $projectsByName[$item.name] = $item
        }
        $project099 = $projectsByName['perf-project-099']
        if ($null -eq $project099) {
            throw 'The 100-project fixture is missing perf-project-099.'
        }
        $huge = Measure-CliJson -CliExecutable $shippedCli `
            -Arguments @('--data-root', $data100k, '--format', 'json', 'viewer', 'projects', '--request-file', $projectsColdRequest) `
            -WorkingDirectory $repositoryFull -TimeoutSeconds $TimeoutSeconds
        if ($huge.Problem) {
            throw "The 100000-task project discovery failed: $($huge.Problem)"
        }
        $hugeProject = @($huge.Payload.data.items | Where-Object { $_.name -eq 'perf-huge' })[0]
        if ($null -eq $hugeProject) {
            throw 'The 100000-task fixture is missing perf-huge.'
        }

        $savePlan = $Iterations + $Warmup + 2
        $saveRequests = [System.Collections.Generic.List[string]]::new()
        for ($index = 1; $index -le $savePlan; $index++) {
            $path = Join-Path -Path $requestRoot -ChildPath ("save-{0:000}.json" -f $index)
            Write-JsonFile -Path $path -Value ([ordered]@{
                    id             = $index
                    expect_version = 1
                    changes        = [ordered]@{ title = ("acknowledged {0}" -f $index) }
                })
            $saveRequests.Add($path)
        }
        $saveCounter = [int[]]@(0)
        $saveSample = {
            $saveCounter[0] += 1
            $requestFile = $saveRequests[$saveCounter[0] - 1]
            $run = Measure-CliJson -CliExecutable $shippedCli `
                -Arguments @('--data-root', $data100, '--project', $project099.project_id, '--format', 'json', 'viewer', 'update', '--request-file', $requestFile) `
                -WorkingDirectory $repositoryFull -TimeoutSeconds $TimeoutSeconds
            $ok = $false
            $detail = $run.Problem
            if (-not $run.Problem) {
                if ($run.Payload.data.version -eq 2) {
                    $ok = $true
                    $detail = ("T-{0} acknowledged at version {1}" -f $run.Payload.data.id, $run.Payload.data.version)
                }
                else {
                    $detail = ("unexpected acknowledgement version {0}" -f $run.Payload.data.version)
                }
            }
            [pscustomobject]@{ Ok = $ok; Detail = $detail; Milliseconds = $run.Milliseconds }
        }
        $tasksPageSample = {
            $run = Measure-CliJson -CliExecutable $shippedCli `
                -Arguments @('--data-root', $data100k, '--project', $hugeProject.project_id, '--format', 'json', 'viewer', 'tasks', '--request-file', $tasksPageRequest) `
                -WorkingDirectory $repositoryFull -TimeoutSeconds $TimeoutSeconds
            $ok = $false
            $detail = $run.Problem
            if (-not $run.Problem) {
                if ($run.Payload.data.total_count -gt 0 -and $run.Payload.data.items.Count -gt 0) {
                    $ok = $true
                    $detail = ("total {0}, items {1}" -f $run.Payload.data.total_count, $run.Payload.data.items.Count)
                }
                else {
                    $detail = 'the task page returned no rows'
                }
            }
            [pscustomobject]@{ Ok = $ok; Detail = $detail; Milliseconds = $run.Milliseconds }
        }
        $detailSample = {
            $run = Measure-CliJson -CliExecutable $shippedCli `
                -Arguments @('--data-root', $data100k, '--project', $hugeProject.project_id, '--format', 'json', 'viewer', 'show', 'T-2') `
                -WorkingDirectory $repositoryFull -TimeoutSeconds $TimeoutSeconds
            $ok = $false
            $detail = $run.Problem
            if (-not $run.Problem) {
                $bodyBytes = Get-Utf8ByteCount -Text $run.Payload.data.body
                if ($bodyBytes -ge 2048) {
                    $ok = $true
                    $detail = ("body {0} bytes" -f $bodyBytes)
                }
                else {
                    $detail = ("the ordinary body was only {0} bytes" -f $bodyBytes)
                }
            }
            [pscustomobject]@{ Ok = $ok; Detail = $detail; Milliseconds = $run.Milliseconds }
        }
        $bigDetailSample = {
            $run = Measure-CliJson -CliExecutable $shippedCli `
                -Arguments @('--data-root', $data100k, '--project', $hugeProject.project_id, '--format', 'json', 'viewer', 'show', 'T-1') `
                -WorkingDirectory $repositoryFull -TimeoutSeconds $TimeoutSeconds
            $ok = $false
            $detail = $run.Problem
            if (-not $run.Problem) {
                $bodyBytes = Get-Utf8ByteCount -Text $run.Payload.data.body
                if ($bodyBytes -ge 1048576) {
                    $ok = $true
                    $detail = ("body {0} bytes" -f $bodyBytes)
                }
                else {
                    $detail = ("the maximum body was only {0} bytes" -f $bodyBytes)
                }
            }
            [pscustomobject]@{ Ok = $ok; Detail = $detail; Milliseconds = $run.Milliseconds }
        }
        $projects100Sample = {
            $run = Measure-CliJson -CliExecutable $shippedCli `
                -Arguments @('--data-root', $data100, '--format', 'json', 'viewer', 'projects', '--request-file', $projectsColdRequest) `
                -WorkingDirectory $repositoryFull -TimeoutSeconds $TimeoutSeconds
            $ok = $false
            $detail = $run.Problem
            if (-not $run.Problem) {
                if ($run.Payload.data.total_count -eq 100) {
                    $ok = $true
                    $detail = ("total {0}" -f $run.Payload.data.total_count)
                }
                else {
                    $detail = ("expected 100 projects, saw {0}" -f $run.Payload.data.total_count)
                }
            }
            [pscustomobject]@{ Ok = $ok; Detail = $detail; Milliseconds = $run.Milliseconds }
        }
        $projectsEmptySample = {
            $run = Measure-CliJson -CliExecutable $shippedCli `
                -Arguments @('--data-root', $dataEmpty, '--format', 'json', 'viewer', 'projects', '--request-file', $emptyProjectsRequest) `
                -WorkingDirectory $repositoryFull -TimeoutSeconds $TimeoutSeconds
            $ok = $false
            $detail = $run.Problem
            if (-not $run.Problem) {
                if ($run.Payload.data.total_count -eq 1000) {
                    $ok = $true
                    $detail = ("total {0}" -f $run.Payload.data.total_count)
                }
                else {
                    $detail = ("expected 1000 projects, saw {0}" -f $run.Payload.data.total_count)
                }
            }
            [pscustomobject]@{ Ok = $ok; Detail = $detail; Milliseconds = $run.Milliseconds }
        }
        $searchSample = {
            $run = Measure-CliJson -CliExecutable $shippedCli `
                -Arguments @('--data-root', $data100k, '--project', $hugeProject.project_id, '--format', 'json', 'viewer', 'tasks', '--request-file', $searchRequest) `
                -WorkingDirectory $repositoryFull -TimeoutSeconds $TimeoutSeconds
            $ok = $false
            $detail = $run.Problem
            if (-not $run.Problem) {
                if ($run.Payload.data.total_count -ge 1) {
                    $ok = $true
                    $detail = ("the literal %_ search found {0} tasks" -f $run.Payload.data.total_count)
                }
                else {
                    $detail = 'the literal %_ search found nothing'
                }
            }
            [pscustomobject]@{ Ok = $ok; Detail = $detail; Milliseconds = $run.Milliseconds }
        }

        $plan = @(
            [pscustomobject]@{ Id = 'M01'; Name = 'first task page (100000-task project)'; TargetMs = 500; Sample = $tasksPageSample; Iterations = $Iterations; Warmup = $Warmup },
            [pscustomobject]@{ Id = 'M02'; Name = 'task detail, 2 KiB body'; TargetMs = 300; Sample = $detailSample; Iterations = $Iterations; Warmup = $Warmup },
            [pscustomobject]@{ Id = 'M03'; Name = 'task detail, 1 MiB body'; TargetMs = 1000; Sample = $bigDetailSample; Iterations = $Iterations; Warmup = $Warmup },
            [pscustomobject]@{ Id = 'M04'; Name = 'save acknowledgement, uncontended'; TargetMs = 750; Sample = $saveSample; Iterations = $Iterations; Warmup = $Warmup },
            [pscustomobject]@{ Id = 'M05'; Name = 'project first page with statistics (100 projects)'; TargetMs = 5000; Sample = $projects100Sample; Iterations = $Iterations; Warmup = $Warmup },
            [pscustomobject]@{ Id = 'M06'; Name = 'project first page with statistics (1000 empty projects)'; TargetMs = 10000; Sample = $projectsEmptySample; Iterations = $Iterations; Warmup = $Warmup },
            [pscustomobject]@{ Id = 'M07'; Name = 'literal %_ body search (100000 tasks)'; TargetMs = 2000; Sample = $searchSample; Iterations = $Iterations; Warmup = $Warmup }
        )
        foreach ($entry in $plan) {
            Write-MeasureMessage -Message ("measuring {0}: {1}" -f $entry.Id, $entry.Name)
            $stats = Get-MeasureStatistic -Samples @()
            $details = @()
            $status = 'failed'
            try {
                $loop = Invoke-SampleLoop -Sample $entry.Sample -Iterations $entry.Iterations -Warmup $entry.Warmup
                $stats = Get-MeasureStatistic -Samples $loop.Samples
                $details = @($loop.Details)
                $status = Get-MeasureStatus -P95 $stats.P95 -TargetMs $entry.TargetMs -Count $stats.Count -ExpectedCount $entry.Iterations
            }
            catch {
                $details = @("measurement aborted: $($_.Exception.Message)")
            }
            $rows.Add([pscustomobject]@{
                    Id       = $entry.Id
                    Name     = $entry.Name
                    TargetMs = $entry.TargetMs
                    Status   = $status
                    Stats    = $stats
                    Details  = $details
                })
        }

        $summaryPath = Write-MeasureEvidence -EvidenceRoot $evidence -HostReport $hostReport -FixtureReport $fixtureReport `
            -CliIdentity $cliIdentity -Rows $rows -Unavailable $unavailable -FixtureRoot $fixtureResolved `
            -Iterations $Iterations -Warmup $Warmup
        $failedRows = @($rows | Where-Object { $_.Status -ne 'passed' })
        if ($failedRows.Count -eq 0) {
            $outcome = 0
            Write-MeasureMessage -Message ("OK - every measured target passed; summary {0}" -f $summaryPath)
        }
        else {
            foreach ($row in $failedRows) {
                Write-MeasureMessage -Message ("FAILED {0} {1}: p95 {2} ms against {3} ms (status {4})" -f `
                        $row.Id, $row.Name, $row.Stats.P95, $row.TargetMs, $row.Status)
            }
            Write-MeasureMessage -Message ("FAILED - at least one measured target missed; summary {0}" -f $summaryPath)
        }
    }
    catch {
        $failure = [ordered]@{
            generated_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            error         = $_.Exception.Message
            fixture_root  = $fixtureResolved
        }
        Set-Content -LiteralPath (Join-Path -Path $evidence -ChildPath 'measure-failure.txt') `
            -Value ($failure | ConvertTo-Json -Depth 6) -Encoding utf8NoBOM
        throw
    }
    finally {
        if ($fixtureOwned -and -not $KeepFixtureRoot) {
            Clear-MeasureFixture -FixtureRoot $fixtureResolved -WorkingRoot $WorkingRoot -RepositoryRoot $repositoryFull
            Write-MeasureMessage -Message ("fixture root removed: {0}" -f $fixtureResolved)
        }
        elseif (Test-Path -LiteralPath $fixtureResolved) {
            Write-MeasureMessage -Message ("fixture root kept: {0}" -f $fixtureResolved)
        }
    }

    return [pscustomobject]@{ ExitCode = $outcome; Evidence = $evidence }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $run = Invoke-Measure -ViewerRoot $ViewerRoot -RepositoryRoot $RepositoryRoot -EvidenceRoot $EvidenceRoot `
            -CliExecutable $CliExecutable -FixtureBinary $FixtureBinary -FixtureRoot $FixtureRoot `
            -WorkingRoot $WorkingRoot -Iterations $Iterations -Warmup $Warmup -TimeoutSeconds $TimeoutSeconds `
            -Seed $Seed -SkipBuild:$SkipBuild -KeepFixtureRoot:$KeepFixtureRoot
        exit $run.ExitCode
    }
    catch {
        Write-Information -MessageData ("measure: error: {0}" -f $_.Exception.Message) -InformationAction Continue
        exit 1
    }
}
