#Requires -Version 7.0
<#
.SYNOPSIS
Focused tests for viewer/tool/verify-windows.ps1.

.DESCRIPTION
Covers the harness rules that keep a headless verification run honest and
non-destructive: the fixture root never escapes the run-owned temporary root,
the evidence root stays inside the viewer target tree, the reporter parser
reads the real counts and never reports success without the suite's own line,
the bundle hash re-check catches missing or altered files, and the fixture
guard refuses the argument shapes that would seed or remove the wrong tree.
Nothing here starts a Flutter run, a window or a real CLI process.
#>
[CmdletBinding()]
param()

BeforeAll {
    $script:ToolPath = Join-Path -Path $PSScriptRoot -ChildPath '../verify-windows.ps1'
    . $script:ToolPath

    function New-VerifyTestRoot {
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper; it creates only one run-owned directory under the system temp path.')]
        param()

        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "tasks-cli-verify-test-$([guid]::NewGuid().ToString('n'))"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        return $root
    }

    function New-VerifyFixtureDirectory {
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper; it creates one run-owned fixture-shaped directory under the temp root.')]
        param(
            [Parameter(Mandatory)][string]$WorkingRoot,

            [string]$Leaf = 'tasks-viewer-e2e-01234567'
        )

        $path = Join-Path -Path $WorkingRoot -ChildPath $Leaf
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        return $path
    }
}

