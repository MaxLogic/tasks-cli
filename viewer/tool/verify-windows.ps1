#requires -Version 7.0
<#
.SYNOPSIS
Runs the automated viewer gates, including external UIA on the packaged release.

.DESCRIPTION
viewer/spec.md section 11 asks for `verify-windows.ps1`: build the matching CLI,
run the Flutter gates and exercise the packaged release, keeping Flutter
test-build evidence apart from packaged-release evidence and failing on a
missing prerequisite.

The release UIA gate opens one window against a synthetic store. It sends no
keyboard or pointer input, does not drive NVDA, and does not access the real
clipboard:

  1. records the source commit, the dirty state and the toolchains;
  2. builds the matching `tasks.exe` from the current source and hashes it;
  3. seeds one throwaway CLI store in a unique temporary root outside the
     repository (two projects, every status and priority, labels, dependencies,
     Unicode text, a literal `%_` search case and one done row) and writes
     `fixture.json` beside it;
  4. runs `dart format`, `flutter analyze` and the full `flutter test` suite
     with the fixture passed through `--dart-define`;
  5. runs the end-to-end viewer cases that drive the real widgets over that
     real store (`test/integration/viewer_e2e_headless_test.dart`);
  6. rebuilds the CLI with `--features test-hooks`, closes the one known skip in
     `test/integration/real_cli_editor_test.dart` and restores the plain
     binary;
  7. builds the Windows release and packages it with `package.ps1`, which
     launch-tests the copy from a path with spaces and non-ASCII characters;
  8. launches the packaged release and checks its external Windows UIA tree;
  9. writes `verify-summary.json` and `verify-summary.md` into the evidence
     root, including the V01..V13 rows that stay unavailable without a human.

The Flutter `integration_test/viewer_test.dart` entry point remains opt-in with
`-IncludeWindowedIntegration`. Manual rows (NVDA speech, a real sign-in,
audible playback, live clipboard) remain unavailable.

.EXAMPLE
pwsh -NoProfile -File viewer/tool/verify-windows.ps1

.EXAMPLE
pwsh -NoProfile -File viewer/tool/verify-windows.ps1 -EvidenceRoot viewer/target/evidence/viewer/2026-09-22-slice7-verify -KeepFixtureRoot
#>
[CmdletBinding()]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '',
    Justification = 'The repository keeps PowerShell sources in UTF-8 without a BOM; the fixture needs real non-ASCII task text.')]
