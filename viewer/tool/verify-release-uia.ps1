#requires -Version 7.0
<#
.SYNOPSIS
Checks native accessibility of the packaged Windows release through UIA or MSAA.

.DESCRIPTION
Launches one packaged viewer against an isolated synthetic store and settings
root. Reads UIA with an MSAA fallback through Windows client APIs; sends no keyboard or pointer
input and never inspects another process's window. The caller owns the store.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundleRoot,
    [Parameter(Mandatory)][string]$DataRoot,
    [Parameter(Mandatory)][string]$SettingsRoot,
    [Parameter(Mandatory)][string]$ExpectedProjectName,
    [int]$ExpectedOpenCount = 27,
    [int]$ExpectedTotalCount = 28,
    [int]$TimeoutSeconds = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ReleaseUiaNode {
    param(
        [Parameter(Mandatory)][System.Windows.Automation.AutomationElement]$Window,
        [int]$MaxNodes = 600,
        [int]$MaxDepth = 24
    )

    $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ Element = $Window; Depth = 0 })
    $nodes = [System.Collections.Generic.List[object]]::new()
    while ($queue.Count -gt 0 -and $nodes.Count -lt $MaxNodes) {
        $entry = $queue.Dequeue()
        try {
            $current = $entry.Element.Current
            $nodes.Add([pscustomobject]@{
                    Name = [string]$current.Name
                    Type = [string]$current.ControlType.ProgrammaticName
                    AutomationId = [string]$current.AutomationId
                    IsEnabled = [bool]$current.IsEnabled
                    Depth = [int]$entry.Depth
                })
            if ($entry.Depth -ge $MaxDepth) { continue }
            $child = $walker.GetFirstChild($entry.Element)
            while ($null -ne $child -and ($queue.Count + $nodes.Count) -lt $MaxNodes) {
                $queue.Enqueue([pscustomobject]@{ Element = $child; Depth = $entry.Depth + 1 })
                $child = $walker.GetNextSibling($child)
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
            continue
        }
    }
    return @($nodes)
}

function Initialize-ReleaseMsaa {
    if ('ReleaseMsaa' -as [type]) { return }
    Add-Type -AssemblyName Accessibility
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ReleaseMsaa {
    [DllImport("oleacc.dll")]
    public static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint id, ref Guid iid,
        [MarshalAs(UnmanagedType.Interface)] out object result);
    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hwnd, uint command);
}
"@
}

function Get-ReleaseMsaaNode {
    param([Parameter(Mandatory)][intptr]$WindowHandle, [switch]$IncludeElement)
    Initialize-ReleaseMsaa
    $childWindow = [ReleaseMsaa]::GetWindow($WindowHandle, 5)
    if ($childWindow -eq [intptr]::Zero) { return }
    $iid = [guid]'618736e0-3c3d-11cf-810c-00aa00389b71'
    $accessible = $null
    $hr = [ReleaseMsaa]::AccessibleObjectFromWindow($childWindow, [uint32]4294967292,
        [ref]$iid, [ref]$accessible)
    if ($hr -ne 0 -or $null -eq $accessible) { return }
    $queue = [collections.generic.queue[object]]::new()
    $queue.Enqueue(@{ Element = $accessible; Child = 0; Depth = 0 })
    $visited = 0
    while ($queue.Count -gt 0 -and $visited -lt 600) {
        $entry = $queue.Dequeue()
        $visited++
        $element = $entry.Element
        # Flutter's native root can reject accName while its children are valid.
        try {
            $name = [string]$element.accName($entry.Child)
            $role = [int]$element.accRole($entry.Child)
            $type = switch ($role) {
                18 { 'ControlType.Dialog' }
                20 { 'ControlType.Custom' }
                41 { 'ControlType.Text' }
                42 { 'ControlType.Edit' }
                43 { 'ControlType.Button' }
                46 { 'ControlType.ComboBox' }
                51 { 'ControlType.Slider' }
                default { "MSAA.Role.$role" }
            }
            $node = [pscustomobject]@{
                Name = $name; Type = $type; NativeRole = $role; Depth = $entry.Depth
            }
            if ($IncludeElement) {
                $node | Add-Member -NotePropertyName Element -NotePropertyValue $element
                $node | Add-Member -NotePropertyName Child -NotePropertyValue $entry.Child
            }
            $node
        }
        catch { Write-Verbose "MSAA name/role unavailable at depth $($entry.Depth): $($_.Exception.Message)" }
        if ($entry.Child -ne 0 -or $entry.Depth -ge 24) { continue }
        try { $count = [int]$element.accChildCount } catch { continue }
        for ($i = 1; $i -le $count -and ($visited + $queue.Count) -lt 600; $i++) {
            try { $child = $element.accChild($i) } catch { $child = $null }
            if ($null -ne $child) {
                $queue.Enqueue(@{ Element = $child; Child = 0; Depth = $entry.Depth + 1 })
            }
            else {
                $queue.Enqueue(@{ Element = $element; Child = $i; Depth = $entry.Depth + 1 })
            }
        }
    }
}

