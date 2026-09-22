#Requires -Version 7.0
<#
.SYNOPSIS
Focused tests for viewer/tool/measure.ps1.

.DESCRIPTION
Covers the harness rules that keep a measurement run honest and
non-destructive: the fixture root never escapes the run-owned temporary root,
the fixture name guard refuses anything a later cleanup would not own,
cleanup re-checks the same bounds before removing a tree, the percentile and
status helpers cannot report a pass from an incomplete sample set, and the
body-size check counts UTF-8 bytes rather than decoded characters.
Nothing here seeds a real fixture, starts a CLI process or opens a database.
#>
[CmdletBinding()]
param()

BeforeAll {
    $script:ToolPath = Join-Path -Path $PSScriptRoot -ChildPath '../measure.ps1'
    . $script:ToolPath

    function New-MeasureTestRoot {
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper; it creates only one run-owned directory under the system temp path.')]
        param()

        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "tasks-cli-measure-test-$([guid]::NewGuid().ToString('n'))"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        return $root
    }

    function New-MeasureFixtureDirectory {
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper; it creates one run-owned fixture-shaped directory under the temp root.')]
        param(
            [Parameter(Mandatory)][string]$WorkingRoot,

            [string]$Leaf = 'tasks-viewer-perf-01234567'
        )

        $path = Join-Path -Path $WorkingRoot -ChildPath $Leaf
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        return $path
    }
}

Describe 'measure.ps1 fixture bounds' {
    BeforeAll {
        $script:WorkingRoot = New-MeasureTestRoot
        $script:RepositoryRoot = Join-Path -Path $script:WorkingRoot -ChildPath 'repository'
        New-Item -ItemType Directory -Force -Path $script:RepositoryRoot | Out-Null
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:WorkingRoot) {
            [System.IO.Directory]::Delete($script:WorkingRoot, $true)
        }
    }

    It 'resolves a fresh throwaway root outside the repository' {
        $resolved = Resolve-MeasureFixtureRoot -WorkingRoot $script:WorkingRoot -RepositoryRoot $script:RepositoryRoot

        $resolved | Should -BeLike "$script:WorkingRoot*"
        (Split-Path -Leaf $resolved) | Should -BeLike 'tasks-viewer-perf-*'
    }

    It 'refuses a fixture root the cleanup would not own' {
        $leaf = Join-Path -Path $script:WorkingRoot -ChildPath 'tasks-cli-not-ours'

        { Resolve-MeasureFixtureRoot -WorkingRoot $script:WorkingRoot -FixtureRoot $leaf -RepositoryRoot $script:RepositoryRoot } |
            Should -Throw '*tasks-viewer-perf-*'
    }

    It 'refuses a fixture root outside the working root' {
        $outside = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'tasks-viewer-perf-elsewhere'

        { Resolve-MeasureFixtureRoot -WorkingRoot $script:WorkingRoot -FixtureRoot $outside -RepositoryRoot $script:RepositoryRoot } |
            Should -Throw '*must stay inside*'
    }

    It 'refuses a fixture root inside the repository even with an owned name' {
        $inside = Join-Path -Path $script:RepositoryRoot -ChildPath 'tasks-viewer-perf-01234567'

        { Resolve-MeasureFixtureRoot -WorkingRoot $script:RepositoryRoot -FixtureRoot $inside -RepositoryRoot $script:RepositoryRoot } |
            Should -Throw '*never live inside the repository*'
    }

    It 'removes only the run-owned tree it was given' {
        $owned = New-MeasureFixtureDirectory -WorkingRoot $script:WorkingRoot
        Set-Content -LiteralPath (Join-Path -Path $owned -ChildPath 'data.txt') -Value 'fixture' -Encoding utf8NoBOM
        $sibling = New-MeasureFixtureDirectory -WorkingRoot $script:WorkingRoot -Leaf 'tasks-viewer-perf-89abcdef'

        Clear-MeasureFixture -FixtureRoot $owned -WorkingRoot $script:WorkingRoot -RepositoryRoot $script:RepositoryRoot

        (Test-Path -LiteralPath $owned) | Should -BeFalse
        (Test-Path -LiteralPath $sibling) | Should -BeTrue
    }

    It 'refuses to clear a tree whose name is not run-owned' {
        $foreign = Join-Path -Path $script:WorkingRoot -ChildPath 'tasks-cli-keep'
        New-Item -ItemType Directory -Force -Path $foreign | Out-Null

        { Clear-MeasureFixture -FixtureRoot $foreign -WorkingRoot $script:WorkingRoot -RepositoryRoot $script:RepositoryRoot } |
            Should -Throw '*tasks-viewer-perf-*'
        (Test-Path -LiteralPath $foreign) | Should -BeTrue
    }

    It 'refuses to reuse a fixture root that already holds content' {
        $populated = New-MeasureFixtureDirectory -WorkingRoot $script:WorkingRoot -Leaf 'tasks-viewer-perf-44444444'
        Set-Content -LiteralPath (Join-Path -Path $populated -ChildPath 'leftover.txt') -Value 'older run' -Encoding utf8NoBOM

        { Initialize-MeasureFixtureRoot -FixtureRoot $populated } | Should -Throw '*already holds content*'
    }
}

Describe 'measure.ps1 statistics helpers' {
    It 'reports the nearest-rank percentile of a raw sample list' {
        $samples = @(10, 20, 30, 40, 50, 60, 70, 80, 90, 100)

        (Get-Percentile -Samples $samples -Percentile 0.5) | Should -Be 50
        (Get-Percentile -Samples $samples -Percentile 0.95) | Should -Be 100
    }

    It 'keeps every raw sample and its order in the summary' {
        $stats = Get-MeasureStatistic -Samples @(300, 100, 200)

        $stats.Count | Should -Be 3
        $stats.Min | Should -Be 100
        $stats.P50 | Should -Be 200
        $stats.Max | Should -Be 300
        $stats.Samples | Should -Be @(100, 200, 300)
    }

    It 'summarises an empty sample set without inventing a value' {
        $stats = Get-MeasureStatistic -Samples @()

        $stats.Count | Should -Be 0
        $stats.P95 | Should -BeNullOrEmpty
    }

    It 'never passes a row with fewer samples than the run planned' {
        (Get-MeasureStatus -P95 120 -TargetMs 500 -Count 3 -ExpectedCount 30) | Should -Be 'incomplete'
        (Get-MeasureStatus -P95 $null -TargetMs 500 -Count 30 -ExpectedCount 30) | Should -Be 'incomplete'
        (Get-MeasureStatus -P95 480 -TargetMs 500 -Count 30 -ExpectedCount 30) | Should -Be 'passed'
        (Get-MeasureStatus -P95 620 -TargetMs 500 -Count 30 -ExpectedCount 30) | Should -Be 'failed'
    }
}

Describe 'measure.ps1 body size check' {
    It 'counts UTF-8 bytes rather than decoded characters' {
        Get-Utf8ByteCount -Text 'ascii' | Should -Be 5
        Get-Utf8ByteCount -Text '' | Should -Be 0
        Get-Utf8ByteCount -Text 'ą' | Should -Be 2
        Get-Utf8ByteCount -Text ('x' * 2047 + 'ą') | Should -Be 2049
    }
}