param(
    [string]$ViewerRoot = (Split-Path -Parent $PSScriptRoot),

    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),

    [string]$EvidenceRoot,

    [string]$CliExecutable,

    [string]$FlutterRoot,

    [string]$WorkingRoot,

    [string]$FixtureRoot,

    [string]$PackageToolPath,

    [string]$UiaProbeToolPath,

    [int]$FixtureSeed = 20260922,

    [int]$AlphaTaskCount = 28,

    [int]$BetaTaskCount = 4,

    [int]$FixtureCommandTimeoutSeconds = 120,

    [int]$GateTimeoutSeconds = 3600,

    [int]$UiaTimeoutSeconds = 45,

    [switch]$KeepFixtureRoot,

    [switch]$IncludeWindowedIntegration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-VerifyMessage {
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

function Get-FileSha256 {
    <#
    .SYNOPSIS
    Returns the lowercase sha256 of one file.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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

function Resolve-VerifyEvidenceRoot {
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
            ("{0}-verify-windows" -f $Now.ToString('yyyy-MM-dd-HHmmss'))
    }

    return Assert-PathInside -Path $EvidenceRoot -Parent $evidenceParent -Purpose 'verification evidence'
}

function Resolve-VerifyFixtureRoot {
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
            ("tasks-viewer-e2e-{0}" -f [guid]::NewGuid().ToString('n').Substring(0, 8))
    }
    $rootFull = [System.IO.Path]::GetFullPath($FixtureRoot)
    if (-not $rootFull.StartsWith([System.IO.Path]::GetFullPath($WorkingRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use '$rootFull' as the fixture root: it must stay inside '$WorkingRoot'."
    }
    $repositoryFull = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
    if ($rootFull.Equals($repositoryFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $rootFull.StartsWith($repositoryFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use '$rootFull' as the fixture root: fixtures never live inside the repository."
    }

    return $rootFull
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

function Write-GateLog {
    <#
    .SYNOPSIS
    Writes one gate log and returns its path.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EvidenceRoot,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $path = Join-Path -Path $EvidenceRoot -ChildPath $Name
    Set-Content -LiteralPath $path -Value $Text -Encoding utf8NoBOM
    return $path
}

function Resolve-FlutterLauncher {
    <#
    .SYNOPSIS
    Finds the deterministic Flutter entry points (dart + tool snapshot).

    .DESCRIPTION
    `flutter.bat` only works through `cmd.exe`, whose quoting cannot be captured
    safely; the same tool runs from its snapshot with FLUTTER_ROOT set, so every
    gate can start a real process with an argument list instead.
    #>
    param(
        [string]$FlutterRoot
    )

    if ([string]::IsNullOrWhiteSpace($FlutterRoot)) {
        $FlutterRoot = $env:FLUTTER_ROOT
    }
    if ([string]::IsNullOrWhiteSpace($FlutterRoot)) {
        $command = Get-Command -Name 'flutter.bat' -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            $command = Get-Command -Name 'flutter' -ErrorAction SilentlyContinue
        }
        if ($null -ne $command) {
            $FlutterRoot = Split-Path -Parent (Split-Path -Parent $command.Source)
        }
    }
    if ([string]::IsNullOrWhiteSpace($FlutterRoot) -or -not (Test-Path -LiteralPath $FlutterRoot -PathType Container)) {
        throw 'The Flutter root could not be resolved: pass -FlutterRoot or set FLUTTER_ROOT.'
    }

    $dartName = if ($IsWindows) { 'dart.exe' } else { 'dart' }
    $dart = Join-Path -Path $FlutterRoot -ChildPath "bin/cache/dart-sdk/bin/$dartName"
    $snapshot = Join-Path -Path $FlutterRoot -ChildPath 'bin/cache/flutter_tools.snapshot'
    foreach ($required in @($dart, $snapshot)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "The Flutter installation at '$FlutterRoot' has no '$required'."
        }
    }

    return [pscustomobject]@{
        Root     = [System.IO.Path]::GetFullPath($FlutterRoot)
        Dart     = $dart
        Snapshot = $snapshot
    }
}

function Invoke-FlutterCommand {
    <#
    .SYNOPSIS
    Runs the Flutter tool from its snapshot and captures both streams.
    #>
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Launcher,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $env:FLUTTER_ROOT = $Launcher.Root
    $full = @($Launcher.Snapshot) + $Arguments
    return Invoke-CapturedProcess -FilePath $Launcher.Dart -Arguments $full `
        -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
}

function Get-FlutterTestCount {
    <#
    .SYNOPSIS
    Reads the selected/passed/skipped/failed counts out of a reporter log.

    .DESCRIPTION
    The expanded reporter prints `+passed ~skipped -failed:` progress lines and
    finishes with either `All tests passed!` or a failing-test list. The last
    counts line is the run total, and a nonzero failed count or a missing
    success line fails the gate even when the process exit code were lost.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $passed = 0
    $skipped = 0
    $failed = 0
    foreach ($line in ($Text -split "\r?\n")) {
        # The expanded reporter prints `<elapsed> +passed ~skipped -failed: <name>`,
        # so the counts never sit at the start of the line; take the last match.
        # `$matches` is an automatic variable, so keep the counts in a named one.
        $countMatches = [regex]::Matches($line, '\+(\d+)(?:\s+~(\d+))?(?:\s+-(\d+))?:')
        if ($countMatches.Count -eq 0) {
            continue
        }
        $countMatch = $countMatches[$countMatches.Count - 1]
        $passed = [int]$countMatch.Groups[1].Value
        if ($countMatch.Groups[2].Success) {
            $skipped = [int]$countMatch.Groups[2].Value
        }
        if ($countMatch.Groups[3].Success) {
            $failed = [int]$countMatch.Groups[3].Value
        }
    }

    return [pscustomobject]@{
        Passed  = $passed
        Skipped = $skipped
        Failed  = $failed
        Succeeded = $Text.Contains('All tests passed!', [System.StringComparison]::Ordinal)
    }
}

function Invoke-TasksCli {
    <#
    .SYNOPSIS
    Runs the CLI once and fails on a timeout or a nonzero exit.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Executable,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $result = Invoke-CapturedProcess -FilePath $Executable -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
    if ($result.TimedOut) {
        throw "tasks.exe $($Arguments -join ' ') did not exit within $TimeoutSeconds s."
    }
    if ($result.ExitCode -ne 0) {
        throw "tasks.exe $($Arguments -join ' ') failed with exit code $($result.ExitCode): $($result.StdErr.Trim())"
    }

    return $result
}

function Invoke-TasksCliJson {
    <#
    .SYNOPSIS
    Runs the CLI once and decodes its JSON envelope.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Executable,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $result = Invoke-TasksCli -Executable $Executable -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
    try {
        return $result.StdOut | ConvertFrom-Json -Depth 20
    }
    catch {
        throw "tasks.exe $($Arguments -join ' ') returned unreadable JSON: $($_.Exception.Message)"
    }
}

function Get-ViewerFixtureBody {
    <#
    .SYNOPSIS
    Builds one deterministic ~2 KiB task body with a unique marker.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Prefix,

        [Parameter(Mandatory)]
        [int]$Index
    )

    $number = '{0:d2}' -f $Index
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("$Prefix body $number.")
    $lines.Add("Body marker $number.")
    for ($line = 1; $line -le 32; $line++) {
        $lines.Add("Filler line $line for task ${number}: alpha beta gamma delta epsilon zeta eta theta.")
    }

    return ($lines -join "`n")
}

function Initialize-ViewerVerifyFixture {
    <#
    .SYNOPSIS
    Seeds one throwaway store through the real CLI and writes fixture.json.

    .DESCRIPTION
    Deterministic layout: rows 1 and 2 carry the reserved P0 priorities and are
    therefore the first two rows of the default priority sort; rows 25 and 26
    hold the literal `%_` search text; row 27 is Unicode; the last row is done,
    so the statistics total and the default open scope differ by exactly one.
    Nothing here touches the live backlog: the root, the registry and the
    settings root all live under the run-owned temporary directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FixtureRoot,

        [Parameter(Mandatory)]
        [string]$CliExecutable,

        [Parameter(Mandatory)]
        [int]$Seed,

        [int]$AlphaTaskCount = 28,

        [int]$BetaTaskCount = 4,

        [Parameter(Mandatory)]
        [int]$CommandTimeoutSeconds
    )

    if ($AlphaTaskCount -lt 28) {
        throw 'AlphaTaskCount must be at least 28: rows 25..28 are reserved for the literal search, Unicode and done cases.'
    }
    if ($BetaTaskCount -lt 1) {
        throw 'BetaTaskCount must be at least 1.'
    }
    if (Test-Path -LiteralPath $FixtureRoot) {
        throw "The fixture root '$FixtureRoot' already exists; pass a new -FixtureRoot."
    }

    $alphaDirectory = Join-Path $FixtureRoot 'projects/alpha'
    $betaDirectory = Join-Path $FixtureRoot 'projects/beta'
    $bodyDirectory = Join-Path $FixtureRoot 'bodies'
    $requestDirectory = Join-Path $FixtureRoot 'requests'
    $settingsRoot = Join-Path $FixtureRoot 'settings'
    foreach ($directory in @($alphaDirectory, $betaDirectory, $bodyDirectory, $requestDirectory, $settingsRoot)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $alphaInit = Invoke-TasksCliJson -Executable $CliExecutable -WorkingDirectory $FixtureRoot `
        -Arguments @('--format', 'json', '--data-root', $FixtureRoot, 'init', '--root', $alphaDirectory) `
        -TimeoutSeconds $CommandTimeoutSeconds
    $betaInit = Invoke-TasksCliJson -Executable $CliExecutable -WorkingDirectory $FixtureRoot `
        -Arguments @('--format', 'json', '--data-root', $FixtureRoot, 'init', '--root', $betaDirectory) `
        -TimeoutSeconds $CommandTimeoutSeconds
    $alphaId = [string]$alphaInit.project_id
    $betaId = [string]$betaInit.project_id
    if ([string]::IsNullOrWhiteSpace($alphaId) -or [string]::IsNullOrWhiteSpace($betaId)) {
        throw 'init did not report a project id for the fixture projects.'
    }

    $statuses = @('todo', 'in-progress', 'blocked', 'draft')
    $priorities = @('P1', 'P2', 'P3')
    $alphaTaskIds = [System.Collections.Generic.List[int]]::new()
    for ($index = 1; $index -le $AlphaTaskCount; $index++) {
        $number = '{0:d2}' -f $index
        $title = "Alpha task $number"
        $priority = $priorities[($index - 1) % $priorities.Count]
        $status = $statuses[($index - 1) % $statuses.Count]
        $labels = ''
        $dependencies = ''
        if ($index -eq 1) {
            $priority = 'P0'
            $status = 'todo'
            $labels = 'ui,a11y'
        }
        elseif ($index -eq 2) {
            $priority = 'P0'
            $status = 'in-progress'
        }
        elseif ($index -eq 3) {
            $dependencies = 'T-001,T-002'
        }
        elseif ($index -eq 25) {
            $title = 'Literal 50%_ probe'
            $priority = 'P2'
            $status = 'todo'
        }
        elseif ($index -eq 26) {
            $title = 'Literal 50%_ probe two'
            $priority = 'P3'
            $status = 'blocked'
        }
        elseif ($index -eq 27) {
            $title = 'Zażółć gęślą jaźń テスト 27'
            $priority = 'P1'
            $status = 'todo'
        }
        elseif ($index -eq $AlphaTaskCount) {
            $title = "Alpha task $number done"
            $status = 'done'
        }

        $bodyPath = Join-Path $bodyDirectory "alpha-$number.txt"
        Set-Content -LiteralPath $bodyPath -Value (Get-ViewerFixtureBody -Prefix 'Alpha' -Index $index) -Encoding utf8NoBOM
        $arguments = @('--format', 'json', '--data-root', $FixtureRoot, '--project', $alphaId,
            'create', '--title', $title, '--body-file', $bodyPath, '--priority', $priority, '--status', $status)
        if (-not [string]::IsNullOrWhiteSpace($labels)) {
            $arguments += @('--labels', $labels)
        }
        if (-not [string]::IsNullOrWhiteSpace($dependencies)) {
            $arguments += @('--deps', $dependencies)
        }
        $created = Invoke-TasksCliJson -Executable $CliExecutable -Arguments $arguments `
            -WorkingDirectory $FixtureRoot -TimeoutSeconds $CommandTimeoutSeconds
        $alphaTaskIds.Add([int]$created.data.id)
    }

    for ($index = 1; $index -le $BetaTaskCount; $index++) {
        $number = '{0:d2}' -f $index
        $bodyPath = Join-Path $bodyDirectory "beta-$number.txt"
        Set-Content -LiteralPath $bodyPath -Value (Get-ViewerFixtureBody -Prefix 'Beta' -Index $index) -Encoding utf8NoBOM
        [void](Invoke-TasksCliJson -Executable $CliExecutable -WorkingDirectory $FixtureRoot `
            -Arguments @('--format', 'json', '--data-root', $FixtureRoot, '--project', $betaId,
                'create', '--title', "Beta task $number", '--body-file', $bodyPath, '--status', 'todo') `
            -TimeoutSeconds $CommandTimeoutSeconds)
    }

    $projectRequest = Join-Path $requestDirectory 'projects.json'
    Set-Content -LiteralPath $projectRequest -Value '{"offset":0,"limit":50}' -Encoding utf8NoBOM
    $projects = Invoke-TasksCliJson -Executable $CliExecutable -WorkingDirectory $FixtureRoot `
        -Arguments @('--format', 'json', '--data-root', $FixtureRoot, 'viewer', 'projects', '--request-file', $projectRequest) `
        -TimeoutSeconds $CommandTimeoutSeconds
    $alphaItem = @($projects.data.items | Where-Object { $_.project_id -eq $alphaId })
    $betaItem = @($projects.data.items | Where-Object { $_.project_id -eq $betaId })
    if ($alphaItem.Count -ne 1 -or $betaItem.Count -ne 1) {
        throw 'The seeded projects are missing from the viewer project page.'
    }
    # init names a project after its root directory, so the manifest must speak
    # the name the CLI reported rather than a label of the harness's choosing.
    $alphaName = [string]$alphaItem[0].name
    $betaName = [string]$betaItem[0].name
    if ([string]::IsNullOrWhiteSpace($alphaName) -or [string]::IsNullOrWhiteSpace($betaName)) {
        throw 'The viewer project page reported no name for a fixture project.'
    }

    $taskRequest = Join-Path $requestDirectory 'tasks.json'
    Set-Content -LiteralPath $taskRequest -Value '{"offset":0,"limit":200}' -Encoding utf8NoBOM
    $tasks = Invoke-TasksCliJson -Executable $CliExecutable -WorkingDirectory $FixtureRoot `
        -Arguments @('--format', 'json', '--data-root', $FixtureRoot, '--project', $alphaId, 'viewer', 'tasks', '--request-file', $taskRequest) `
        -TimeoutSeconds $CommandTimeoutSeconds

    $alphaTotal = [int]$alphaItem[0].stats.total
    $alphaOpen = [int]$alphaItem[0].stats.open
    $betaTotal = [int]$betaItem[0].stats.total
    $openTasks = [int]$tasks.data.total_count
    if ($alphaTotal -ne $AlphaTaskCount -or $betaTotal -ne $BetaTaskCount) {
        throw "The seeded statistics disagree with the store: alpha $alphaTotal (expected $AlphaTaskCount), beta $betaTotal (expected $BetaTaskCount)."
    }
    if ($openTasks -ne ($AlphaTaskCount - 1)) {
        throw "The default open scope reported $openTasks tasks (expected $($AlphaTaskCount - 1))."
    }
    if ($alphaOpen -ne $openTasks) {
        throw "The project statistics report $alphaOpen open tasks while the default scope reports $openTasks."
    }
    $firstTwo = @($tasks.data.items | Select-Object -First 2)
    if ($firstTwo.Count -ne 2 -or [int]$firstTwo[0].id -ne 1 -or [int]$firstTwo[1].id -ne 2) {
        throw 'The default priority sort must start with the two reserved P0 rows (T-001, T-002).'
    }

    $manifest = [ordered]@{
        schema_version   = 1
        seed             = $Seed
        created_utc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        data_root        = $FixtureRoot
        settings_root    = $settingsRoot
        cli              = $CliExecutable
        projects         = @(
            [ordered]@{
                role            = 'alpha'
                name            = $alphaName
                project_id      = $alphaId
                task_count      = $alphaTotal
                open_task_count = $openTasks
            },
            [ordered]@{
                role            = 'beta'
                name            = $betaName
                project_id      = $betaId
                task_count      = $betaTotal
                open_task_count = $BetaTaskCount
            }
        )
        checks           = [ordered]@{
            first_row_id        = 'T-001'
            first_row_title     = 'Alpha task 01'
            detail_row_id       = 'T-002'
            detail_body_marker  = 'Body marker 02'
            search_query        = '%_'
            search_expected_count = 2
            search_expected_title = 'Literal 50%_ probe'
            save_task_id        = 'T-001'
            save_new_title      = 'Alpha task 01 renamed by the headless viewer'
        }
    }
    $manifestPath = Join-Path $FixtureRoot 'fixture.json'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM

    return [pscustomobject]@{
        Root          = $FixtureRoot
        ManifestPath  = $manifestPath
        SettingsRoot  = $settingsRoot
        AlphaProject  = $alphaId
        BetaProject   = $betaId
        AlphaTotal    = $alphaTotal
        AlphaOpen     = $openTasks
        BetaTotal     = $betaTotal
    }
}

function Clear-ViewerVerifyFixture {
    <#
    .SYNOPSIS
    Removes one run-owned fixture root after re-checking its resolved bounds.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FixtureRoot,

        [Parameter(Mandatory)]
        [string]$WorkingRoot,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [switch]$Keep
    )

    if ($Keep) {
        return $false
    }
    $resolved = Resolve-VerifyFixtureRoot -WorkingRoot $WorkingRoot -FixtureRoot $FixtureRoot -RepositoryRoot $RepositoryRoot
    $leaf = Split-Path -Leaf $resolved
    if (-not $leaf.StartsWith('tasks-viewer-e2e-', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove '$resolved': the name is not a run-owned fixture root."
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
    return $true
}

function Add-VerifyGate {
    <#
    .SYNOPSIS
    Records one gate result for the evidence summary.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Gates,

        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Command,

        [string]$Log,

        [string]$Detail = ''
    )

    $Gates.Add([pscustomobject]@{
            Id      = $Id
            Name    = $Name
            Status  = $Status
            Command = $Command
            Log     = $Log
            Detail  = $Detail
        })
}

function Get-ToolchainReport {
    <#
    .SYNOPSIS
    Captures the toolchains and the machine the gates ran on.
    #>
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Launcher,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Toolchain and machine")
    $lines.Add("captured_utc: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))")
    $flutter = Invoke-FlutterCommand -Launcher $Launcher -Arguments @('--version') -WorkingDirectory $RepositoryRoot -TimeoutSeconds 300
    $lines.Add('')
    $lines.Add('## flutter --version')
    $lines.Add($flutter.StdOut.Trim())
    if (-not [string]::IsNullOrWhiteSpace($flutter.StdErr)) {
        $lines.Add($flutter.StdErr.Trim())
    }
    foreach ($probe in @(
            [pscustomobject]@{ Title = 'git rev-parse HEAD'; File = 'git'; Arguments = @('-C', $RepositoryRoot, 'rev-parse', 'HEAD') }
            [pscustomobject]@{ Title = 'git status --porcelain'; File = 'git'; Arguments = @('-C', $RepositoryRoot, 'status', '--porcelain') }
            [pscustomobject]@{ Title = 'cargo --version'; File = 'cargo'; Arguments = @('--version') }
            [pscustomobject]@{ Title = 'rustc --version'; File = 'rustc'; Arguments = @('--version') }
        )) {
        $lines.Add('')
        $lines.Add("## $($probe.Title)")
        try {
            $result = Invoke-CapturedProcess -FilePath $probe.File -Arguments $probe.Arguments `
                -WorkingDirectory $RepositoryRoot -TimeoutSeconds $TimeoutSeconds
            $lines.Add($result.StdOut.Trim())
            if (-not [string]::IsNullOrWhiteSpace($result.StdErr)) {
                $lines.Add($result.StdErr.Trim())
            }
        }
        catch {
            $lines.Add("unavailable: $($_.Exception.Message)")
        }
    }
    $lines.Add('')
    $lines.Add('## machine')
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $lines.Add("os: $($os.Caption) $($os.Version) build $($os.BuildNumber)")
        $lines.Add("cpu: $($cpu.Name) ($($cpu.NumberOfLogicalProcessors) logical processors)")
        $lines.Add("ram_bytes: $($os.TotalVisibleMemorySize * 1KB)")
        $lines.Add("power_plan_note: record the active Windows power mode by hand for performance runs")
    }
    catch {
        $lines.Add("machine details unavailable: $($_.Exception.Message)")
    }

    return ($lines -join "`n")
}

function Assert-BundleHash {
    <#
    .SYNOPSIS
    Re-computes every SHA256SUMS.txt entry of one packaged bundle.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BundleRoot
    )

    $hashPath = Join-Path -Path $BundleRoot -ChildPath 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
        throw "The packaged bundle has no SHA256SUMS.txt at '$hashPath'."
    }
    $checked = 0
    $findings = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-Content -LiteralPath $hashPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $match = [regex]::Match($line.Trim(), '^([0-9a-fA-F]{64})\s+(.+)$')
        if (-not $match.Success) {
            $findings.Add("SHA256SUMS.txt line '$line' is not '<hash>  <path>'.")
            continue
        }
        $relative = $match.Groups[2].Value
        $file = Join-Path -Path $BundleRoot -ChildPath ($relative -replace '/', '\')
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            $findings.Add("Bundled file '$relative' is missing.")
            continue
        }
        $actual = Get-FileSha256 -Path $file
        if ($actual -ne $match.Groups[1].Value.ToLowerInvariant()) {
            $findings.Add("Bundled file '$relative' hash mismatch.")
            continue
        }
        $checked += 1
    }

    return [pscustomobject]@{ Checked = $checked; Findings = @($findings) }
}