Describe 'verify-windows.ps1 dot-source contract' {
    It 'defines the harness functions without running the gates' {
        foreach ($name in @('Invoke-VerifyWindows', 'Get-FlutterTestCount', 'Resolve-VerifyFixtureRoot')) {
            Get-Command -Name $name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'verify-windows.ps1 fixture root bounds' {
    BeforeEach {
        $script:Root = New-VerifyTestRoot
        $script:Working = Join-Path -Path $script:Root -ChildPath 'work'
        $script:Repository = Join-Path -Path $script:Root -ChildPath 'repo'
        New-Item -ItemType Directory -Force -Path $script:Working, $script:Repository | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'generates a run-owned leaf under the working root' {
        $resolved = Resolve-VerifyFixtureRoot -WorkingRoot $script:Working -RepositoryRoot $script:Repository
        (Split-Path -Leaf $resolved) | Should -Match '^tasks-viewer-e2e-[0-9a-f]{8}$'
        $resolved.StartsWith([System.IO.Path]::GetFullPath($script:Working), [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
    }

    It 'refuses a fixture root outside the working root' {
        $outside = Join-Path -Path $script:Root -ChildPath 'elsewhere'
        { Resolve-VerifyFixtureRoot -WorkingRoot $script:Working -FixtureRoot $outside -RepositoryRoot $script:Repository } |
            Should -Throw -ExpectedMessage '*must stay inside*'
    }

    It 'refuses a fixture root inside the repository' {
        $inside = Join-Path -Path $script:Repository -ChildPath 'tasks-viewer-e2e-01234567'
        { Resolve-VerifyFixtureRoot -WorkingRoot $script:Root -FixtureRoot $inside -RepositoryRoot $script:Repository } |
            Should -Throw -ExpectedMessage '*never live inside the repository*'
    }
}

Describe 'verify-windows.ps1 evidence root bounds' {
    BeforeEach {
        $script:Root = New-VerifyTestRoot
        $script:Viewer = Join-Path -Path $script:Root -ChildPath 'viewer'
        New-Item -ItemType Directory -Force -Path $script:Viewer | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'defaults to one timestamped directory inside the viewer target tree' {
        $resolved = Resolve-VerifyEvidenceRoot -ViewerRoot $script:Viewer -Now ([datetime]'2026-09-22T11:22:33')
        (Split-Path -Leaf $resolved) | Should -Be '2026-09-22-112233-verify-windows'
        $resolved.StartsWith((Join-Path $script:Viewer 'target/evidence/viewer'), [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
    }

    It 'refuses an evidence root outside the viewer target tree' {
        { Resolve-VerifyEvidenceRoot -ViewerRoot $script:Viewer -EvidenceRoot (Join-Path $script:Root 'evidence') } |
            Should -Throw -ExpectedMessage '*must stay inside*'
    }
}

Describe 'verify-windows.ps1 fixture guards' {
    BeforeEach {
        $script:Root = New-VerifyTestRoot
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'refuses fewer than the reserved alpha rows' {
        { Initialize-ViewerVerifyFixture -FixtureRoot (Join-Path $script:Root 'fixture') -CliExecutable 'tasks.exe' `
                -Seed 1 -AlphaTaskCount 27 -CommandTimeoutSeconds 5 } |
            Should -Throw -ExpectedMessage '*at least 28*'
    }

    It 'refuses an empty beta project' {
        { Initialize-ViewerVerifyFixture -FixtureRoot (Join-Path $script:Root 'fixture') -CliExecutable 'tasks.exe' `
                -Seed 1 -BetaTaskCount 0 -CommandTimeoutSeconds 5 } |
            Should -Throw -ExpectedMessage '*BetaTaskCount must be at least 1*'
    }

    It 'refuses an existing fixture root instead of seeding over it' {
        $existing = Join-Path -Path $script:Root -ChildPath 'fixture'
        New-Item -ItemType Directory -Force -Path $existing | Out-Null
        { Initialize-ViewerVerifyFixture -FixtureRoot $existing -CliExecutable 'tasks.exe' `
                -Seed 1 -CommandTimeoutSeconds 5 } |
            Should -Throw -ExpectedMessage '*already exists*'
    }

    It 'removes a run-owned fixture root' {
        $fixture = New-VerifyFixtureDirectory -WorkingRoot $script:Root
        $removed = Clear-ViewerVerifyFixture -FixtureRoot $fixture -WorkingRoot $script:Root -RepositoryRoot (Join-Path $script:Root 'repo')
        $removed | Should -BeTrue
        Test-Path -LiteralPath $fixture | Should -BeFalse
    }

    It 'keeps the fixture root with -Keep and refuses a foreign leaf' {
        $fixture = New-VerifyFixtureDirectory -WorkingRoot $script:Root
        (Clear-ViewerVerifyFixture -FixtureRoot $fixture -WorkingRoot $script:Root -RepositoryRoot (Join-Path $script:Root 'repo') -Keep) | Should -BeFalse
        Test-Path -LiteralPath $fixture | Should -BeTrue

        $foreign = New-VerifyFixtureDirectory -WorkingRoot $script:Root -Leaf 'not-run-owned'
        { Clear-ViewerVerifyFixture -FixtureRoot $foreign -WorkingRoot $script:Root -RepositoryRoot (Join-Path $script:Root 'repo') } |
            Should -Throw -ExpectedMessage '*run-owned fixture root*'
        Test-Path -LiteralPath $foreign | Should -BeTrue
    }

    It 'derives a separately removable end-to-end root from the suite root' {
        $suite = New-VerifyFixtureDirectory -WorkingRoot $script:Root
        $gate = Resolve-VerifyFixtureRoot -WorkingRoot $script:Root -RepositoryRoot (Join-Path $script:Root 'repo') `
            -FixtureRoot "$suite-e2e"
        $gate | Should -Not -Be $suite
        (Split-Path -Leaf $gate) | Should -Match '^tasks-viewer-e2e-[0-9a-f]{8}-e2e$'
        New-Item -ItemType Directory -Force -Path $gate | Out-Null

        (Clear-ViewerVerifyFixture -FixtureRoot $gate -WorkingRoot $script:Root -RepositoryRoot (Join-Path $script:Root 'repo')) | Should -BeTrue
        Test-Path -LiteralPath $gate | Should -BeFalse
        Test-Path -LiteralPath $suite | Should -BeTrue
    }
}

Describe 'verify-windows.ps1 packaging hand-off' {
    It 'copies the fixture cleanup inputs before dot-sourcing the packaging tool' {
        # package.ps1 declares $WorkingRoot, so dot-sourcing it rebinds that name
        # in the harness scope. The fixture cleanup runs after that point, so it
        # must use copies taken beforehand or it silently loses the temp root.
        $text = Get-Content -LiteralPath $script:ToolPath -Raw
        $snapshot = $text.IndexOf('$fixtureCleanupWorkingRoot = $WorkingRoot', [System.StringComparison]::Ordinal)
        $dotSource = $text.IndexOf('. $PackageToolPath', [System.StringComparison]::Ordinal)
        $snapshot | Should -BeGreaterThan 0
        $dotSource | Should -BeGreaterThan $snapshot
        $text.Contains('-WorkingRoot $fixtureCleanupWorkingRoot', [System.StringComparison]::Ordinal) | Should -BeTrue
    }
}

Describe 'verify-windows.ps1 reporter counts' {
    It 'reads the last progress line and requires the success line' {
        $counts = Get-FlutterTestCount -Text @'
00:00 +0: loading F:/viewer/test/integration/viewer_e2e_headless_test.dart
00:04 +458 ~1: All tests passed!
'@
        $counts.Passed | Should -Be 458
        $counts.Skipped | Should -Be 1
        $counts.Failed | Should -Be 0
        $counts.Succeeded | Should -BeTrue
    }

    It 'reads a run without skips or failures' {
        $counts = Get-FlutterTestCount -Text '00:00 +396: All tests passed!'
        $counts.Passed | Should -Be 396
        $counts.Skipped | Should -Be 0
        $counts.Failed | Should -Be 0
        $counts.Succeeded | Should -BeTrue
    }

    It 'reports a failing run' {
        $counts = Get-FlutterTestCount -Text @'
00:10 +10 ~0 -2: Some tests failed.

Consider enabling the flag: --reporter
'@
        $counts.Passed | Should -Be 10
        $counts.Failed | Should -Be 2
        $counts.Succeeded | Should -BeFalse
    }

    It 'never reads an empty or unfinished run as success' {
        (Get-FlutterTestCount -Text '').Succeeded | Should -BeFalse
        (Get-FlutterTestCount -Text '00:01 +10: still running').Succeeded | Should -BeFalse
        (Get-FlutterTestCount -Text '00:01 +10: done').Passed | Should -Be 10
    }
}

Describe 'verify-windows.ps1 bundle hash re-check' {
    BeforeEach {
        $script:Root = New-VerifyTestRoot
        $script:Bundle = Join-Path -Path $script:Root -ChildPath 'bundle'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Bundle 'data') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Bundle 'tasks.exe') -Value 'cli payload' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:Bundle 'data/app.so') -Value 'runner payload' -Encoding utf8NoBOM
        $script:HashPath = Join-Path -Path $script:Bundle -ChildPath 'SHA256SUMS.txt'
        $lines = @(
            "$(Get-FileSha256 -Path (Join-Path $script:Bundle 'tasks.exe'))  tasks.exe"
            "$(Get-FileSha256 -Path (Join-Path $script:Bundle 'data/app.so'))  data/app.so"
        )
        Set-Content -LiteralPath $script:HashPath -Value $lines -Encoding utf8NoBOM
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'accepts a bundle whose hashes match' {
        $result = Assert-BundleHash -BundleRoot $script:Bundle
        $result.Checked | Should -Be 2
        @($result.Findings).Count | Should -Be 0
    }

    It 'flags a missing bundled file' {
        Remove-Item -LiteralPath (Join-Path $script:Bundle 'data/app.so') -Force
        $result = Assert-BundleHash -BundleRoot $script:Bundle
        @($result.Findings).Count | Should -Be 1
        @($result.Findings)[0] | Should -BeLike '*data/app.so*is missing*'
    }

    It 'flags an altered bundled file' {
        Set-Content -LiteralPath (Join-Path $script:Bundle 'tasks.exe') -Value 'tampered' -Encoding utf8NoBOM
        $result = Assert-BundleHash -BundleRoot $script:Bundle
        @($result.Findings).Count | Should -Be 1
        @($result.Findings)[0] | Should -BeLike '*tasks.exe*hash mismatch*'
    }

    It 'flags a malformed hash line' {
        Add-Content -LiteralPath $script:HashPath -Value 'not-a-hash  data/app.so'
        $result = Assert-BundleHash -BundleRoot $script:Bundle
        @($result.Findings).Count | Should -Be 1
        @($result.Findings)[0] | Should -BeLike "*line 'not-a-hash*"
        @($result.Findings)[0] | Should -BeLike '*is not*'
    }

    It 'throws when the bundle has no hash list' {
        Remove-Item -LiteralPath $script:HashPath -Force
        { Assert-BundleHash -BundleRoot $script:Bundle } | Should -Throw -ExpectedMessage '*no SHA256SUMS.txt*'
    }
}

Describe 'verify-windows.ps1 gate log rendering' {
    It 'records the command, the exit code and both streams' {
        $result = [pscustomobject]@{ TimedOut = $false; ExitCode = 3; StdOut = "out line`n"; StdErr = 'err line' }
        $text = Format-GateLog -Command 'cargo test' -Result $result -Header 'header line'
        $text | Should -BeLike '*header line*'
        $text | Should -BeLike '*$ cargo test*'
        $text | Should -BeLike '*exit_code: 3*'
        $text | Should -BeLike '*--- stdout ---*out line*'
        $text | Should -BeLike '*--- stderr ---*err line*'
    }

    It 'marks a timed-out process' {
        $result = [pscustomobject]@{ TimedOut = $true; ExitCode = -1; StdOut = ''; StdErr = 'killed' }
        (Format-GateLog -Command 'flutter test' -Result $result) | Should -BeLike '*timed_out: true*'
    }
}
