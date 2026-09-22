#Requires -Version 7.0
<#
.SYNOPSIS
Focused tests for viewer/tool/package.ps1.

.DESCRIPTION
Covers the packaging safety rules that protect the release bundle: the output
root stays inside the repository target tree, credential markers never ship,
the hash list matches every other bundled file, the launch probe accepts a
working bundle and fails a broken one, and a missing input is reported instead
of writing a partial bundle. The probe uses compiled stub executables, so the
tests never launch the real viewer window.
#>
[CmdletBinding()]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '',
    Justification = 'The repository keeps PowerShell sources in UTF-8 without a BOM; the launch-probe fixture needs a real non-ASCII path.')]
param()

BeforeAll {
    $script:ToolPath = Join-Path -Path $PSScriptRoot -ChildPath '../package.ps1'
    . $script:ToolPath

    . (Join-Path -Path $PSScriptRoot -ChildPath '../generate-announcements.ps1')

    function New-PackageTestRoot {
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper; it creates only one run-owned directory under the system temp path.')]
        param()

        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "tasks-cli-package-$([guid]::NewGuid().ToString('n'))"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        return $root
    }

    function New-FakeExecutable {
        <#
        .SYNOPSIS
        Compiles one stub console executable for the launch probe.
        #>
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper; it compiles one stub executable under the run-owned temporary root.')]
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Source
        )

        $csc = Join-Path -Path $env:WINDIR -ChildPath 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
        if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
            throw "the .NET Framework C# compiler is required to build the stub executable '$Path'."
        }
        $sourcePath = "$Path.cs"
        Set-Content -LiteralPath $sourcePath -Value $Source -Encoding utf8NoBOM
        $output = & $csc /nologo /target:exe /out:$Path $sourcePath 2>&1
        Remove-Item -LiteralPath $sourcePath -Force
        if ($LASTEXITCODE -ne 0) {
            throw "csc could not build '$Path': $($output -join ' ')"
        }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "stub executable '$Path' was not produced"
        }
    }

    function New-FakeBundle {
        <#
        .SYNOPSIS
        Builds a bundle whose stubs imitate the viewer and CLI exit behaviour.
        #>
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper; it writes only inside the run-owned temporary root.')]
        param([Parameter(Mandatory)][string]$Root)

        New-Item -ItemType Directory -Force -Path $Root | Out-Null
        $viewerSource = @'
using System;
using System.Linq;
class Program {
    static int Main(string[] args) {
        if (args.Contains("--startup")) {
            string sleep = Environment.GetEnvironmentVariable("FAKE_VIEWER_SLEEP_SECONDS");
            if (sleep != null) {
                System.Threading.Thread.Sleep(int.Parse(sleep) * 1000);
            }
            string forced = Environment.GetEnvironmentVariable("FAKE_VIEWER_STARTUP_EXIT");
            if (forced != null) {
                return int.Parse(forced);
            }
            return 0;
        }
        if (args.Contains("--test-mode")) {
            Console.Error.WriteLine("Test mode requires --data-root, --tasks-exe and --settings-root.");
            return 2;
        }
        return 7;
    }
}
'@
        $cliSource = @'
using System;
using System.Linq;
class Program {
    static int Main(string[] args) {
        if (args.Contains("--version")) {
            Console.WriteLine("tasks 9.9.9-stub");
            return 0;
        }
        if (args.Contains("viewer") && args.Contains("info")) {
            Console.WriteLine("{\"schema_version\":1,\"project_id\":null,\"data\":{\"protocol_version\":9}}");
            return 0;
        }
        Console.Error.WriteLine("unexpected arguments");
        return 9;
    }
}
'@
        New-FakeExecutable -Path (Join-Path -Path $Root -ChildPath 'tasks_viewer.exe') -Source $viewerSource
        New-FakeExecutable -Path (Join-Path -Path $Root -ChildPath 'tasks.exe') -Source $cliSource
        New-Item -ItemType Directory -Force -Path (Join-Path -Path $Root -ChildPath 'data') | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $Root -ChildPath 'data/marker.txt') -Value 'stub payload' -Encoding utf8NoBOM -Force
    }
}