function Find-ReleaseUiaElement {
    param(
        [Parameter(Mandatory)][System.Windows.Automation.AutomationElement]$Window,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Windows.Automation.ControlType]$ControlType
    )

    $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ Element = $Window; Depth = 0 })
    while ($queue.Count -gt 0) {
        $entry = $queue.Dequeue()
        try {
            $current = $entry.Element.Current
            if ($current.Name -like $Name -and $current.ControlType -eq $ControlType) {
                return $entry.Element
            }
            if ($entry.Depth -ge 24) { continue }
            $child = $walker.GetFirstChild($entry.Element)
            while ($null -ne $child) {
                $queue.Enqueue([pscustomobject]@{ Element = $child; Depth = $entry.Depth + 1 })
                $child = $walker.GetNextSibling($child)
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
            continue
        }
    }
    return $null
}

function Test-ReleaseUiaSettingsSnapshot {
    param([Parameter(Mandatory)][object[]]$Nodes)

    $required = @(
        @{ Name = 'Settings'; Types = @('ControlType.Dialog', 'ControlType.Custom') },
        @{ Name = 'Tasks CLI path (Alt+E)'; Types = @('ControlType.Edit') },
        @{ Name = 'Data root (Alt+D)'; Types = @('ControlType.Edit') },
        @{ Name = 'Theme (Alt+H)*'; Types = @('ControlType.ComboBox', 'ControlType.Button') },
        @{ Name = 'Text size (Alt+Z)*'; Types = @('ControlType.ComboBox', 'ControlType.Button') },
        @{ Name = 'Bella volume (Alt+V)'; Types = @('ControlType.Slider') },
        @{ Name = 'Cancel (Alt+C)'; Types = @('ControlType.Button') },
        @{ Name = 'Save (Ctrl+S)'; Types = @('ControlType.Button') }
    )
    $findings = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $required) {
        if (@($Nodes | Where-Object { $_.Name -like $item.Name -and $_.Type -in $item.Types }).Count -eq 0) {
            $findings.Add("Settings did not expose '$($item.Name)' as $($item.Types -join ' or ').")
        }
    }
    return [pscustomobject]@{ Ok = $findings.Count -eq 0; Findings = @($findings) }
}

function Test-ReleaseUiaSnapshot {
    param(
        [Parameter(Mandatory)][object[]]$Nodes,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][int]$OpenCount,
        [Parameter(Mandatory)][int]$TotalCount
    )

    $list = @($Nodes | Where-Object { $_.Name -eq 'Projects' -and $_.Type -eq 'ControlType.Custom' })
    $search = @($Nodes | Where-Object { $_.Name -eq 'Search projects (Ctrl+F)' -and $_.Type -eq 'ControlType.Edit' })
    $sort = @($Nodes | Where-Object { $_.Name -like 'Sort (Alt+O)*' -and $_.Type -eq 'ControlType.Button' })
    $row = @($Nodes | Where-Object {
            $_.Name -like "$([System.Management.Automation.WildcardPattern]::Escape($ProjectName)).*" -and
            $_.Name -like "*$OpenCount open, $TotalCount total*"
        })
    $findings = [System.Collections.Generic.List[string]]::new()
    if ($list.Count -eq 0) { $findings.Add('No named Projects region appeared with the expected UIA role.') }
    if ($search.Count -eq 0) { $findings.Add('Search projects was not exposed as a named UIA Edit control.') }
    if ($sort.Count -eq 0) { $findings.Add('Sort was not exposed as a named UIA Button.') }
    if ($row.Count -eq 0) {
        $findings.Add("No project row exposed '$ProjectName' with $OpenCount open and $TotalCount total in its UIA name.")
    }
    return [pscustomobject]@{
        Ok = $findings.Count -eq 0
        Findings = @($findings)
        ProjectsRegions = $list.Count
        SearchEdits = $search.Count
        SortButtons = $sort.Count
        MatchingRows = $row.Count
    }
}

