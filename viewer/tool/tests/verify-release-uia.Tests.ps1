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