Describe 'package.ps1 output root guard' {
    BeforeEach {
        $script:Root = New-PackageTestRoot
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'accepts an output root inside the target tree' {
        $allowed = Join-Path -Path $script:Root -ChildPath 'target'
        New-Item -ItemType Directory -Force -Path $allowed | Out-Null
        $resolved = Resolve-PackageOutputRoot -Path (Join-Path $allowed 'viewer-release') -AllowedRoot $allowed
        $resolved | Should -Be (Join-Path $allowed 'viewer-release')
    }

    It 'refuses an output root outside the target tree' {
        $allowed = Join-Path -Path $script:Root -ChildPath 'target'
        New-Item -ItemType Directory -Force -Path $allowed | Out-Null
        { Resolve-PackageOutputRoot -Path (Join-Path $script:Root 'elsewhere') -AllowedRoot $allowed } |
            Should -Throw -ExpectedMessage '*must stay inside*'
    }

    It 'refuses the target tree itself' {
        $allowed = Join-Path -Path $script:Root -ChildPath 'target'
        New-Item -ItemType Directory -Force -Path $allowed | Out-Null
        { Resolve-PackageOutputRoot -Path $allowed -AllowedRoot $allowed } |
            Should -Throw -ExpectedMessage '*must stay inside*'
    }

    It 'refuses a system directory' {
        $allowed = Join-Path -Path $script:Root -ChildPath 'target'
        New-Item -ItemType Directory -Force -Path $allowed | Out-Null
        { Resolve-PackageOutputRoot -Path 'C:\Windows' -AllowedRoot $allowed } | Should -Throw
    }
}

Describe 'package.ps1 bundle helpers' {
    BeforeEach {
        $script:Root = New-PackageTestRoot
        $script:Bundle = Join-Path -Path $script:Root -ChildPath 'bundle'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Bundle 'data') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Bundle 'tasks_viewer.exe') -Value 'stub' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:Bundle 'data/app.so') -Value 'stub payload' -Encoding utf8NoBOM
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns slash-separated relative paths and rejects outside files' {
        $inside = Join-Path -Path $script:Bundle -ChildPath 'data/app.so'
        Get-BundleRelativePath -Root $script:Bundle -Path $inside | Should -Be 'data/app.so'
        $outside = Join-Path -Path $script:Root -ChildPath 'outside.txt'
        Set-Content -LiteralPath $outside -Value 'x' -Encoding utf8NoBOM
        { Get-BundleRelativePath -Root $script:Bundle -Path $outside } | Should -Throw -ExpectedMessage '*not inside*'
    }

    It 'finds a credentialed file and accepts a clean tree' {
        $clean = Find-BundleCredential -Root $script:Bundle
        @($clean).Count | Should -Be 0
        Set-Content -LiteralPath (Join-Path $script:Bundle 'data/leak.json') `
            -Value '{"key": "ELEVENLABS_API_KEY"}' -Encoding utf8NoBOM
        $findings = Find-BundleCredential -Root $script:Bundle
        @($findings).Count | Should -Be 1
        @($findings)[0] | Should -BeLike '*data/leak.json*'
    }

    It 'writes a hash list that matches Get-FileHash and excludes itself' {
        $hashPath = Join-Path -Path $script:Bundle -ChildPath 'SHA256SUMS.txt'
        Write-BundleHashFile -Root $script:Bundle -HashPath $hashPath
        $lines = Get-Content -LiteralPath $hashPath
        @($lines).Count | Should -Be 2
        foreach ($line in $lines) {
            $line | Should -Match '^[0-9a-f]{64}  [^\s].*$'
            $parts = $line -split '  ', 2
            $expected = (Get-FileHash -LiteralPath (Join-Path $script:Bundle ($parts[1] -replace '/', '\')) -Algorithm SHA256).Hash.ToLowerInvariant()
            $parts[0] | Should -Be $expected
        }
        ($lines -join "`n") | Should -Not -Match 'SHA256SUMS.txt'
    }

    It 'writes an opt-out settings document for the launch probe' {
        $settingsRoot = Get-BundleSettingsRoot -Root $script:Root
        $document = Get-Content -LiteralPath (Join-Path $settingsRoot 'viewer-settings.json') -Raw | ConvertFrom-Json
        $document.schema_version | Should -Be 1
        $document.start_with_windows | Should -BeFalse
    }

    It 'copies the runner tree and adds the matching CLI' {
        $destination = Join-Path -Path $script:Root -ChildPath 'out'
        $cli = Join-Path -Path $script:Root -ChildPath 'tasks.exe'
        Set-Content -LiteralPath $cli -Value 'stub cli' -Encoding utf8NoBOM
        Copy-PackageBundle -SourceRoot $script:Bundle -CliExecutable $cli -DestinationRoot $destination
        Test-Path -LiteralPath (Join-Path $destination 'tasks_viewer.exe') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $destination 'data/app.so') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $destination 'tasks.exe') -PathType Leaf | Should -BeTrue
    }
}