function Test-ReleaseUiaBareFlutterViewSnapshot {
    <#
    .SYNOPSIS
    True when a snapshot is exactly the OS's own default MSAA object for the
    FLUTTERVIEW child window, not anything Flutter's accessibility bridge
    produced.

    .DESCRIPTION
    A 2026-09-30 run (HEAD 47ab4f5) timed out after 45 s with a snapshot of
    exactly one node: Name "FLUTTERVIEW" (the raw win32 class name, which
    Windows uses as a fallback display name when nothing set a real
    accessible name) and a generic "MSAA.Role.<n>" type (the synthesized
    label `Get-ReleaseMsaaNode` uses for any MSAA role it doesn't recognize
    as one of Flutter's own control roles). That combination only appears
    when Windows answered the query with its own default accessible object
    for the window instead of Flutter's, i.e. the accessibility bridge had
    not attached at all. Flutter's own nodes never carry this signature: a
    working run's single nodes (if any existed) would have a recognized
    ControlType/role or non-default content.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Nodes)

    if ($Nodes.Count -ne 1) { return $false }
    $node = $Nodes[0]
    return ($node.Name -eq 'FLUTTERVIEW') -and ([string]$node.Type).StartsWith('MSAA.Role.', [System.StringComparison]::Ordinal)
}

