#requires -Version 7.0
<#
.SYNOPSIS
Checks the release UIA probe's fail-closed snapshot assertions without opening a window.
#>
[CmdletBinding()]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot '../verify-release-uia.ps1') `
        -BundleRoot 'unused' -DataRoot 'unused' -SettingsRoot 'unused' -ExpectedProjectName 'alpha'

    # A minimal on-disk bundle so Invoke-ReleaseUiaProbe's pre-flight file
    # checks pass without ever launching a real window; the retry-decision
    # tests stub AttemptFunction instead of touching these files' content.
    $script:DummyRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("release-uia-tests-{0}" -f ([guid]::NewGuid().ToString('n').Substring(0, 8)))
    $script:BundleRoot = Join-Path $script:DummyRoot 'bundle'
    $script:DataRoot = Join-Path $script:DummyRoot 'data-root'
    $script:SettingsRoot = Join-Path $script:DummyRoot 'settings-root'
    New-Item -ItemType Directory -Force -Path (Join-Path $script:BundleRoot 'data') | Out-Null
    New-Item -ItemType Directory -Force -Path $script:DataRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $script:SettingsRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $script:BundleRoot 'tasks_viewer.exe') -Value 'stub' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $script:BundleRoot 'tasks.exe') -Value 'stub' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $script:BundleRoot 'data/app.so') -Value 'stub' -Encoding utf8NoBOM
}

AfterAll {
    if ($null -ne $script:DummyRoot -and (Test-Path -LiteralPath $script:DummyRoot)) {
        Remove-Item -LiteralPath $script:DummyRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'packaged release UIA snapshot' {
    It 'accepts a named region and a seeded project row' {
        $nodes = @(
            [pscustomobject]@{ Name = 'Tasks Viewer'; Type = 'ControlType.Window' }
            [pscustomobject]@{ Name = 'Projects'; Type = 'ControlType.Custom' }
            [pscustomobject]@{ Name = 'Search projects (Ctrl+F)'; Type = 'ControlType.Edit' }
            [pscustomobject]@{ Name = "Sort (Alt+O)`r`nName"; Type = 'ControlType.Button' }
            [pscustomobject]@{ Name = 'alpha. 27 open, 28 total, 0 blocked.'; Type = 'ControlType.ListItem' }
        )
        $result = Test-ReleaseUiaSnapshot -Nodes $nodes -ProjectName 'alpha' -OpenCount 27 -TotalCount 28
        $result.Ok | Should -BeTrue
        $result.ProjectsRegions | Should -Be 1
        $result.SearchEdits | Should -Be 1
        $result.SortButtons | Should -Be 1
        $result.MatchingRows | Should -Be 1
    }

    It 'accepts a keyed project row (name (KEY))' {
        $nodes = @(
            [pscustomobject]@{ Name = 'Tasks Viewer'; Type = 'ControlType.Window' }
            [pscustomobject]@{ Name = 'Projects'; Type = 'ControlType.Custom' }
            [pscustomobject]@{ Name = 'Search projects (Ctrl+F)'; Type = 'ControlType.Edit' }
            [pscustomobject]@{ Name = "Sort (Alt+O)`r`nName"; Type = 'ControlType.Button' }
            [pscustomobject]@{ Name = 'alpha (ALPHA). 27 open, 28 total, 0 blocked.'; Type = 'ControlType.ListItem' }
        )
        $result = Test-ReleaseUiaSnapshot -Nodes $nodes -ProjectName 'alpha (ALPHA)' -OpenCount 27 -TotalCount 28
        $result.Ok | Should -BeTrue
        $result.MatchingRows | Should -Be 1
    }

    It 'accepts a project row whose key contains wildcard bracket characters' {
        $nodes = @(
            [pscustomobject]@{ Name = 'Tasks Viewer'; Type = 'ControlType.Window' }
            [pscustomobject]@{ Name = 'Projects'; Type = 'ControlType.Custom' }
            [pscustomobject]@{ Name = 'Search projects (Ctrl+F)'; Type = 'ControlType.Edit' }
            [pscustomobject]@{ Name = "Sort (Alt+O)`r`nName"; Type = 'ControlType.Button' }
            [pscustomobject]@{ Name = 'alpha[1] (A[1]). 27 open, 28 total, 0 blocked.'; Type = 'ControlType.ListItem' }
        )
        $result = Test-ReleaseUiaSnapshot -Nodes $nodes -ProjectName 'alpha[1] (A[1])' -OpenCount 27 -TotalCount 28
        $result.Ok | Should -BeTrue
        $result.MatchingRows | Should -Be 1
    }

    It 'rejects a native window with no Flutter controls' {
        $nodes = @(
            [pscustomobject]@{ Name = 'Tasks Viewer'; Type = 'ControlType.Window' }
            [pscustomobject]@{ Name = 'FLUTTERVIEW'; Type = 'ControlType.Pane' }
        )
        $result = Test-ReleaseUiaSnapshot -Nodes $nodes -ProjectName 'alpha' -OpenCount 27 -TotalCount 28
        $result.Ok | Should -BeFalse
        @($result.Findings).Count | Should -Be 4
    }

    It 'rejects a project row with stale or absent accessible counts' {
        $nodes = @(
            [pscustomobject]@{ Name = 'Projects'; Type = 'ControlType.Custom' }
            [pscustomobject]@{ Name = 'Search projects (Ctrl+F)'; Type = 'ControlType.Edit' }
            [pscustomobject]@{ Name = 'Sort (Alt+O)'; Type = 'ControlType.Button' }
            [pscustomobject]@{ Name = 'alpha. 28 open, 28 total'; Type = 'ControlType.ListItem' }
        )
        $result = Test-ReleaseUiaSnapshot -Nodes $nodes -ProjectName 'alpha' -OpenCount 27 -TotalCount 28
        $result.Ok | Should -BeFalse
        $result.MatchingRows | Should -Be 0
    }
}

Describe 'packaged release Settings UIA snapshot' {
    It 'requires a named dialog and its first interactive controls' {
        $nodes = @(
            [pscustomobject]@{ Name = 'Settings'; Type = 'ControlType.Dialog' }
            [pscustomobject]@{ Name = 'Tasks CLI path (Alt+E)'; Type = 'ControlType.Edit' }
            [pscustomobject]@{ Name = 'Data root (Alt+D)'; Type = 'ControlType.Edit' }
            [pscustomobject]@{ Name = 'Theme (Alt+H)'; Type = 'ControlType.ComboBox' }
            [pscustomobject]@{ Name = 'Text size (Alt+Z)'; Type = 'ControlType.ComboBox' }
            [pscustomobject]@{ Name = 'Bella volume (Alt+V)'; Type = 'ControlType.Slider' }
            [pscustomobject]@{ Name = 'Cancel (Alt+C)'; Type = 'ControlType.Button' }
            [pscustomobject]@{ Name = 'Save (Ctrl+S)'; Type = 'ControlType.Button' }
        )
        (Test-ReleaseUiaSettingsSnapshot -Nodes $nodes).Ok | Should -BeTrue
        (Test-ReleaseUiaSettingsSnapshot -Nodes @($nodes | Where-Object Name -ne 'Theme (Alt+H)')).Ok | Should -BeFalse
    }

    It 'accepts the native Flutter MSAA roles and dropdown values' {
        $nodes = @(
            [pscustomobject]@{ Name = 'Settings'; Type = 'ControlType.Custom' }
            [pscustomobject]@{ Name = 'Tasks CLI path (Alt+E)'; Type = 'ControlType.Edit' }
            [pscustomobject]@{ Name = 'Data root (Alt+D)'; Type = 'ControlType.Edit' }
            [pscustomobject]@{ Name = "Theme (Alt+H)`nFollow Windows"; Type = 'ControlType.Button' }
            [pscustomobject]@{ Name = "Text size (Alt+Z)`n100%"; Type = 'ControlType.Button' }
            [pscustomobject]@{ Name = 'Bella volume (Alt+V)'; Type = 'ControlType.Slider' }
            [pscustomobject]@{ Name = 'Cancel (Alt+C)'; Type = 'ControlType.Button' }
            [pscustomobject]@{ Name = 'Save (Ctrl+S)'; Type = 'ControlType.Button' }
        )
        (Test-ReleaseUiaSettingsSnapshot -Nodes $nodes).Ok | Should -BeTrue
    }
}