function Format-GateLog {
    <#
    .SYNOPSIS
    Renders one captured process result as a gate log.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [pscustomobject]$Result,

        [string]$Header
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Header)) {
        $lines.Add($Header)
        $lines.Add('')
    }
    $lines.Add('$ ' + $Command)
    $lines.Add("exit_code: $($Result.ExitCode)")
    if ($Result.TimedOut) {
        $lines.Add('timed_out: true')
    }
    $lines.Add('')
    $lines.Add('--- stdout ---')
    $lines.Add(('' + $Result.StdOut).TrimEnd())
    $lines.Add('--- stderr ---')
    $lines.Add(('' + $Result.StdErr).TrimEnd())

    return ($lines -join "`n")
}

function Invoke-VerifyWindows {
    <#
    .SYNOPSIS
    Runs the automated viewer gates and writes one evidence root.

    .DESCRIPTION
    The gate order matters: the throwaway store is seeded by the plain release
    binary, the full Flutter suite runs against that binary (one documented
    `test-hooks` skip), the `test-hooks` build then closes that skip in its own
    focused run, the plain binary is rebuilt and re-checked before the packaged
    release is built, and the end-to-end viewer cases run against the shipped
    binary. G11 checks external UIA on the packaged release using a separate
    synthetic store. Every log lands in the evidence root and every unrun
    manual row is reported as unavailable.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ViewerRoot,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [string]$EvidenceRoot,

        [string]$CliExecutable,

        [string]$FlutterRoot,

        [string]$WorkingRoot,

        [string]$FixtureRoot,

        [string]$PackageToolPath,

        [string]$UiaProbeToolPath,

        [int]$FixtureSeed = 20260922,

        [int]$AlphaTaskCount = 28,

        [int]$BetaTaskCount = 4,

        [int]$FixtureCommandTimeoutSeconds = 120,

        [int]$GateTimeoutSeconds = 3600,

        [int]$UiaTimeoutSeconds = 45,

        [switch]$KeepFixtureRoot,

        [switch]$IncludeWindowedIntegration
    )

    $viewerFull = [System.IO.Path]::GetFullPath($ViewerRoot)
    $repositoryFull = [System.IO.Path]::GetFullPath($RepositoryRoot)
    if ([string]::IsNullOrWhiteSpace($WorkingRoot)) {
        $WorkingRoot = [System.IO.Path]::GetTempPath()
    }
    if ([string]::IsNullOrWhiteSpace($CliExecutable)) {
        $CliExecutable = Join-Path -Path $repositoryFull -ChildPath 'target/release/tasks.exe'
    }
    if ([string]::IsNullOrWhiteSpace($PackageToolPath)) {
        $PackageToolPath = Join-Path -Path $viewerFull -ChildPath 'tool/package.ps1'
    }
    if ([string]::IsNullOrWhiteSpace($UiaProbeToolPath)) {
        $UiaProbeToolPath = Join-Path -Path $viewerFull -ChildPath 'tool/verify-release-uia.ps1'
    }
    if (-not (Test-Path -LiteralPath $PackageToolPath -PathType Leaf)) {
        throw "The packaging tool '$PackageToolPath' is missing."
    }
    if (-not (Test-Path -LiteralPath $UiaProbeToolPath -PathType Leaf)) {
        throw "The release UIA probe '$UiaProbeToolPath' is missing."
    }

    $evidence = Resolve-VerifyEvidenceRoot -ViewerRoot $viewerFull -EvidenceRoot $EvidenceRoot
    New-Item -ItemType Directory -Force -Path $evidence | Out-Null
    $launcher = Resolve-FlutterLauncher -FlutterRoot $FlutterRoot
    $fixtureResolved = Resolve-VerifyFixtureRoot -WorkingRoot $WorkingRoot -FixtureRoot $FixtureRoot -RepositoryRoot $repositoryFull
    # The full suite already runs the end-to-end cases against $fixtureResolved,
    # and the save case legitimately renames T-001 there. The end-to-end gate is a
    # separate gate, so it seeds its own store rather than re-running the same
    # cases over rows another gate just mutated.
    $e2eFixtureResolved = Resolve-VerifyFixtureRoot -WorkingRoot $WorkingRoot -RepositoryRoot $repositoryFull `
        -FixtureRoot "$fixtureResolved-e2e"
    $uiaFixtureResolved = Resolve-VerifyFixtureRoot -WorkingRoot $WorkingRoot -RepositoryRoot $repositoryFull `
        -FixtureRoot "$fixtureResolved-uia"

    $findings = [System.Collections.Generic.List[string]]::new()
    $gates = [System.Collections.Generic.List[object]]::new()
    $fixture = $null
    $e2eFixture = $null
    $uiaFixture = $null
    $failure = $null
    $plainCliHash = $null
    $restoredCliHash = $null
    $fullCounts = $null
    $hookCounts = $null
    $e2eCounts = $null
    $packageResult = $null
    $packageHash = $null
    $windowedStatus = 'not-requested'
    $windowedLog = $null
    $uiaStatus = 'not-run'
    $uiaLog = $null
    $hookSkipMarker = 'has no TASKS_PRECOMMIT_READY_FILE test hook'

    try {
        Write-VerifyMessage -Message 'verify: collecting the toolchains'
        $toolchainText = Get-ToolchainReport -Launcher $launcher -RepositoryRoot $repositoryFull -TimeoutSeconds 300
        $toolchainLog = Write-GateLog -EvidenceRoot $evidence -Name '00-toolchains.txt' -Text $toolchainText
        Add-VerifyGate -Gates $gates -Id 'G00' -Name 'toolchains' -Status 'passed' `
            -Command 'flutter --version; git rev-parse HEAD; git status --porcelain; cargo --version; rustc --version' `
            -Log $toolchainLog

        Write-VerifyMessage -Message 'verify: cargo build --release --locked'
        $buildResult = Invoke-CapturedProcess -FilePath 'cargo' -Arguments @('build', '--release', '--locked') `
            -WorkingDirectory $repositoryFull -TimeoutSeconds $GateTimeoutSeconds
        $buildLog = Write-GateLog -EvidenceRoot $evidence -Name '01-cargo-build-release.txt' `
            -Text (Format-GateLog -Command 'cargo build --release --locked' -Result $buildResult -Header "repository: $repositoryFull")
        if ($buildResult.TimedOut -or $buildResult.ExitCode -ne 0) {
            throw "cargo build --release --locked failed with exit code $($buildResult.ExitCode); see $buildLog"
        }
        if (-not (Test-Path -LiteralPath $CliExecutable -PathType Leaf)) {
            throw "The release build did not produce '$CliExecutable'."
        }
        $plainCliHash = Get-FileSha256 -Path $CliExecutable
        Add-VerifyGate -Gates $gates -Id 'G01' -Name 'release CLI build' -Status 'passed' `
            -Command 'cargo build --release --locked' -Log $buildLog -Detail "sha256 $plainCliHash"

        Write-VerifyMessage -Message "verify: seeding the throwaway store in '$fixtureResolved'"
        $fixture = Initialize-ViewerVerifyFixture -FixtureRoot $fixtureResolved -CliExecutable $CliExecutable `
            -Seed $FixtureSeed -AlphaTaskCount $AlphaTaskCount -BetaTaskCount $BetaTaskCount `
            -CommandTimeoutSeconds $FixtureCommandTimeoutSeconds
        $fixtureCopy = Join-Path -Path $evidence -ChildPath 'fixture.json'
        Copy-Item -LiteralPath $fixture.ManifestPath -Destination $fixtureCopy -Force
        $fixtureLog = Write-GateLog -EvidenceRoot $evidence -Name '02-fixture.txt' -Text (@(
                "fixture_root: $($fixture.Root)"
                "manifest: $($fixture.ManifestPath)"
                "manifest_copy: $fixtureCopy"
                "settings_root: $($fixture.SettingsRoot)"
                "alpha_project: $($fixture.AlphaProject)"
                "beta_project: $($fixture.BetaProject)"
                "alpha_total: $($fixture.AlphaTotal)"
                "alpha_open: $($fixture.AlphaOpen)"
                "beta_total: $($fixture.BetaTotal)"
                "cli: $CliExecutable"
                "cli_sha256: $plainCliHash"
                "manifest_sha256: $(Get-FileSha256 -Path $fixture.ManifestPath)"
            ) -join "`n")
        Add-VerifyGate -Gates $gates -Id 'G02' -Name 'throwaway fixture seed' -Status 'passed' `
            -Command 'tasks.exe init / create / viewer projects / viewer tasks' -Log $fixtureLog `
            -Detail "alpha $($fixture.AlphaTotal) tasks ($($fixture.AlphaOpen) open), beta $($fixture.BetaTotal) tasks"

        Write-VerifyMessage -Message 'verify: dart format --set-exit-if-changed'
        $formatResult = Invoke-CapturedProcess -FilePath $launcher.Dart `
            -Arguments @('format', '--output=none', '--set-exit-if-changed', 'lib', 'test', 'integration_test') `
            -WorkingDirectory $viewerFull -TimeoutSeconds 900
        $formatLog = Write-GateLog -EvidenceRoot $evidence -Name '03-dart-format.txt' `
            -Text (Format-GateLog -Command 'dart format --output=none --set-exit-if-changed lib test integration_test' -Result $formatResult)
        if ($formatResult.TimedOut -or $formatResult.ExitCode -ne 0) {
            throw "dart format reported unformatted files (exit $($formatResult.ExitCode)); see $formatLog"
        }
        Add-VerifyGate -Gates $gates -Id 'G03' -Name 'dart format' -Status 'passed' `
            -Command 'dart format --output=none --set-exit-if-changed lib test integration_test' -Log $formatLog

        Write-VerifyMessage -Message 'verify: flutter pub get and flutter analyze --fatal-infos'
        $pubResult = Invoke-FlutterCommand -Launcher $launcher -Arguments @('pub', 'get') `
            -WorkingDirectory $viewerFull -TimeoutSeconds 1800
        $analyzeResult = Invoke-FlutterCommand -Launcher $launcher -Arguments @('analyze', '--no-pub', '--fatal-infos') `
            -WorkingDirectory $viewerFull -TimeoutSeconds 1800
        $analyzeLog = Write-GateLog -EvidenceRoot $evidence -Name '04-flutter-analyze.txt' -Text (@(
                (Format-GateLog -Command 'flutter pub get' -Result $pubResult)
                ''
                (Format-GateLog -Command 'flutter analyze --no-pub --fatal-infos' -Result $analyzeResult)
            ) -join "`n")
        if ($pubResult.TimedOut -or $pubResult.ExitCode -ne 0) {
            throw "flutter pub get failed with exit code $($pubResult.ExitCode); see $analyzeLog"
        }
        if ($analyzeResult.TimedOut -or $analyzeResult.ExitCode -ne 0) {
            throw "flutter analyze --fatal-infos failed with exit code $($analyzeResult.ExitCode); see $analyzeLog"
        }
        Add-VerifyGate -Gates $gates -Id 'G04' -Name 'flutter analyze' -Status 'passed' `
            -Command 'flutter pub get; flutter analyze --no-pub --fatal-infos' -Log $analyzeLog

        $fixtureDefine = "TASKS_VIEWER_E2E_FIXTURE=$($fixture.ManifestPath)"
        Write-VerifyMessage -Message 'verify: flutter test (full suite against the shipped CLI)'
        $fullResult = Invoke-FlutterCommand -Launcher $launcher `
            -Arguments @('test', '--reporter', 'expanded', "--dart-define=$fixtureDefine") `
            -WorkingDirectory $viewerFull -TimeoutSeconds $GateTimeoutSeconds
        $fullLog = Write-GateLog -EvidenceRoot $evidence -Name '05-flutter-test-full.txt' `
            -Text (Format-GateLog -Command "flutter test --reporter expanded --dart-define=$fixtureDefine" -Result $fullResult)
        $fullCounts = Get-FlutterTestCount -Text ($fullResult.StdOut + "`n" + $fullResult.StdErr)
        if ($fullResult.TimedOut) {
            throw "The full Flutter suite did not finish within $GateTimeoutSeconds s; see $fullLog"
        }
        if ($fullCounts.Failed -gt 0 -or -not $fullCounts.Succeeded -or $fullCounts.Passed -eq 0) {
            throw "The full Flutter suite failed (+$($fullCounts.Passed) ~$($fullCounts.Skipped) -$($fullCounts.Failed)); see $fullLog"
        }
        $hookSkipSeen = ($fullResult.StdOut + "`n" + $fullResult.StdErr).Contains($hookSkipMarker, [System.StringComparison]::Ordinal)
        if ($fullCounts.Skipped -eq 0) {
            $fullDetail = "passed $($fullCounts.Passed), skipped 0: the CLI already carries the test hooks"
        }
        elseif ($fullCounts.Skipped -eq 1 -and $hookSkipSeen) {
            $fullDetail = "passed $($fullCounts.Passed), skipped 1: the documented acknowledgement-loss case, closed by G06"
        }
        else {
            throw "The full Flutter suite skipped $($fullCounts.Skipped) cases and only the documented test-hooks skip is accepted here (+$($fullCounts.Passed) ~$($fullCounts.Skipped) -$($fullCounts.Failed)); see $fullLog"
        }
        Add-VerifyGate -Gates $gates -Id 'G05' -Name 'flutter test (full suite)' -Status 'passed' `
            -Command "flutter test --reporter expanded --dart-define=$fixtureDefine" -Log $fullLog -Detail $fullDetail

        Write-VerifyMessage -Message 'verify: cargo build --release --locked --features test-hooks'
        $hookBuild = Invoke-CapturedProcess -FilePath 'cargo' `
            -Arguments @('build', '--release', '--locked', '--features', 'test-hooks') `
            -WorkingDirectory $repositoryFull -TimeoutSeconds $GateTimeoutSeconds
        $hookBuildLog = Write-GateLog -EvidenceRoot $evidence -Name '06-cargo-build-test-hooks.txt' `
            -Text (Format-GateLog -Command 'cargo build --release --locked --features test-hooks' -Result $hookBuild -Header "repository: $repositoryFull")
        if ($hookBuild.TimedOut -or $hookBuild.ExitCode -ne 0) {
            throw "cargo build --release --locked --features test-hooks failed with exit code $($hookBuild.ExitCode); see $hookBuildLog"
        }
        $hookedCliText = [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes($CliExecutable))
        foreach ($hook in @('TASKS_PRECOMMIT_READY_FILE', 'TASKS_HOLD_PRECOMMIT_MS')) {
            if (-not $hookedCliText.Contains($hook, [System.StringComparison]::Ordinal)) {
                throw "The test-hooks build at '$CliExecutable' still has no $hook string."
            }
        }
        Write-VerifyMessage -Message 'verify: the acknowledgement-loss case with the test-hooks CLI'
        $hookResult = Invoke-FlutterCommand -Launcher $launcher `
            -Arguments @('test', 'test/integration/real_cli_editor_test.dart', '--reporter', 'expanded') `
            -WorkingDirectory $viewerFull -TimeoutSeconds $GateTimeoutSeconds
        $hookLog = Write-GateLog -EvidenceRoot $evidence -Name '07-flutter-test-test-hooks.txt' `
            -Text (@(
                (Format-GateLog -Command 'cargo build --release --locked --features test-hooks' -Result $hookBuild)
                ''
                (Format-GateLog -Command 'flutter test test/integration/real_cli_editor_test.dart --reporter expanded' -Result $hookResult)
            ) -join "`n")
        $hookCounts = Get-FlutterTestCount -Text ($hookResult.StdOut + "`n" + $hookResult.StdErr)
        if ($hookResult.TimedOut -or $hookResult.ExitCode -ne 0 -or $hookCounts.Failed -gt 0 -or -not $hookCounts.Succeeded -or $hookCounts.Passed -eq 0) {
            throw "The test-hooks run failed (+$($hookCounts.Passed) ~$($hookCounts.Skipped) -$($hookCounts.Failed), exit $($hookResult.ExitCode)); see $hookLog"
        }
        if ($hookCounts.Skipped -ne 0) {
            throw "The test-hooks run still skipped $($hookCounts.Skipped) case(s); see $hookLog"
        }
        Add-VerifyGate -Gates $gates -Id 'G06' -Name 'test-hooks CLI closes the skip' -Status 'passed' `
            -Command 'cargo build --release --locked --features test-hooks; flutter test test/integration/real_cli_editor_test.dart' `
            -Log $hookLog -Detail "passed $($hookCounts.Passed), skipped 0"

        Write-VerifyMessage -Message 'verify: restoring the plain release CLI'
        $restoreBuild = Invoke-CapturedProcess -FilePath 'cargo' -Arguments @('build', '--release', '--locked') `
            -WorkingDirectory $repositoryFull -TimeoutSeconds $GateTimeoutSeconds
        $restoreText = Format-GateLog -Command 'cargo build --release --locked' -Result $restoreBuild -Header 'restoring the shipped CLI after the test-hooks build'
        if ($restoreBuild.TimedOut -or $restoreBuild.ExitCode -ne 0) {
            throw "The restoring cargo build --release --locked failed with exit code $($restoreBuild.ExitCode)."
        }
        $restoredCliHash = Get-FileSha256 -Path $CliExecutable
        $restoredBytesText = [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes($CliExecutable))
        if ($restoredBytesText.Contains('TASKS_PRECOMMIT_READY_FILE', [System.StringComparison]::Ordinal)) {
            throw "The restored release CLI at '$CliExecutable' still contains the test-hooks string."
        }
        $restoreDetail = "sha256 $restoredCliHash"
        if ($restoredCliHash -ne $plainCliHash) {
            $restoreDetail += " (the first build hashed $plainCliHash)"
        }
        $restoreLog = Write-GateLog -EvidenceRoot $evidence -Name '08-cargo-build-release-restore.txt' `
            -Text ($restoreText + "`ncli_sha256_after_restore: $restoredCliHash`ncli_sha256_before_test_hooks: $plainCliHash")
        Add-VerifyGate -Gates $gates -Id 'G07' -Name 'shipped CLI restored' -Status 'passed' `
            -Command 'cargo build --release --locked' -Log $restoreLog -Detail $restoreDetail

        Write-VerifyMessage -Message "verify: seeding the pristine end-to-end store in '$e2eFixtureResolved'"
        $e2eFixture = Initialize-ViewerVerifyFixture -FixtureRoot $e2eFixtureResolved -CliExecutable $CliExecutable `
            -Seed $FixtureSeed -AlphaTaskCount $AlphaTaskCount -BetaTaskCount $BetaTaskCount `
            -CommandTimeoutSeconds $FixtureCommandTimeoutSeconds
        $e2eDefine = "TASKS_VIEWER_E2E_FIXTURE=$($e2eFixture.ManifestPath)"
        Write-VerifyMessage -Message 'verify: the end-to-end viewer cases over the real store'
        $e2eResult = Invoke-FlutterCommand -Launcher $launcher `
            -Arguments @('test', 'test/integration/viewer_e2e_headless_test.dart', '--reporter', 'expanded', "--dart-define=$e2eDefine") `
            -WorkingDirectory $viewerFull -TimeoutSeconds $GateTimeoutSeconds
        $e2eLog = Write-GateLog -EvidenceRoot $evidence -Name '09-viewer-e2e-headless.txt' `
            -Text (Format-GateLog -Header "pristine store: $($e2eFixture.Root)`nmanifest: $($e2eFixture.ManifestPath)" `
                -Command "flutter test test/integration/viewer_e2e_headless_test.dart --reporter expanded --dart-define=$e2eDefine" -Result $e2eResult)
        $e2eCounts = Get-FlutterTestCount -Text ($e2eResult.StdOut + "`n" + $e2eResult.StdErr)
        if ($e2eResult.TimedOut -or $e2eResult.ExitCode -ne 0 -or $e2eCounts.Failed -gt 0 -or -not $e2eCounts.Succeeded) {
            throw "The headless end-to-end viewer run failed (+$($e2eCounts.Passed) ~$($e2eCounts.Skipped) -$($e2eCounts.Failed), exit $($e2eResult.ExitCode)); see $e2eLog"
        }
        if ($e2eCounts.Skipped -ne 0 -or $e2eCounts.Passed -lt 5) {
            throw "The headless end-to-end viewer run selected $($e2eCounts.Passed) cases with $($e2eCounts.Skipped) skips; the five seeded cases must all run; see $e2eLog"
        }
        Add-VerifyGate -Gates $gates -Id 'G08' -Name 'viewer end-to-end (headless, real store)' -Status 'passed' `
            -Command "flutter test test/integration/viewer_e2e_headless_test.dart --dart-define=$e2eDefine" -Log $e2eLog `
            -Detail "passed $($e2eCounts.Passed), skipped 0, on a freshly seeded store"

        Write-VerifyMessage -Message 'verify: flutter build windows --release'
        $windowsBuild = Invoke-FlutterCommand -Launcher $launcher -Arguments @('build', 'windows', '--release') `
            -WorkingDirectory $viewerFull -TimeoutSeconds $GateTimeoutSeconds
        $windowsLog = Write-GateLog -EvidenceRoot $evidence -Name '10-build-windows-release.txt' `
            -Text (Format-GateLog -Command 'flutter build windows --release' -Result $windowsBuild)
        if ($windowsBuild.TimedOut -or $windowsBuild.ExitCode -ne 0) {
            throw "flutter build windows --release failed with exit code $($windowsBuild.ExitCode); see $windowsLog"
        }
        $viewerExe = Join-Path -Path $viewerFull -ChildPath 'build/windows/x64/runner/Release/tasks_viewer.exe'
        if (-not (Test-Path -LiteralPath $viewerExe -PathType Leaf)) {
            throw "flutter build windows --release did not produce '$viewerExe'."
        }
        Add-VerifyGate -Gates $gates -Id 'G09' -Name 'Windows release build' -Status 'passed' `
            -Command 'flutter build windows --release' -Log $windowsLog -Detail "sha256 $(Get-FileSha256 -Path $viewerExe)"

        Write-VerifyMessage -Message 'verify: packaging the portable release bundle'
        # package.ps1 declares its own parameters, and dot-sourcing it rebinds
        # those names here: hold on to the values the fixture cleanup needs.
        $fixtureCleanupWorkingRoot = $WorkingRoot
        $fixtureCleanupRepositoryRoot = $repositoryFull
        . $PackageToolPath
        if ($null -eq (Get-Command -Name 'Invoke-PackageTool' -ErrorAction SilentlyContinue)) {
            throw "The packaging tool '$PackageToolPath' does not define Invoke-PackageTool."
        }
        $packageResult = Invoke-PackageTool -ViewerRoot $viewerFull -RepositoryRoot $repositoryFull `
            -CliExecutable $CliExecutable -EvidenceRoot $evidence -WorkingRoot $WorkingRoot
        $packageHash = Assert-BundleHash -BundleRoot $packageResult.OutputRoot
        $packageFindings = @($packageResult.Findings)
        $hashFindings = @($packageHash.Findings)
        foreach ($finding in $packageFindings) {
            $findings.Add("packaging: $finding")
        }
        foreach ($finding in $hashFindings) {
            $findings.Add("bundle hashes: $finding")
        }
        if ($packageResult.CliExeSha256 -ne $restoredCliHash) {
            $findings.Add("The bundled tasks.exe hashes $($packageResult.CliExeSha256) while the shipped release CLI hashes $restoredCliHash.")
        }
        $packageLines = [System.Collections.Generic.List[string]]::new()
        $packageLines.Add("bundle_root: $($packageResult.OutputRoot)")
        $packageLines.Add("file_count: $($packageResult.FileCount)")
        $packageLines.Add("total_bytes: $($packageResult.TotalBytes)")
        $packageLines.Add("clip_count: $($packageResult.ClipCount)")
        $packageLines.Add("clip_bytes: $($packageResult.ClipBytes)")
        $packageLines.Add("viewer_exe_sha256: $($packageResult.ViewerExeSha256)")
        $packageLines.Add("cli_exe_sha256: $($packageResult.CliExeSha256)")
        $packageLines.Add("shipped_cli_sha256: $restoredCliHash")
        $packageLines.Add("source_commit: $($packageResult.SourceCommit)")
        $packageLines.Add("source_dirty: $($packageResult.SourceDirty)")
        if ($null -ne $packageResult.LaunchTest) {
            $packageLines.Add("launch_test_ok: $($packageResult.LaunchTest.Ok)")
            foreach ($case in @($packageResult.LaunchTest.Cases)) {
                $packageLines.Add(("launch_case {0}: exit {1} ok {2}" -f $case.Name, $case.ExitCode, $case.Ok))
            }
        }
        else {
            $packageLines.Add('launch_test: not run')
        }
        $packageLines.Add("hash_entries_verified: $($packageHash.Checked)")
        foreach ($finding in $packageFindings) {
            $packageLines.Add("finding: $finding")
        }
        foreach ($finding in $hashFindings) {
            $packageLines.Add("hash_finding: $finding")
        }
        $packageLog = Write-GateLog -EvidenceRoot $evidence -Name '11-package.txt' -Text ($packageLines -join "`n")
        if (-not $packageResult.Ok -or $hashFindings.Count -gt 0) {
            throw "The packaged bundle has $($packageFindings.Count) finding(s) and $($hashFindings.Count) hash finding(s); see $packageLog"
        }
        Add-VerifyGate -Gates $gates -Id 'G10' -Name 'portable release bundle' -Status 'passed' `
            -Command 'viewer/tool/package.ps1 (with the hash re-check)' -Log $packageLog `
            -Detail "$($packageResult.FileCount) files, $($packageResult.ClipCount) clips, $($packageHash.Checked) hash entries, launch test passed"

        Write-VerifyMessage -Message 'verify: external UI Automation on the packaged Windows release'
        $uiaFixture = Initialize-ViewerVerifyFixture -FixtureRoot $uiaFixtureResolved `
            -CliExecutable (Join-Path -Path $packageResult.OutputRoot -ChildPath 'tasks.exe') `
            -Seed $FixtureSeed -AlphaTaskCount $AlphaTaskCount -BetaTaskCount $BetaTaskCount `
            -CommandTimeoutSeconds $FixtureCommandTimeoutSeconds
        $fixtureManifest = Get-Content -LiteralPath $uiaFixture.ManifestPath -Raw | ConvertFrom-Json
        $uiaCommand = (Get-Command -Name 'pwsh' -ErrorAction Stop).Source
        $uiaArguments = @('-NoProfile', '-File', $UiaProbeToolPath,
            '-BundleRoot', $packageResult.OutputRoot,
            '-DataRoot', $uiaFixtureResolved,
            '-SettingsRoot', $uiaFixture.SettingsRoot,
            '-ExpectedProjectName', [string]$fixtureManifest.projects[0].name,
            '-ExpectedOpenCount', [string]$uiaFixture.AlphaOpen,
            '-ExpectedTotalCount', [string]$uiaFixture.AlphaTotal,
            '-TimeoutSeconds', [string]$UiaTimeoutSeconds)
        $uiaResult = Invoke-CapturedProcess -FilePath $uiaCommand -Arguments $uiaArguments `
            -WorkingDirectory $viewerFull -TimeoutSeconds ($UiaTimeoutSeconds + 15)
        $uiaLog = Write-GateLog -EvidenceRoot $evidence -Name '12-release-uia.txt' `
            -Text (Format-GateLog -Command 'pwsh -NoProfile -File viewer/tool/verify-release-uia.ps1 (packaged release)' -Result $uiaResult)
        if ($uiaResult.TimedOut -or $uiaResult.ExitCode -ne 0) {
            $uiaStatus = 'failed'
            Add-VerifyGate -Gates $gates -Id 'G11' -Name 'packaged release UI Automation' -Status 'failed' `
                -Command 'viewer/tool/verify-release-uia.ps1' -Log $uiaLog -Detail 'External UIA probe failed'
            throw "The packaged release UIA probe failed (exit $($uiaResult.ExitCode)); see $uiaLog"
        }
        $uiaProof = $uiaResult.StdOut | ConvertFrom-Json
        $builtAppImage = Join-Path -Path $viewerFull -ChildPath 'build/windows/x64/runner/Release/data/app.so'
        if (-not $uiaProof.Ok -or $uiaProof.ViewerSha256 -ne $packageResult.ViewerExeSha256 -or
            $uiaProof.CliSha256 -ne $packageResult.CliExeSha256 -or
            $uiaProof.AppSha256 -ne (Get-FileSha256 -Path $builtAppImage)) {
            $uiaStatus = 'failed'
            Add-VerifyGate -Gates $gates -Id 'G11' -Name 'packaged release UI Automation' -Status 'failed' `
                -Command 'viewer/tool/verify-release-uia.ps1' -Log $uiaLog -Detail 'Probe result or packaged hashes disagree'
            throw "The release UIA probe did not verify the packaged candidate hashes and semantics; see $uiaLog"
        }
        $uiaStatus = 'passed'
        Add-VerifyGate -Gates $gates -Id 'G11' -Name 'packaged release UI Automation' -Status 'passed' `
            -Command 'viewer/tool/verify-release-uia.ps1' -Log $uiaLog `
            -Detail "$($uiaProof.NodeCount) native UIA nodes; project region and row exposed; app.so sha256 $($uiaProof.AppSha256)"

        if ($IncludeWindowedIntegration) {
            Write-VerifyMessage -Message 'verify: windowed integration_test/viewer_test.dart -d windows (this opens a real window)'
            $windowedResult = Invoke-FlutterCommand -Launcher $launcher `
                -Arguments @('test', 'integration_test/viewer_test.dart', '-d', 'windows', '--reporter', 'expanded', "--dart-define=$fixtureDefine") `
                -WorkingDirectory $viewerFull -TimeoutSeconds $GateTimeoutSeconds
            $windowedLog = Write-GateLog -EvidenceRoot $evidence -Name '12-windowed-integration.txt' `
                -Text (Format-GateLog -Command "flutter test integration_test/viewer_test.dart -d windows --reporter expanded --dart-define=$fixtureDefine" -Result $windowedResult)
            $windowedCounts = Get-FlutterTestCount -Text ($windowedResult.StdOut + "`n" + $windowedResult.StdErr)
            if ($windowedResult.TimedOut -or $windowedResult.ExitCode -ne 0 -or $windowedCounts.Failed -gt 0 -or -not $windowedCounts.Succeeded) {
                $windowedStatus = 'failed'
                throw "The windowed integration run failed (+$($windowedCounts.Passed) ~$($windowedCounts.Skipped) -$($windowedCounts.Failed), exit $($windowedResult.ExitCode)); see $windowedLog"
            }
            $windowedStatus = 'passed'
            Add-VerifyGate -Gates $gates -Id 'G12' -Name 'windowed integration (opt-in)' -Status 'passed' `
                -Command "flutter test integration_test/viewer_test.dart -d windows --dart-define=$fixtureDefine" -Log $windowedLog `
                -Detail "passed $($windowedCounts.Passed), skipped $($windowedCounts.Skipped); this gate opens a real window and is never part of the default run"
        }
    }
    catch {
        $failure = $_.Exception.Message
    }

    foreach ($rootEntry in @(
            [pscustomobject]@{ Root = $fixtureResolved; Seeded = ($null -ne $fixture) }
            [pscustomobject]@{ Root = $e2eFixtureResolved; Seeded = ($null -ne $e2eFixture) }
            [pscustomobject]@{ Root = $uiaFixtureResolved; Seeded = ($null -ne $uiaFixture) }
        )) {
        if (-not $rootEntry.Seeded) {
            continue
        }
        try {
            $removed = Clear-ViewerVerifyFixture -FixtureRoot $rootEntry.Root -WorkingRoot $fixtureCleanupWorkingRoot `
                -RepositoryRoot $fixtureCleanupRepositoryRoot -Keep:$KeepFixtureRoot
            if (-not $removed) {
                Write-VerifyMessage -Message "verify: keeping the fixture root '$($rootEntry.Root)'"
            }
        }
        catch {
            $findings.Add("The fixture root '$($rootEntry.Root)' could not be removed: $($_.Exception.Message)")
        }
    }
    if ($null -ne $failure) {
        $findings.Insert(0, $failure)
    }

    $commit = $null
    $dirty = $null
    try {
        $commitResult = Invoke-CapturedProcess -FilePath 'git' -Arguments @('-C', $repositoryFull, 'rev-parse', 'HEAD') `
            -WorkingDirectory $repositoryFull -TimeoutSeconds 120
        if ($commitResult.ExitCode -eq 0) {
            $commit = $commitResult.StdOut.Trim()
        }
        $statusResult = Invoke-CapturedProcess -FilePath 'git' -Arguments @('-C', $repositoryFull, 'status', '--porcelain') `
            -WorkingDirectory $repositoryFull -TimeoutSeconds 120
        $dirty = -not [string]::IsNullOrWhiteSpace($statusResult.StdOut)
    }
    catch {
        $dirty = $null
    }

    $viewerExePath = Join-Path -Path $viewerFull -ChildPath 'build/windows/x64/runner/Release/tasks_viewer.exe'
    $viewerExeHash = if (Test-Path -LiteralPath $viewerExePath -PathType Leaf) { Get-FileSha256 -Path $viewerExePath } else { $null }
    $bundleRoot = if ($null -ne $packageResult) { $packageResult.OutputRoot } else { $null }
    $bundleCliHash = if ($null -ne $packageResult) { $packageResult.CliExeSha256 } else { $null }
    $bundleViewerHash = if ($null -ne $packageResult) { $packageResult.ViewerExeSha256 } else { $null }
    $hashEntries = if ($null -ne $packageHash) { $packageHash.Checked } else { 0 }

    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add([pscustomobject]@{ Id = 'V01'; Status = 'unavailable'; Scope = 'Protocol cases belong to the Rust gate set (cargo test --locked, tests/viewer_api.rs); this harness runs no Rust tests.'; Logs = '' })
    $rows.Add([pscustomobject]@{ Id = 'V02'; Status = 'unavailable'; Scope = 'The Rust gate set proves the catalog cases; the viewer catalog slice over the seeded store ran in G08.'; Logs = '09-viewer-e2e-headless.txt' })
    $rows.Add([pscustomobject]@{ Id = 'V03'; Status = 'unavailable'; Scope = 'The Rust and measure gate sets prove the page/filter/sort cases; G08 ran the literal %_ search, the Unicode row and the priority order against the real store.'; Logs = '09-viewer-e2e-headless.txt' })
    $rows.Add([pscustomobject]@{ Id = 'V04'; Status = 'passed'; Scope = 'Editor fields, validation and rollback in the G05 suite; acknowledgement loss against the real CLI in G06; the save plus second-process history proof in G08.'; Logs = '05-flutter-test-full.txt, 07-flutter-test-test-hooks.txt, 09-viewer-e2e-headless.txt' })
    $rows.Add([pscustomobject]@{ Id = 'V05'; Status = 'passed'; Scope = 'Draft and navigation suites in G05: Save/Discard/Cancel per leaving action, restart restore, corrupt settings and write failures, store identity.'; Logs = '05-flutter-test-full.txt' })
    $rows.Add([pscustomobject]@{ Id = 'V06'; Status = 'passed'; Scope = 'Clipboard suites in G05 over the fake clipboard; the real clipboard was never read or written in this run.'; Logs = '05-flutter-test-full.txt' })
    $rows.Add([pscustomobject]@{ Id = 'V07'; Status = 'passed'; Scope = 'Widget, semantics and accessibility suites in G05: control names and roles, focus order and return, disabled reasons, loading announcements, text scaling.'; Logs = '05-flutter-test-full.txt' })
    $rows.Add([pscustomobject]@{ Id = 'V08'; Status = 'unavailable'; Scope = "G08 proves the real-store flow headlessly. Packaged release UIA G11 status: $uiaStatus. The full packaged window workflows remain unverified."; Logs = '09-viewer-e2e-headless.txt, 12-release-uia.txt' })
    $rows.Add([pscustomobject]@{ Id = 'V09'; Status = 'unavailable'; Scope = 'Section 10 timings live in viewer/tool/measure.ps1 and its own evidence root: deterministic release fixtures plus release CLI round trips, with the frame, memory and NVDA rows recorded unavailable. This harness runs no timing gate.'; Logs = '' })
    $rows.Add([pscustomobject]@{ Id = 'V10'; Status = 'unavailable'; Scope = 'Manual NVDA walkthroughs need live speech and a real desktop; never driven in this run by direction.'; Logs = '' })
    $rows.Add([pscustomobject]@{ Id = 'V11'; Status = 'passed'; Scope = 'G05 hotkey suites: F1/F2/F3 focus targets, remembered-list Ctrl+F, scoped access keys, modal isolation, Ctrl+D and Ctrl+E routing, the Hotkey help dialog and its focus return.'; Logs = '05-flutter-test-full.txt' })
    $rows.Add([pscustomobject]@{ Id = 'V12'; Status = 'unavailable'; Scope = 'Startup registration and single-instance classification pass in G05; the real sign-in proof in a disposable account and the monitor/DPI checks need a live session.'; Logs = '05-flutter-test-full.txt' })
    $rows.Add([pscustomobject]@{ Id = 'V13'; Status = 'unavailable'; Scope = 'G05 and G10 prove the catalog, manifest hashes, packaged clips and package rejection offline; audible listening and the real voice provenance need a human and the account.'; Logs = '05-flutter-test-full.txt, 11-package.txt' })

    $ok = ($findings.Count -eq 0)
    $summary = [ordered]@{
        schema_version   = 1
        generated_utc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        viewer_root      = $viewerFull
        repository_root  = $repositoryFull
        source_commit    = $commit
        source_dirty     = $dirty
        evidence_root    = $evidence
        fixture_root     = $fixtureResolved
        e2e_fixture_root = $e2eFixtureResolved
        uia_fixture_root = $uiaFixtureResolved
        fixture_kept     = [bool]$KeepFixtureRoot
        ok               = $ok
        gates            = @($gates)
        counts           = [ordered]@{
            full_suite    = $fullCounts
            test_hooks    = $hookCounts
            e2e_headless  = $e2eCounts
            windowed_run  = $windowedStatus
            release_uia   = $uiaStatus
        }
        artifacts       = [ordered]@{
            shipped_cli_sha256        = $restoredCliHash
            first_build_cli_sha256    = $plainCliHash
            viewer_exe_sha256         = $viewerExeHash
            bundle_root               = $bundleRoot
            bundle_cli_sha256         = $bundleCliHash
            bundle_viewer_exe_sha256  = $bundleViewerHash
            hash_entries_verified     = $hashEntries
        }
        rows            = @($rows)
        findings        = @($findings)
    }
    $summaryPath = Join-Path -Path $evidence -ChildPath 'verify-summary.json'
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8NoBOM

    $markdown = [System.Collections.Generic.List[string]]::new()
    $markdown.Add('# viewer Windows verification - verify-windows.ps1')
    $markdown.Add('')
    $markdown.Add("generated_utc: $($summary.generated_utc)")
    $markdown.Add("repository: $repositoryFull")
    $markdown.Add("source_commit: $commit")
    $markdown.Add("source_dirty: $dirty")
    $markdown.Add("evidence_root: $evidence")
    $markdown.Add("fixture_root: $fixtureResolved (kept: $([bool]$KeepFixtureRoot))")
    $markdown.Add("e2e_fixture_root: $e2eFixtureResolved (the end-to-end gate seeds its own store)")
    $markdown.Add("uia_fixture_root: $uiaFixtureResolved (G11 seeds its own store with the packaged CLI)")
    $markdown.Add('')
    $markdown.Add('Scope: headless Flutter gates plus an external UIA check of one packaged-release')
    $markdown.Add('window on a synthetic store. No keyboard or pointer input, NVDA driving or')
    $markdown.Add('real clipboard access. The UIA gate does not prove NVDA speech.')
    $markdown.Add('')
    $markdown.Add('## Gates')
    $markdown.Add('')
    $markdown.Add('| Id | Gate | Status | Detail | Log |')
    $markdown.Add('| --- | --- | --- | --- | --- |')
    foreach ($gate in $gates) {
        $markdown.Add(("| {0} | {1} | {2} | {3} | {4} |" -f $gate.Id, $gate.Name, $gate.Status, $gate.Detail, (Split-Path -Leaf $gate.Log)))
    }
    $markdown.Add('')
    $markdown.Add('## Counts')
    $markdown.Add('')
    foreach ($pair in @(
            [pscustomobject]@{ Name = 'full suite (shipped CLI)'; Counts = $fullCounts }
            [pscustomobject]@{ Name = 'real CLI editor (test hooks)'; Counts = $hookCounts }
            [pscustomobject]@{ Name = 'viewer end-to-end (headless)'; Counts = $e2eCounts }
        )) {
        if ($null -eq $pair.Counts) {
            $markdown.Add("- $($pair.Name): not run")
        }
        else {
            $markdown.Add("- $($pair.Name): passed $($pair.Counts.Passed), skipped $($pair.Counts.Skipped), failed $($pair.Counts.Failed)")
        }
    }
    $markdown.Add("- windowed integration (-d windows): $windowedStatus")
    $markdown.Add("- packaged release UIA: $uiaStatus (log: $uiaLog)")
    $markdown.Add('')
    $markdown.Add('## Artifacts')
    $markdown.Add('')
    $markdown.Add("- shipped tasks.exe: $restoredCliHash")
    $markdown.Add("- first tasks.exe build: $plainCliHash")
    $markdown.Add("- tasks_viewer.exe: $viewerExeHash")
    $markdown.Add("- bundle: $bundleRoot (cli $bundleCliHash, viewer $bundleViewerHash, $hashEntries hash entries re-checked)")
    $markdown.Add('')
    $markdown.Add('## Required test matrix')
    $markdown.Add('')
    $markdown.Add('| Id | Status | What this run covers | Logs |')
    $markdown.Add('| --- | --- | --- | --- |')
    foreach ($row in $rows) {
        $markdown.Add(("| {0} | {1} | {2} | {3} |" -f $row.Id, $row.Status, $row.Scope, $row.Logs))
    }
    $markdown.Add('')
    $markdown.Add('## Not verified here')
    $markdown.Add('')
    $markdown.Add('- NVDA speech, caret behaviour and real text editing (V10).')
    $markdown.Add('- A real sign-in launch, changed/missing monitors and live DPI (V12).')
    $markdown.Add('- Audible Bella playback on a real device and listening checks (V13).')
    $markdown.Add('- The full packaged window flows (V08); G11 covers only UIA exposure of the initial window.')
    $markdown.Add('- Section 10 performance numbers: run viewer/tool/measure.ps1, which keeps its own evidence root (V09).')
    $markdown.Add('')
    $markdown.Add('## Findings')
    $markdown.Add('')
    if ($findings.Count -eq 0) {
        $markdown.Add('- none')
    }
    else {
        foreach ($finding in $findings) {
            $markdown.Add("- $finding")
        }
    }
    $markdownPath = Join-Path -Path $evidence -ChildPath 'verify-summary.md'
    Set-Content -LiteralPath $markdownPath -Value ($markdown -join "`n") -Encoding utf8NoBOM

    return [pscustomobject]@{
        Ok           = $ok
        Findings     = @($findings)
        EvidenceRoot = $evidence
        SummaryPath  = $summaryPath
        ReportPath   = $markdownPath
        Gates        = @($gates)
        FullCounts   = $fullCounts
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $toolExitCode = 1
    try {
        $toolResult = Invoke-VerifyWindows -ViewerRoot $ViewerRoot -RepositoryRoot $RepositoryRoot `
            -EvidenceRoot $EvidenceRoot -CliExecutable $CliExecutable -FlutterRoot $FlutterRoot `
            -WorkingRoot $WorkingRoot -FixtureRoot $FixtureRoot -PackageToolPath $PackageToolPath `
            -UiaProbeToolPath $UiaProbeToolPath -UiaTimeoutSeconds $UiaTimeoutSeconds `
            -FixtureSeed $FixtureSeed -AlphaTaskCount $AlphaTaskCount -BetaTaskCount $BetaTaskCount `
            -FixtureCommandTimeoutSeconds $FixtureCommandTimeoutSeconds -GateTimeoutSeconds $GateTimeoutSeconds `
            -KeepFixtureRoot:$KeepFixtureRoot -IncludeWindowedIntegration:$IncludeWindowedIntegration
        foreach ($finding in $toolResult.Findings) {
            Write-VerifyMessage -Message "verify: $finding"
        }
        foreach ($gate in $toolResult.Gates) {
            Write-VerifyMessage -Message ("verify: {0} {1} - {2}" -f $gate.Id, $gate.Status, $gate.Name)
        }
        Write-VerifyMessage -Message "verify: summary '$($toolResult.ReportPath)'"
        if ($toolResult.Ok) {
            Write-VerifyMessage -Message ("verify: OK - {0} gates, {1} evidence root" -f $toolResult.Gates.Count, $toolResult.EvidenceRoot)
            $toolExitCode = 0
        }
        else {
            Write-VerifyMessage -Message "verify: FAILED - $($toolResult.Findings.Count) problem(s)"
        }
    }
    catch {
        Write-VerifyMessage -Message "error: $($_.Exception.Message)"
        $toolExitCode = 1
    }

    exit $toolExitCode
}
