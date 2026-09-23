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