function Invoke-ReleaseUiaAttempt {
    <#
    .SYNOPSIS
    Launches one packaged viewer and runs the timed UIA/MSAA wait loop once.
    Never throws: returns a result object whose Ok flag and Findings/Nodes
    describe either the successful snapshot or why the attempt failed, so
    the caller can decide whether a bare-FLUTTERVIEW timeout deserves one
    retry.
    #>
    param(
        [Parameter(Mandatory)][string]$ViewerExe,
        [Parameter(Mandatory)][string]$BundleFull,
        [Parameter(Mandatory)][string]$CliExe,
        [Parameter(Mandatory)][string]$DataRootFull,
        [Parameter(Mandatory)][string]$SettingsRootFull,
        [Parameter(Mandatory)][string]$ExpectedProjectName,
        [Parameter(Mandatory)][int]$ExpectedOpenCount,
        [Parameter(Mandatory)][int]$ExpectedTotalCount,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ViewerExe
    $startInfo.WorkingDirectory = $BundleFull
    $startInfo.UseShellExecute = $false
    foreach ($argument in @('--test-mode', '--data-root', $DataRootFull,
            '--tasks-exe', $CliExe, '--settings-root', $SettingsRootFull)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
        $lastNodes = @()
        $lastCheck = $null
        $windowName = $null
        do {
            if ($process.HasExited) {
                return [pscustomobject]@{
                    Ok = $false
                    Reason = "The packaged viewer exited before the UIA tree was ready (exit $($process.ExitCode))."
                    Nodes = @()
                    NodeCount = 0
                    ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
                    Backend = $null
                    WindowName = $null
                    SettingsChecks = $null
                    SettingsNodes = @()
                    ProcessId = $process.Id
                }
            }
            $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
                [System.Windows.Automation.TreeScope]::Children, $condition)
            for ($i = 0; $i -lt $windows.Count; $i++) {
                $window = $windows.Item($i)
                if ($window.Current.ControlType -ne [System.Windows.Automation.ControlType]::Window) { continue }
                $windowName = $window.Current.Name
                $lastNodes = @(Get-ReleaseUiaNode -Window $window)
                $lastCheck = Test-ReleaseUiaSnapshot -Nodes $lastNodes -ProjectName $ExpectedProjectName `
                    -OpenCount $ExpectedOpenCount -TotalCount $ExpectedTotalCount
                $backend = 'UIA'
                if (-not $lastCheck.Ok) {
                    $lastNodes = @(Get-ReleaseMsaaNode -WindowHandle $window.Current.NativeWindowHandle)
                    if ($lastNodes.Count -eq 0) { continue }
                    $lastCheck = Test-ReleaseUiaSnapshot -Nodes $lastNodes -ProjectName $ExpectedProjectName `
                        -OpenCount $ExpectedOpenCount -TotalCount $ExpectedTotalCount
                    $backend = 'MSAA'
                }
                if ($lastCheck.Ok) {
                    if ($backend -eq 'MSAA') {
                        $settingsButton = @(Get-ReleaseMsaaNode -WindowHandle $window.Current.NativeWindowHandle -IncludeElement |
                            Where-Object { $_.Name -like 'Settings*' -and $_.Type -eq 'ControlType.Button' })
                        if ($settingsButton.Count -ne 1) {
                            return [pscustomobject]@{
                                Ok = $false
                                Reason = 'Expected exactly one accessible Settings button.'
                                Nodes = $lastNodes
                                NodeCount = $lastNodes.Count
                                ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
                                Backend = $backend
                                WindowName = $windowName
                                SettingsChecks = $null
                                SettingsNodes = @()
                                ProcessId = $process.Id
                            }
                        }
                        $settingsButton[0].Element.accDoDefaultAction($settingsButton[0].Child)
                    }
                    else {
                        $settingsButton = Find-ReleaseUiaElement -Window $window -Name 'Settings*' `
                            -ControlType ([System.Windows.Automation.ControlType]::Button)
                        if ($null -eq $settingsButton) {
                            return [pscustomobject]@{
                                Ok = $false
                                Reason = 'Settings is absent from the packaged release UIA tree.'
                                Nodes = $lastNodes
                                NodeCount = $lastNodes.Count
                                ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
                                Backend = $backend
                                WindowName = $windowName
                                SettingsChecks = $null
                                SettingsNodes = @()
                                ProcessId = $process.Id
                            }
                        }
                        $invoke = $settingsButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                        if ($null -eq $invoke) {
                            return [pscustomobject]@{
                                Ok = $false
                                Reason = 'Settings has no native UIA Invoke action.'
                                Nodes = $lastNodes
                                NodeCount = $lastNodes.Count
                                ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
                                Backend = $backend
                                WindowName = $windowName
                                SettingsChecks = $null
                                SettingsNodes = @()
                                ProcessId = $process.Id
                            }
                        }
                        $invoke.Invoke()
                    }
                    $settingsCheck = $null
                    $settingsNodes = @()
                    do {
                        if ($process.HasExited) {
                            return [pscustomobject]@{
                                Ok = $false
                                Reason = 'The packaged viewer exited while opening Settings.'
                                Nodes = $lastNodes
                                NodeCount = $lastNodes.Count
                                ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
                                Backend = $backend
                                WindowName = $windowName
                                SettingsChecks = $null
                                SettingsNodes = @()
                                ProcessId = $process.Id
                            }
                        }
                        $settingsNodes = if ($backend -eq 'MSAA') {
                            @(Get-ReleaseMsaaNode -WindowHandle $window.Current.NativeWindowHandle)
                        } else { @(Get-ReleaseUiaNode -Window $window) }
                        $settingsCheck = Test-ReleaseUiaSettingsSnapshot -Nodes $settingsNodes
                        if ($settingsCheck.Ok) { break }
                        Start-Sleep -Milliseconds 200
                    } while ([datetime]::UtcNow -lt $deadline)
                    if (-not $settingsCheck.Ok) {
                        return [pscustomobject]@{
                            Ok = $false
                            Reason = "Settings was not accessible through $backend`: $($settingsCheck.Findings -join ' ')"
                            Nodes = $lastNodes
                            NodeCount = $lastNodes.Count
                            ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
                            Backend = $backend
                            WindowName = $windowName
                            SettingsChecks = $settingsCheck
                            SettingsNodes = $settingsNodes
                            ProcessId = $process.Id
                        }
                    }
                    return [pscustomobject]@{
                        Ok = $true
                        Reason = $null
                        Nodes = $lastNodes
                        NodeCount = $lastNodes.Count
                        ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
                        Backend = $backend
                        WindowName = $windowName
                        Checks = $lastCheck
                        SettingsChecks = $settingsCheck
                        SettingsNodes = $settingsNodes
                        ProcessId = $process.Id
                    }
                }
            }
            Start-Sleep -Milliseconds 300
        } while ([datetime]::UtcNow -lt $deadline)

        $reason = if ($null -eq $lastCheck) { 'No window owned by the launched process appeared in UIA.' }
        else { $lastCheck.Findings -join ' ' }
        return [pscustomobject]@{
            Ok = $false
            Reason = "Release UIA check timed out after $TimeoutSeconds s. $reason"
            Nodes = $lastNodes
            NodeCount = $lastNodes.Count
            ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            Backend = $null
            WindowName = $windowName
            SettingsChecks = $null
            SettingsNodes = @()
            ProcessId = $process.Id
            TimedOut = $true
        }
    }
    finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
            if (-not $process.WaitForExit(10000)) {
                throw "The probe could not stop its own packaged viewer process $($process.Id)."
            }
        }
        $process.Dispose()
    }
}