Describe 'native modal transition regression' {
    It 'rejects a stale workspace after invoking Settings through MSAA' {
        $nodes = @(
            [pscustomobject]@{ Name = 'Tasks Viewer'; Type = 'ControlType.Custom'; NativeRole = 20 }
            [pscustomobject]@{ Name = 'Settings (Ctrl+,)'; Type = 'ControlType.Button'; NativeRole = 43 }
            [pscustomobject]@{ Name = 'Projects'; Type = 'ControlType.Custom'; NativeRole = 20 }
            [pscustomobject]@{ Name = 'Search projects (Ctrl+F)'; Type = 'ControlType.Edit'; NativeRole = 42 }
        )
        $result = Test-ReleaseUiaSettingsSnapshot -Nodes $nodes
        $result.Ok | Should -BeFalse
        @($result.Findings).Count | Should -Be 8
    }
}

Describe 'bare FLUTTERVIEW snapshot predicate' {
    It 'accepts the exact signature Windows returns before the accessibility bridge attaches' {
        $nodes = @([pscustomobject]@{ Name = 'FLUTTERVIEW'; Type = 'MSAA.Role.10' })
        Test-ReleaseUiaBareFlutterViewSnapshot -Nodes $nodes | Should -BeTrue
    }

    It 'accepts any unrecognized MSAA role number, not just 10' {
        $nodes = @([pscustomobject]@{ Name = 'FLUTTERVIEW'; Type = 'MSAA.Role.9' })
        Test-ReleaseUiaBareFlutterViewSnapshot -Nodes $nodes | Should -BeTrue
    }

    It 'rejects an empty snapshot' {
        Test-ReleaseUiaBareFlutterViewSnapshot -Nodes @() | Should -BeFalse
    }

    It 'rejects more than one node even if the first is the bare default' {
        $nodes = @(
            [pscustomobject]@{ Name = 'FLUTTERVIEW'; Type = 'MSAA.Role.10' }
            [pscustomobject]@{ Name = 'Projects'; Type = 'ControlType.Custom' }
        )
        Test-ReleaseUiaBareFlutterViewSnapshot -Nodes $nodes | Should -BeFalse
    }

    It 'rejects a FLUTTERVIEW node that carries a recognized (non-default) type' {
        $nodes = @([pscustomobject]@{ Name = 'FLUTTERVIEW'; Type = 'ControlType.Pane' })
        Test-ReleaseUiaBareFlutterViewSnapshot -Nodes $nodes | Should -BeFalse
    }

    It 'rejects a single default-role node whose name is not FLUTTERVIEW' {
        $nodes = @([pscustomobject]@{ Name = 'Tasks Viewer'; Type = 'MSAA.Role.10' })
        Test-ReleaseUiaBareFlutterViewSnapshot -Nodes $nodes | Should -BeFalse
    }
}

