#Requires -Version 7.0
BeforeAll {
    . "$PSScriptRoot/../tool-paths.ps1"
    . "$PSScriptRoot/../verify-windows.ps1"
    . "$PSScriptRoot/../measure.ps1"
}
Describe 'lane build and evidence roots' {
    It 'exposes root overrides on the callable harnesses' {
        foreach ($name in @('Invoke-VerifyWindows', 'Invoke-Measure')) {
            $parameters = (Get-Command $name).Parameters
            $parameters.ContainsKey('CliTargetDirectory') | Should -BeTrue
            $parameters.ContainsKey('EvidenceParentRoot') | Should -BeTrue
        }
    }
    It 'keeps the existing timestamped evidence defaults for both harnesses' {
        foreach ($command in @('Resolve-VerifyEvidenceRoot', 'Resolve-MeasureEvidenceRoot')) {
            $path = & $command -ViewerRoot $TestDrive -Now ([datetime]'2026-10-25T12:00:00')
            $path | Should -BeLike (Join-Path $TestDrive 'target/evidence/viewer/2026-10-25-120000-*')
        }
    }
    It 'keeps the existing verification CLI default' {
        Resolve-ToolCliTarget -RepositoryRoot $TestDrive | Should -Be (Join-Path $TestDrive 'target/verify-cli')
    }
    It 'accepts a lane CLI target' {
        $lane = Join-Path $TestDrive 'lane/rust'
        Resolve-ToolCliTarget -RepositoryRoot $TestDrive -CliTargetDirectory $lane | Should -Be $lane
    }
    It 'refuses the installed CLI target' {
        { Resolve-ToolCliTarget -RepositoryRoot $TestDrive -CliTargetDirectory (Join-Path $TestDrive 'target') } | Should -Throw '*installed*'
    }
    It 'refuses a link to the installed target' {
        $installed = Join-Path $TestDrive 'target'
        New-Item -ItemType Directory -Force -Path $installed | Out-Null
        $link = Join-Path $TestDrive 'linked-target'
        New-Item -ItemType Junction -Path $link -Target $installed | Out-Null
        try {
            { Resolve-ToolCliTarget -RepositoryRoot $TestDrive -CliTargetDirectory $link } | Should -Throw '*reparse*'
        }
        finally { Remove-Item -LiteralPath $link -Force }
    }
    It 'uses the selected evidence parent for both harnesses' {
        $parent = Join-Path $TestDrive 'lane/evidence'
        foreach ($command in @('Resolve-VerifyEvidenceRoot', 'Resolve-MeasureEvidenceRoot')) {
            $path = & $command -ViewerRoot $TestDrive -EvidenceParentRoot $parent -Now ([datetime]'2026-10-25T12:00:00')
            $path | Should -BeLike "$parent*"
            { & $command -ViewerRoot $TestDrive -EvidenceParentRoot $parent -EvidenceRoot (Join-Path $TestDrive 'outside') } | Should -Throw '*must stay inside*'
            { & $command -ViewerRoot $TestDrive -EvidenceParentRoot $parent -EvidenceRoot (Join-Path $parent '../escape') } | Should -Throw '*must stay inside*'
        }
    }
    It 'refuses a redirected evidence child' {
        $parent = Join-Path $TestDrive 'evidence'
        $outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory -Force -Path $parent, $outside | Out-Null
        $link = Join-Path $parent 'link'
        New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
        try {
            { Resolve-VerifyEvidenceRoot -ViewerRoot $TestDrive -EvidenceParentRoot $parent -EvidenceRoot (Join-Path $link 'run') } | Should -Throw '*reparse*'
        }
        finally { Remove-Item -LiteralPath $link -Force }
    }
}

Describe 'verification build routing' {
    BeforeAll {
        # Import last so this test uses verify's same-named process helper.
        . "$PSScriptRoot/../verify-windows.ps1"
    }
    It 'passes the selected Cargo target and writes failure proof only to selected evidence' {
        $repository = Join-Path $TestDrive 'repository'
        $viewer = Join-Path $repository 'viewer'
        $lane = Join-Path $TestDrive 'lane'
        $cliTarget = Join-Path $lane 'rust'
        $evidence = Join-Path $lane 'evidence/run'
        $working = Join-Path $TestDrive 'working'
        New-Item -ItemType Directory -Force -Path $viewer, $working | Out-Null
        Mock Resolve-FlutterLauncher { [pscustomobject]@{ Dart = 'unused'; Flutter = 'unused' } }
        Mock Test-HasConsoleWindow { $false }
        Mock Get-ToolchainReport { 'fixture toolchains' }
        Mock Invoke-CapturedProcess { [pscustomobject]@{ ExitCode = 9; TimedOut = $false; StdOut = ''; StdErr = 'intentional fixture stop'; Milliseconds = 1 } }
        $result = Invoke-VerifyWindows -ViewerRoot $viewer -RepositoryRoot $repository `
            -CliTargetDirectory $cliTarget -EvidenceParentRoot (Join-Path $lane 'evidence') -EvidenceRoot $evidence `
            -WorkingRoot $working -PackageToolPath "$PSScriptRoot/../package.ps1" -UiaProbeToolPath "$PSScriptRoot/../verify-release-uia.ps1" -SkipReleaseUia
        $result.Ok | Should -BeFalse
        Should -Invoke Invoke-CapturedProcess -Times 1 -Exactly -ParameterFilter {
            $targetIndex = [array]::IndexOf($Arguments, '--target-dir')
            $FilePath -eq 'cargo' -and $targetIndex -ge 0 -and $Arguments[$targetIndex + 1] -eq $cliTarget
        }
        Test-Path -LiteralPath $result.SummaryPath | Should -BeTrue
        @(Get-ChildItem -LiteralPath $repository -Recurse -File).Count | Should -Be 0
    }
}

Describe 'measurement build routing' {
    BeforeAll { . "$PSScriptRoot/../measure.ps1" }
    It 'passes the selected Cargo target and cleans its explicit fixture on failure' {
        $repository = Join-Path $TestDrive 'repository'
        $lane = Join-Path $TestDrive 'lane'
        $cliTarget = Join-Path $lane 'rust'
        $evidence = Join-Path $lane 'evidence/run'
        $working = Join-Path $TestDrive 'working'
        $fixture = Join-Path $working 'tasks-viewer-perf-12345678'
        New-Item -ItemType Directory -Force -Path $repository, $working | Out-Null
        Mock Invoke-CapturedProcess { [pscustomobject]@{ ExitCode = 9; TimedOut = $false; StdOut = ''; StdErr = 'intentional fixture stop'; Milliseconds = 1 } }
        { Invoke-Measure -ViewerRoot $repository -RepositoryRoot $repository `
                -CliTargetDirectory $cliTarget -EvidenceParentRoot (Join-Path $lane 'evidence') -EvidenceRoot $evidence `
                -WorkingRoot $working -FixtureRoot $fixture -Iterations 1 -Warmup 0 -TimeoutSeconds 10 -Seed 1 } | Should -Throw '*failed with exit 9*'
        Should -Invoke Invoke-CapturedProcess -Times 1 -Exactly -ParameterFilter {
            $Arguments[3] -eq '--target-dir' -and $Arguments[4] -eq $cliTarget
        }
        Test-Path -LiteralPath (Join-Path $evidence 'measure-failure.txt') | Should -BeTrue
        Test-Path -LiteralPath $fixture | Should -BeFalse
        @(Get-ChildItem -LiteralPath $repository -Recurse -File).Count | Should -Be 0
    }
}
