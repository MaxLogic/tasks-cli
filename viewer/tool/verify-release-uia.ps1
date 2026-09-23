#requires -Version 7.0
<#
.SYNOPSIS
Checks the external UI Automation tree of the packaged Windows release.

.DESCRIPTION
Launches one packaged viewer against an isolated synthetic store and settings
root. Reads UIA through the Windows client API; sends no keyboard or pointer
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
        [int]$MaxDepth = 12
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
            $_.Name -like "$ProjectName.*" -and
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

function Invoke-ReleaseUiaProbe {
    param(
        [Parameter(Mandatory)][string]$BundleRoot,
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$SettingsRoot,
        [Parameter(Mandatory)][string]$ExpectedProjectName,
        [int]$ExpectedOpenCount = 27,
        [int]$ExpectedTotalCount = 28,
        [int]$TimeoutSeconds = 45
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
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $viewerExe
    $startInfo.WorkingDirectory = $bundleFull
    $startInfo.UseShellExecute = $false
    foreach ($argument in @('--test-mode', '--data-root', [System.IO.Path]::GetFullPath($DataRoot),
            '--tasks-exe', $cliExe, '--settings-root', [System.IO.Path]::GetFullPath($SettingsRoot))) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
        $lastNodes = @()
        $lastCheck = $null
        do {
            if ($process.HasExited) { throw "The packaged viewer exited before the UIA tree was ready (exit $($process.ExitCode))." }
            $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
                [System.Windows.Automation.TreeScope]::Children, $condition)
            for ($i = 0; $i -lt $windows.Count; $i++) {
                $window = $windows.Item($i)
                if ($window.Current.ControlType -ne [System.Windows.Automation.ControlType]::Window) { continue }
                $lastNodes = @(Get-ReleaseUiaNode -Window $window)
                $lastCheck = Test-ReleaseUiaSnapshot -Nodes $lastNodes -ProjectName $ExpectedProjectName `
                    -OpenCount $ExpectedOpenCount -TotalCount $ExpectedTotalCount
                if ($lastCheck.Ok) {
                    return [pscustomobject]@{
                        Ok = $true
                        ViewerExe = $viewerExe
                        ViewerSha256 = $viewerHash
                        CliSha256 = $cliHash
                        AppSha256 = $appHash
                        ProcessId = $process.Id
                        WindowName = $window.Current.Name
                        NodeCount = $lastNodes.Count
                        Checks = $lastCheck
                        Nodes = $lastNodes
                    }
                }
            }
            Start-Sleep -Milliseconds 300
        } while ([datetime]::UtcNow -lt $deadline)

        $reason = if ($null -eq $lastCheck) { 'No window owned by the launched process appeared in UIA.' }
        else { $lastCheck.Findings -join ' ' }
        $sample = ($lastNodes | Select-Object -First 30 | ConvertTo-Json -Compress -Depth 3)
        throw "Release UIA check timed out after $TimeoutSeconds s. Bundle: $bundleFull. app.so sha256: $appHash; viewer sha256: $viewerHash; CLI sha256: $cliHash. $reason Last snapshot had $($lastNodes.Count) nodes: $sample"
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
