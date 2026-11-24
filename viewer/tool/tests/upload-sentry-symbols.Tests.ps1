#Requires -Version 7.0
<#
.SYNOPSIS
Focused Pester tests for viewer/tool/upload-sentry-symbols.ps1.
#>
[CmdletBinding()]
param()

BeforeAll {
    $script:ToolPath = Join-Path -Path $PSScriptRoot -ChildPath '../upload-sentry-symbols.ps1'
    . $script:ToolPath
}

Describe 'upload-sentry-symbols.ps1 configuration and discovery' {
    BeforeEach {
        $script:Root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("sentry-sym-test-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Force -Path $script:Root | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'skips cleanly when no token is configured' {
        $savedToken = $env:SENTRY_AUTH_TOKEN
        $savedOrg = $env:SENTRY_ORG
        try {
            $env:SENTRY_AUTH_TOKEN = ''
            $env:SENTRY_ORG = ''
            $result = Invoke-SentrySymbolUpload -Component all -RepositoryRoot $script:Root -ViewerRoot (Join-Path $script:Root 'viewer')
            $result.Ok | Should -BeTrue
            $result.Skipped | Should -BeTrue
        }
        finally {
            $env:SENTRY_AUTH_TOKEN = $savedToken
            $env:SENTRY_ORG = $savedOrg
        }
    }

    It 'reads org, url, and token from private overlay when env vars are absent' {
        $privateDir = Join-Path $script:Root '.private/integration'
        New-Item -ItemType Directory -Force -Path $privateDir | Out-Null
        Set-Content -LiteralPath (Join-Path $privateDir 'sentry-auth.env') -Value @(
            'SENTRY_URL=https://de.sentry.io/'
            'SENTRY_ORG=example-org'
            'SENTRY_AUTH_TOKEN=fake_test_token_value'
        ) -Encoding utf8NoBOM

        $cfg = Resolve-SentryUploadConfiguration -RepositoryRoot $script:Root -EnvironmentOverride @{
            SENTRY_URL        = ''
            SENTRY_ORG        = ''
            SENTRY_AUTH_TOKEN = ''
            TASKS_SENTRY_USE_PRIVATE_OVERLAY = '1'
        }
        $cfg.Configured | Should -BeTrue
        $cfg.Url | Should -Be 'https://de.sentry.io/'
        $cfg.Org | Should -Be 'example-org'
        $cfg.AuthToken | Should -Be 'fake_test_token_value'
    }

    It 'discovers CLI and viewer symbols including engine PDB in DryRun mode' {
        $cliTarget = Join-Path $script:Root 'target'
        $cliRelease = Join-Path $cliTarget 'release'
        $viewerRoot = Join-Path $script:Root 'viewer'
        $viewerSymbols = Join-Path $viewerRoot 'build/windows/x64/symbols/Release'
        $viewerRunner = Join-Path $viewerRoot 'build/windows/x64/runner/Release'
        $flutterRoot = Join-Path $script:Root 'flutter'
        $engineDir = Join-Path $flutterRoot 'bin/cache/artifacts/engine/windows-x64-release'
        New-Item -ItemType Directory -Force -Path $cliRelease, $viewerSymbols, (Join-Path $viewerRunner 'data'), $engineDir | Out-Null

        Set-Content -LiteralPath (Join-Path $cliRelease 'tasks.exe') -Value 'cli' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $cliRelease 'tasks.pdb') -Value 'pdb' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $viewerSymbols 'tasks_viewer.pdb') -Value 'vpdb' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $viewerRunner 'tasks_viewer.exe') -Value 'vexe' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $viewerRunner 'flutter_windows.dll') -Value 'fdll' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $viewerRunner 'data/app.so') -Value 'aso' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $engineDir 'flutter_windows.dll.pdb') -Value 'epdb' -Encoding utf8NoBOM

        $cliPaths = @(Get-SentryDebugSymbolPaths -Component cli -RepositoryRoot $script:Root -ViewerRoot $viewerRoot -CliTargetDirectory $cliTarget)
        $cliPaths.Count | Should -Be 2

        $viewerPaths = @(Get-SentryDebugSymbolPaths -Component viewer -RepositoryRoot $script:Root -ViewerRoot $viewerRoot -FlutterRoot $flutterRoot)
        $viewerPaths.Count | Should -Be 5
        ($viewerPaths -join "`n") | Should -Match 'tasks_viewer\.pdb'
        ($viewerPaths -join "`n") | Should -Match 'flutter_windows\.dll\.pdb'
    }
}