Describe 'release UIA probe retry decision' {
    BeforeEach {
        $script:attemptCalls = [System.Collections.Generic.List[object]]::new()
    }

    It 'retries exactly once after a bare FLUTTERVIEW timeout, then reports success as retried' {
        $bareTimeout = [pscustomobject]@{
            Ok = $false; Reason = 'Release UIA check timed out after 45 s. No project row.'
            Nodes = @([pscustomobject]@{ Name = 'FLUTTERVIEW'; Type = 'MSAA.Role.10' })
            NodeCount = 1; ElapsedSeconds = 45.0; Backend = $null; WindowName = $null
            SettingsChecks = $null; SettingsNodes = @(); ProcessId = 111; TimedOut = $true
        }
        $success = [pscustomobject]@{
            Ok = $true; Reason = $null
            Nodes = @([pscustomobject]@{ Name = 'Tasks Viewer'; Type = 'ControlType.Window' })
            NodeCount = 70; ElapsedSeconds = 6.0; Backend = 'UIA'; WindowName = 'Tasks Viewer'
            Checks = [pscustomobject]@{ Ok = $true }
            SettingsChecks = [pscustomobject]@{ Ok = $true }; SettingsNodes = @(); ProcessId = 222
        }
        $canned = @($bareTimeout, $success)
        $stub = {
            param($ViewerExe, $BundleFull, $CliExe, $DataRootFull, $SettingsRootFull,
                $ExpectedProjectName, $ExpectedOpenCount, $ExpectedTotalCount, $TimeoutSeconds)
            # The stub does not need these; referencing them once satisfies
            # PSReviewUnusedParameter while keeping the splat shape identical
            # to Invoke-ReleaseUiaAttempt's real signature.
            $null = $ViewerExe, $BundleFull, $CliExe, $DataRootFull, $SettingsRootFull,
                $ExpectedProjectName, $ExpectedOpenCount, $ExpectedTotalCount, $TimeoutSeconds
            $script:attemptCalls.Add($true)
            return $canned[$script:attemptCalls.Count - 1]
        }

        $result = Invoke-ReleaseUiaProbe -BundleRoot $script:BundleRoot -DataRoot $script:DataRoot `
            -SettingsRoot $script:SettingsRoot -ExpectedProjectName 'alpha' -TimeoutSeconds 45 `
            -AttemptFunction $stub

        $script:attemptCalls.Count | Should -Be 2
        $result.Ok | Should -BeTrue
        $result.Retried | Should -BeTrue
        $result.FirstAttempt.NodeCount | Should -Be 1
        $result.FirstAttempt.ElapsedSeconds | Should -Be 45.0
    }

    It 'does not retry a timeout whose final snapshot is not the bare FLUTTERVIEW signature' {
        $emptyTimeout = [pscustomobject]@{
            Ok = $false; Reason = 'Release UIA check timed out after 45 s. No window owned by the launched process appeared in UIA.'
            Nodes = @(); NodeCount = 0; ElapsedSeconds = 45.0; Backend = $null; WindowName = $null
            SettingsChecks = $null; SettingsNodes = @(); ProcessId = 111; TimedOut = $true
        }
        $stub = {
            param($ViewerExe, $BundleFull, $CliExe, $DataRootFull, $SettingsRootFull,
                $ExpectedProjectName, $ExpectedOpenCount, $ExpectedTotalCount, $TimeoutSeconds)
            # The stub does not need these; referencing them once satisfies
            # PSReviewUnusedParameter while keeping the splat shape identical
            # to Invoke-ReleaseUiaAttempt's real signature.
            $null = $ViewerExe, $BundleFull, $CliExe, $DataRootFull, $SettingsRootFull,
                $ExpectedProjectName, $ExpectedOpenCount, $ExpectedTotalCount, $TimeoutSeconds
            $script:attemptCalls.Add($true)
            return $emptyTimeout
        }

        { Invoke-ReleaseUiaProbe -BundleRoot $script:BundleRoot -DataRoot $script:DataRoot `
                -SettingsRoot $script:SettingsRoot -ExpectedProjectName 'alpha' -TimeoutSeconds 45 `
                -AttemptFunction $stub } | Should -Throw '*Not retried*'

        $script:attemptCalls.Count | Should -Be 1
    }

    It 'does not retry a non-timeout failure even if its snapshot looks bare' {
        $nonTimeoutFailure = [pscustomobject]@{
            Ok = $false; Reason = 'Settings is absent from the packaged release UIA tree.'
            Nodes = @([pscustomobject]@{ Name = 'FLUTTERVIEW'; Type = 'MSAA.Role.10' })
            NodeCount = 1; ElapsedSeconds = 3.0; Backend = 'UIA'; WindowName = 'Tasks Viewer'
            SettingsChecks = $null; SettingsNodes = @(); ProcessId = 111; TimedOut = $false
        }
        $stub = {
            param($ViewerExe, $BundleFull, $CliExe, $DataRootFull, $SettingsRootFull,
                $ExpectedProjectName, $ExpectedOpenCount, $ExpectedTotalCount, $TimeoutSeconds)
            # The stub does not need these; referencing them once satisfies
            # PSReviewUnusedParameter while keeping the splat shape identical
            # to Invoke-ReleaseUiaAttempt's real signature.
            $null = $ViewerExe, $BundleFull, $CliExe, $DataRootFull, $SettingsRootFull,
                $ExpectedProjectName, $ExpectedOpenCount, $ExpectedTotalCount, $TimeoutSeconds
            $script:attemptCalls.Add($true)
            return $nonTimeoutFailure
        }

        { Invoke-ReleaseUiaProbe -BundleRoot $script:BundleRoot -DataRoot $script:DataRoot `
                -SettingsRoot $script:SettingsRoot -ExpectedProjectName 'alpha' -TimeoutSeconds 45 `
                -AttemptFunction $stub } | Should -Throw '*Not retried*'

        $script:attemptCalls.Count | Should -Be 1
    }
}