Describe 'package.ps1 launch probe' {
    BeforeEach {
        $script:Root = New-PackageTestRoot
        $script:Bundle = Join-Path -Path $script:Root -ChildPath 'bundle'
        New-FakeBundle -Root $script:Bundle
        $script:Working = Join-Path -Path $script:Root -ChildPath 'work'
        New-Item -ItemType Directory -Force -Path $script:Working | Out-Null
    }

    AfterEach {
        Remove-Item Env:FAKE_VIEWER_STARTUP_EXIT -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_VIEWER_SLEEP_SECONDS -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'passes a bundle whose launch paths behave' {
        $result = Invoke-BundleLaunchTest -BundleRoot $script:Bundle -WorkingRoot $script:Working -TimeoutSeconds 60
        $result.Ok | Should -BeTrue
        @($result.Cases).Count | Should -Be 4
        $result.ProtocolVersion | Should -Be 9
        $result.LaunchRoot | Should -BeLike '*gęślą*'
        $result.LaunchRoot | Should -BeLike '* *'
    }

    It 'fails and kills the process when a launch path never returns' {
        $env:FAKE_VIEWER_SLEEP_SECONDS = '30'
        $result = Invoke-BundleLaunchTest -BundleRoot $script:Bundle -WorkingRoot $script:Working -TimeoutSeconds 1
        $startupCase = $result.Cases | Where-Object { $_.Name -eq 'startup-opt-out' }
        $startupCase.TimedOut | Should -BeTrue
        $result.Ok | Should -BeFalse
    }

    It 'fails when the viewer start-up path reports an error' {
        $env:FAKE_VIEWER_STARTUP_EXIT = '3'
        $result = Invoke-BundleLaunchTest -BundleRoot $script:Bundle -WorkingRoot $script:Working -TimeoutSeconds 30
        $result.Ok | Should -BeFalse
        ($result.Cases | Where-Object { $_.Name -eq 'startup-opt-out' }).Ok | Should -BeFalse
    }
}

Describe 'package.ps1 batch guards' {
    BeforeEach {
        $script:Root = New-PackageTestRoot
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reports missing inputs instead of writing a bundle' {
        $outputRoot = Join-Path -Path $script:Root -ChildPath 'target/viewer-release'
        $result = Invoke-PackageTool -ViewerRoot (Join-Path $script:Root 'viewer') `
            -RepositoryRoot $script:Root -OutputRoot $outputRoot
        $result.Ok | Should -BeFalse
        @($result.Findings).Count | Should -BeGreaterThan 0
        Test-Path -LiteralPath $outputRoot | Should -BeFalse
    }
}