function Invoke-ReleaseUiaProbe {
    <#
    .DESCRIPTION
    Runs one timed attempt against the packaged viewer. A 2026-09-30 run
    (HEAD 47ab4f5) timed out after 45 s with the OS's own default
    FLUTTERVIEW MSAA object (see Test-ReleaseUiaBareFlutterViewSnapshot);
    the identical exe hash re-ran cleanly moments later. When, and only
    when, a timed-out attempt ends on that exact bare-default signature,
    this relaunches the packaged viewer and runs one more timed attempt
    before failing; any other failure (a real content mismatch, a crash, a
    Settings defect) fails on the first attempt with no retry. The first
    attempt's own snapshot, node count and elapsed time are always kept in
    the result so a retry is visible rather than silently swallowed.
    #>
    param(
        [Parameter(Mandatory)][string]$BundleRoot,
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$SettingsRoot,
        [Parameter(Mandatory)][string]$ExpectedProjectName,
        [int]$ExpectedOpenCount = 27,
        [int]$ExpectedTotalCount = 28,
        [int]$TimeoutSeconds = 45,
        # Test seam only: real callers never pass this. It lets Pester stub
        # the timed launch-and-wait attempt so the retry-on-bare-FLUTTERVIEW
        # decision can be unit-tested without opening a real window.
        [scriptblock]$AttemptFunction = (Get-Item Function:\Invoke-ReleaseUiaAttempt).ScriptBlock
    )

    if (-not $IsWindows) { throw 'The release UIA gate requires Windows.' }
    if ($TimeoutSeconds -lt 1) { throw 'TimeoutSeconds must be positive.' }
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $bundleFull = [System.IO.Path]::GetFullPath($BundleRoot)
    $viewerExe = Join-Path $bundleFull 'tasks_viewer.exe'
    $cliExe = Join-Path $bundleFull 'tasks.exe'
    $appImage = Join-Path $bundleFull 'data/app.so'
    foreach ($path in @($viewerExe, $cliExe, $appImage)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "The packaged executable '$path' is missing." }
    }
    if (-not (Test-Path -LiteralPath $DataRoot -PathType Container)) { throw "The synthetic store '$DataRoot' is missing." }
    if (-not (Test-Path -LiteralPath $SettingsRoot -PathType Container)) { throw "The isolated settings root '$SettingsRoot' is missing." }

    $viewerHash = (Get-FileHash -LiteralPath $viewerExe -Algorithm SHA256).Hash.ToLowerInvariant()
    $cliHash = (Get-FileHash -LiteralPath $cliExe -Algorithm SHA256).Hash.ToLowerInvariant()
    $appHash = (Get-FileHash -LiteralPath $appImage -Algorithm SHA256).Hash.ToLowerInvariant()
    $dataRootFull = [System.IO.Path]::GetFullPath($DataRoot)
    $settingsRootFull = [System.IO.Path]::GetFullPath($SettingsRoot)

    $attemptArgs = @{
        ViewerExe = $viewerExe
        BundleFull = $bundleFull
        CliExe = $cliExe
        DataRootFull = $dataRootFull
        SettingsRootFull = $settingsRootFull
        ExpectedProjectName = $ExpectedProjectName
        ExpectedOpenCount = $ExpectedOpenCount
        ExpectedTotalCount = $ExpectedTotalCount
        TimeoutSeconds = $TimeoutSeconds
    }

    [Console]::Error.WriteLine("UIA attempt 1 starting; timeout ${TimeoutSeconds}s; session $([System.Diagnostics.Process]::GetCurrentProcess().SessionId).")
    $first = & $AttemptFunction @attemptArgs
    [Console]::Error.WriteLine("UIA attempt 1 finished: ok=$($first.Ok), nodes=$($first.NodeCount), elapsed=$($first.ElapsedSeconds)s, reason=$($first.Reason)")
    $attempt = $first
    $retried = $false
    if (-not $first.Ok -and $first.TimedOut -and (Test-ReleaseUiaBareFlutterViewSnapshot -Nodes $first.Nodes)) {
        $retried = $true
        [Console]::Error.WriteLine('UIA attempt 2 starting after the bare-FLUTTERVIEW startup signature.')
        $attempt = & $AttemptFunction @attemptArgs
        [Console]::Error.WriteLine("UIA attempt 2 finished: ok=$($attempt.Ok), nodes=$($attempt.NodeCount), elapsed=$($attempt.ElapsedSeconds)s, reason=$($attempt.Reason)")
    }

    if ($attempt.Ok) {
        return [pscustomobject]@{
            Ok = $true
            AccessibilityBackend = $attempt.Backend
            ViewerExe = $viewerExe
            ViewerSha256 = $viewerHash
            CliSha256 = $cliHash
            AppSha256 = $appHash
            ProcessId = $attempt.ProcessId
            WindowName = $attempt.WindowName
            NodeCount = $attempt.NodeCount
            Checks = $attempt.Checks
            Nodes = $attempt.Nodes
            SettingsChecks = $attempt.SettingsChecks
            SettingsNodes = $attempt.SettingsNodes
            Retried = $retried
            FirstAttempt = if ($retried) {
                [pscustomobject]@{
                    Ok = $first.Ok; Reason = $first.Reason; NodeCount = $first.NodeCount
                    ElapsedSeconds = $first.ElapsedSeconds; Backend = $first.Backend; Nodes = $first.Nodes
                }
            } else { $null }
        }
    }

    $sample = ($attempt.Nodes | Select-Object -First 30 | ConvertTo-Json -Compress -Depth 3)
    $retryNote = if ($retried) {
        $firstSample = ($first.Nodes | Select-Object -First 30 | ConvertTo-Json -Compress -Depth 3)
        "Retried once after a bare FLUTTERVIEW snapshot (first attempt: $($first.Reason) elapsed $($first.ElapsedSeconds)s, $($first.NodeCount) nodes: $firstSample)."
    }
    else { 'Not retried: the failure was not a bare FLUTTERVIEW snapshot.' }
    throw "$($attempt.Reason) Bundle: $bundleFull. app.so sha256: $appHash; viewer sha256: $viewerHash; CLI sha256: $cliHash. $retryNote Final snapshot had $($attempt.NodeCount) nodes: $sample"
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-ReleaseUiaProbe -BundleRoot $BundleRoot -DataRoot $DataRoot -SettingsRoot $SettingsRoot `
            -ExpectedProjectName $ExpectedProjectName -ExpectedOpenCount $ExpectedOpenCount `
            -ExpectedTotalCount $ExpectedTotalCount -TimeoutSeconds $TimeoutSeconds
        $result | ConvertTo-Json -Depth 6
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}