Describe 'release UIA probe script entry point' {
    # Regression for a REVISE finding on TSK-017: verify-windows.ps1 passes
    # `-WarmupTimeoutSeconds` style additions through to this script's own
    # top-level param() block (not just the Invoke-ReleaseUiaProbe function's
    # param block). A mismatch between the two makes pwsh fail parameter
    # binding before any of this script's own code runs, which the
    # function-level Pester tests above cannot see since they dot-source the
    # file directly rather than invoking it as `pwsh -File ...`. This test
    # runs the actual script entry point with the exact argument set and
    # order verify-windows.ps1 passes, and asserts the failure is this
    # script's own domain error (a missing packaged executable), not a
    # PowerShell parameter-binding error.
    It 'binds every argument verify-windows.ps1 passes without a parameter-binding error' {
        $scriptPath = Join-Path $PSScriptRoot '../verify-release-uia.ps1'
        $pwsh = (Get-Command -Name 'pwsh' -ErrorAction Stop).Source
        # A bundle path that does not exist: parameter binding must still
        # succeed (that's what this test proves), and the script should then
        # fail on its own missing-executable check rather than ever trying
        # to launch a window.
        $missingBundleRoot = Join-Path $script:DummyRoot 'no-such-bundle'
        $arguments = @('-NoProfile', '-File', $scriptPath,
            '-BundleRoot', $missingBundleRoot,
            '-DataRoot', $script:DataRoot,
            '-SettingsRoot', $script:SettingsRoot,
            '-ExpectedProjectName', 'alpha (ALPHA)',
            '-ExpectedOpenCount', '27',
            '-ExpectedTotalCount', '28',
            '-TimeoutSeconds', '1')

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $pwsh
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        foreach ($argument in $arguments) { [void]$psi.ArgumentList.Add($argument) }
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdErr = $proc.StandardError.ReadToEndAsync()
        # Drain stdout concurrently too so the child can't deadlock writing
        # to a full pipe buffer; its content is not asserted on.
        [void]$proc.StandardOutput.ReadToEndAsync()
        $proc.WaitForExit(30000) | Should -BeTrue
        $err = $stdErr.Result

        $proc.ExitCode | Should -Be 1
        $err | Should -Match 'packaged executable'
        $err | Should -Not -Match 'parameter cannot be found'
        $err | Should -Not -Match 'positional parameter'
        $err | Should -Not -Match 'Cannot bind parameter'
        $err | Should -Not -Match 'Missing an argument'
    }
}
