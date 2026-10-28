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

Describe 'package.ps1 unnamed-stream copy' {
    BeforeEach {
        $script:Root = New-PackageTestRoot
        $script:Source = Join-Path $script:Root 'source'
        New-Item -ItemType Directory -Path $script:Source | Out-Null
        $script:PayloadFile = Join-Path $script:Source 'payload.bin'
        $script:Cli = Join-Path $script:Root 'tasks.exe'
        Set-Content $script:PayloadFile 'validated payload'
        Set-Content $script:Cli 'validated cli'
    }
    AfterEach { Remove-Item -LiteralPath $script:Root -Recurse -Force }

    It 'copies only unnamed streams when ADS is added <Timing> stamping' -ForEach @(
        @{ Timing = 'before' }
        @{ Timing = 'after' }
    ) {
        if ($Timing -eq 'before') {
            Set-Content -LiteralPath $script:PayloadFile -Stream unvalidated -Value 'secret payload stream'
            Set-Content -LiteralPath $script:Cli -Stream unvalidated -Value 'secret cli stream'
        }
        @{ bundle_files = @(Get-PackageBundleManifest -Root $script:Source) } |
            ConvertTo-Json | Set-Content (Join-Path $script:Source 'viewer-build-stamp.json')
        if ($Timing -eq 'after') {
            Set-Content -LiteralPath $script:PayloadFile -Stream unvalidated -Value 'secret payload stream'
            Set-Content -LiteralPath $script:Cli -Stream unvalidated -Value 'secret cli stream'
        }
        $out = Join-Path $script:Root 'out'
        Copy-PackageBundle -SourceRoot $script:Source -CliExecutable $script:Cli -DestinationRoot $out
        foreach ($file in Get-ChildItem -LiteralPath $out -Recurse -File -Force) {
            @(Get-Item -LiteralPath $file.FullName -Stream * | Where-Object Stream -NE ':$DATA').Count | Should -Be 0
        }
        (Get-FileHash (Join-Path $out 'payload.bin')).Hash | Should -Be (Get-FileHash $script:PayloadFile).Hash
        (Get-FileHash (Join-Path $out 'tasks.exe')).Hash | Should -Be (Get-FileHash $script:Cli).Hash
        # The source ADS really existed and has not been removed to make the test pass.
        Get-Content -LiteralPath $script:PayloadFile -Stream unvalidated | Should -Be 'secret payload stream'
        Get-Content -LiteralPath $script:Cli -Stream unvalidated | Should -Be 'secret cli stream'
    }

    It 'rejects a hash mismatch from the bytes actually copied' {
        $out = Join-Path $script:Root 'copied.bin'
        { Copy-PackageFile -SourcePath $script:PayloadFile -DestinationPath $out -ExpectedSha256 ('0' * 64) } |
            Should -Throw '*copied bundle manifest mismatch*'
    }

    It 'refuses explicitly named stream paths for either side of the copy' {
        Set-Content -LiteralPath $script:PayloadFile -Stream unvalidated -Value 'named bytes'
        $out = Join-Path $script:Root 'copied.bin'
        { Copy-PackageFile -SourcePath "$($script:PayloadFile):unvalidated" -DestinationPath $out `
                -ExpectedSha256 (Get-FileHash $script:PayloadFile).Hash } | Should -Throw '*unnamed data stream*'
        { Copy-PackageFile -SourcePath $script:PayloadFile -DestinationPath "$($out):unvalidated" `
                -ExpectedSha256 (Get-FileHash $script:PayloadFile).Hash } | Should -Throw '*unnamed data stream*'
        Test-Path $out | Should -BeFalse
    }

    It 'creates a new file instead of reusing a destination with an ADS' {
        $out = Join-Path $script:Root 'existing.bin'
        Set-Content $out 'existing'
        Set-Content -LiteralPath $out -Stream unvalidated -Value 'existing ADS'
        { Copy-PackageFile -SourcePath $script:PayloadFile -DestinationPath $out `
                -ExpectedSha256 (Get-FileHash $script:PayloadFile).Hash } | Should -Throw '*already exists*'
        Get-Content $out | Should -Be 'existing'
        Get-Content -LiteralPath $out -Stream unvalidated | Should -Be 'existing ADS'
    }
}

Describe 'package.ps1 exact bundle traversal' {
    BeforeEach {
        $script:Root = New-PackageTestRoot
        $script:Links = @()
        $script:Source = Join-Path $script:Root 'source'
        $script:Payload = Join-Path $script:Root 'payload'
        New-Item -ItemType Directory -Path $script:Source, $script:Payload | Out-Null
        Set-Content (Join-Path $script:Payload 'payload.bin') 'original'
        $script:Cli = Join-Path $script:Root 'tasks.exe'
        Set-Content $script:Cli 'cli'
    }
    AfterEach {
        foreach ($link in $script:Links) { Remove-Item -LiteralPath $link -Force }
        Remove-Item -LiteralPath $script:Root -Recurse -Force
    }
    It 'refuses <Kind> during hashing and copying' -ForEach @(
        @{ Kind = 'junction-backed replacement' }
        @{ Kind = 'symlinked file' }
        @{ Kind = 'nested junction' }
        @{ Kind = 'ancestor junction' }
    ) {
        $link = Join-Path $script:Source 'data'
        switch ($Kind) {
            'junction-backed replacement' {
                New-Item -ItemType Junction -Path $link -Target $script:Payload | Out-Null
            }
            'symlinked file' {
                $link = Join-Path $script:Source 'payload.bin'
                New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $script:Payload 'payload.bin') | Out-Null
            }
            'nested junction' {
                New-Item -ItemType Directory -Path (Join-Path $script:Source 'nested') | Out-Null
                $link = Join-Path $script:Source 'nested/data'
                New-Item -ItemType Junction -Path $link -Target $script:Payload | Out-Null
            }
            'ancestor junction' {
                $link = Join-Path $script:Root 'redirected'
                New-Item -ItemType Junction -Path $link -Target $script:Root | Out-Null
                $script:Source = Join-Path $link 'source'
            }
        }
        $script:Links += $link
        { Get-PackageBundleManifest -Root $script:Source } | Should -Throw '*bundle*reparse point*'
        Set-Content (Join-Path $script:Payload 'payload.bin') 'replacement'
        { Get-PackageBundleManifest -Root $script:Source } | Should -Throw '*bundle*reparse point*'
        $out = Join-Path $script:Root 'out'
        { Copy-PackageBundle -SourceRoot $script:Source -CliExecutable $script:Cli -DestinationRoot $out } |
            Should -Throw '*bundle*reparse point*'
        Test-Path $out | Should -BeFalse
        { Invoke-PackageTool -ViewerRoot $script:Root -RepositoryRoot $script:Root -PackageSourceRoot $script:Source } |
            Should -Throw '*bundle*reparse point*'
    }

    It 'copies exactly the manifested payload set over generated directory trees (seed 4702, 12 cases)' {
        $random = [Random]::new(4702)
        foreach ($case in 0..11) {
            $source = Join-Path $script:Source "case-$case"
            $out = Join-Path $script:Root "out-$case"
            New-Item -ItemType Directory -Path $source | Out-Null
            foreach ($index in 0..($random.Next(1, 12))) {
                $relative = ('level-{0}/child {1}/file-{2}.bin' -f $random.Next(0, 4), $random.Next(0, 4), $index)
                $path = Join-Path $source $relative
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                $bytes = [byte[]]::new($random.Next(0, 1024))
                $random.NextBytes($bytes)
                [IO.File]::WriteAllBytes($path, $bytes)
            }
            Set-Content (Join-Path $source 'viewer-build-stamp.json') '{"fixture":true}'
            $manifest = @(Get-PackageBundleManifest -Root $source -IncludeStamp)
            Copy-PackageBundle -SourceRoot $source -CliExecutable $script:Cli -DestinationRoot $out
            $copied = @(Get-PackageBundleManifest -Root $out -IncludeStamp | Where-Object { $_ -notlike '*  tasks.exe' })
            $copied | Should -Be $manifest
            $actualFiles = @(Get-ChildItem -LiteralPath $out -Recurse -File)
            $actualFiles.Count | Should -Be ($manifest.Count + 1)
            (Get-FileHash (Join-Path $out 'tasks.exe')).Hash | Should -Be (Get-FileHash $script:Cli).Hash
        }
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

Describe 'package.ps1 source fingerprint' {
    BeforeEach {
        $script:Root = New-PackageTestRoot
        Mock Get-FileSha256 { throw 'Fingerprint must work before the announcement tool is loaded.' }
        & git -C $script:Root init --quiet
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'lib'), (Join-Path $script:Root 'windows') | Out-Null
        Set-Content (Join-Path $script:Root 'pubspec.yaml') 'name: fixture'
        Set-Content (Join-Path $script:Root 'lib/main.dart') 'original source'
        Set-Content (Join-Path $script:Root 'windows/runner.cpp') 'original runner'
        & git -C $script:Root add .
    }
    AfterEach { Remove-Item -LiteralPath $script:Root -Recurse -Force }
    It 'changes for dirty Dart, pubspec, Windows and untracked source inputs' {
        $previous = Get-ViewerSourceFingerprint -ViewerRoot $script:Root
        foreach ($relative in @('lib/main.dart', 'pubspec.yaml', 'windows/runner.cpp', 'lib/new.dart')) {
            Set-Content (Join-Path $script:Root $relative) 'changed source'
            $current = Get-ViewerSourceFingerprint -ViewerRoot $script:Root
            $current | Should -Not -Be $previous
            $previous = $current
        }
    }
    It 'ignores generated release output and is stable for unchanged sources' {
        $before = Get-ViewerSourceFingerprint -ViewerRoot $script:Root
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'build') | Out-Null
        Set-Content (Join-Path $script:Root 'build/output.exe') 'generated'
        Get-ViewerSourceFingerprint -ViewerRoot $script:Root | Should -Be $before
    }
}

Describe 'package.ps1 batch guards' {
    BeforeEach {
        $script:Root = New-PackageTestRoot
        Mock Invoke-PackageFlutterBuild {}
        Mock Get-ViewerSourceFingerprint { 'fixture-inputs' }
        Mock Get-SourceIdentity { [pscustomobject]@{ Commit = 'fixture'; Dirty = $false } }
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reports missing inputs instead of writing a bundle' {
        $source = Join-Path $script:Root 'viewer/build/windows/x64/runner/Release'
        New-Item -ItemType Directory -Force -Path $source | Out-Null
        Set-Content (Join-Path $source 'tasks_viewer.exe') 'built stub'
        $outputRoot = Join-Path -Path $script:Root -ChildPath 'target/viewer-release'
        $result = Invoke-PackageTool -ViewerRoot (Join-Path $script:Root 'viewer') `
            -RepositoryRoot $script:Root -OutputRoot $outputRoot
        $result.Ok | Should -BeFalse
        @($result.Findings).Count | Should -BeGreaterThan 0
        Test-Path -LiteralPath $outputRoot | Should -BeFalse
    }

    It 'packages under lane roots and preserves existing output on copy corruption: <CorruptCopy>, ADS <StreamTiming>' -ForEach @(
        @{ CorruptCopy = 'none'; StreamTiming = 'none' }
        @{ CorruptCopy = 'replacement'; StreamTiming = 'none' }
        @{ CorruptCopy = 'missing'; StreamTiming = 'none' }
        @{ CorruptCopy = 'extra'; StreamTiming = 'none' }
        @{ CorruptCopy = 'source-during-copy'; StreamTiming = 'none' }
        @{ CorruptCopy = 'none'; StreamTiming = 'before' }
        @{ CorruptCopy = 'none'; StreamTiming = 'after' }
    ) {
        $repository = Join-Path $script:Root 'repository'
        $viewer = Join-Path $repository 'viewer'
        $lane = Join-Path $script:Root 'lane'
        $source = Join-Path $lane 'flutter-release'
        $cliTarget = Join-Path $lane 'rust'
        $output = Join-Path $lane 'nested/viewer-release'
        $evidence = Join-Path $lane 'evidence'
        New-FakeBundle -Root $source
        New-Item -ItemType Directory -Force -Path (Join-Path $cliTarget 'release'), (Join-Path $viewer 'assets/announcements') | Out-Null
        Copy-Item -LiteralPath (Join-Path $source 'tasks.exe') -Destination (Join-Path $cliTarget 'release/tasks.exe')
        foreach ($leaf in @('catalog.json', 'manifest.json')) {
            Set-Content -LiteralPath (Join-Path $viewer "assets/announcements/$leaf") -Value '{}'
        }
        $announcementTool = Join-Path $script:Root 'announcements-stub.ps1'
        Set-Content -LiteralPath $announcementTool -Value '# Announcement validation is mocked in this packaging-path test.'
        Mock Resolve-FfprobeExecutable { 'unused-ffprobe' }
        Mock Test-AnnouncementBundle { [pscustomobject]@{ Findings = @(); Verified = @([pscustomobject]@{ Bytes = 1 }) } }
        Mock Get-SourceIdentity { [pscustomobject]@{ Commit = 'fixture'; Dirty = $false } }

        $streamTargets = @((Join-Path $source 'tasks_viewer.exe'), (Join-Path $source 'data/marker.txt'), (Join-Path $cliTarget 'release/tasks.exe'))
        if ($StreamTiming -eq 'before') {
            foreach ($target in $streamTargets) { Set-Content -LiteralPath $target -Stream unvalidated -Value 'before stamping' }
        }
        @{ source_commit = 'fixture'; source_fingerprint = 'fixture-inputs' } |
            ConvertTo-Json | Set-Content (Join-Path $source 'viewer-build-stamp.json')
        # Matching source fields alone must not admit arbitrary stub executables.
        { Invoke-PackageTool -ViewerRoot $viewer -RepositoryRoot $repository `
                -CliTargetDirectory $cliTarget -PackageParentRoot $lane -PackageSourceRoot $source `
                -OutputRoot $output -EvidenceRoot $evidence -WorkingRoot $script:Root -AnnouncementToolPath $announcementTool } |
            Should -Throw '*prebuilt*bundle manifest*'
        Test-Path -LiteralPath $output | Should -BeFalse
        @{ source_commit = 'fixture'; source_fingerprint = 'fixture-inputs'
            bundle_files = @(Get-PackageBundleManifest -Root $source) } |
            ConvertTo-Json | Set-Content (Join-Path $source 'viewer-build-stamp.json')
        if ($StreamTiming -eq 'after') {
            foreach ($target in $streamTargets) { Set-Content -LiteralPath $target -Stream unvalidated -Value 'after stamping' }
        }
        if ($StreamTiming -ne 'none') {
            Set-Content -LiteralPath (Join-Path $source 'viewer-build-stamp.json') -Stream unvalidated -Value 'stamp ADS'
            New-Item -ItemType Directory -Force -Path $output | Out-Null
            Set-Content (Join-Path $output 'previous.bin') 'previous output'
            Set-Content -LiteralPath (Join-Path $output 'previous.bin') -Stream unvalidated -Value 'previous ADS'
        }
        $before = @(Get-ChildItem -LiteralPath $repository -Recurse -File | ForEach-Object { "$($_.FullName):$((Get-FileHash -LiteralPath $_.FullName).Hash)" })
        if ($CorruptCopy -ne 'none') {
            $script:CopyCorruption = $CorruptCopy
            $script:RealCopy = (Get-Command Copy-PackageBundle).ScriptBlock
            Mock Copy-PackageBundle {
                if ($script:CopyCorruption -eq 'source-during-copy') {
                    Set-Content (Join-Path $SourceRoot 'tasks_viewer.exe') 'source changed after validation'
                }
                & $script:RealCopy -SourceRoot $SourceRoot -CliExecutable $CliExecutable -DestinationRoot $DestinationRoot -ExpectedManifest $ExpectedManifest
                switch ($script:CopyCorruption) {
                    'replacement' { Set-Content (Join-Path $DestinationRoot 'tasks_viewer.exe') 'copy corrupted' }
                    'missing' { Remove-Item -LiteralPath (Join-Path $DestinationRoot 'tasks_viewer.exe') }
                    'extra' { Set-Content (Join-Path $DestinationRoot 'extra.bin') 'unexpected payload' }
                }
            }
            New-Item -ItemType Directory -Path $output | Out-Null
            Set-Content (Join-Path $output 'keep.txt') 'existing output'
            { Invoke-PackageTool -ViewerRoot $viewer -RepositoryRoot $repository `
                    -CliTargetDirectory $cliTarget -PackageParentRoot $lane -PackageSourceRoot $source `
                    -OutputRoot $output -EvidenceRoot $evidence -WorkingRoot $script:Root -AnnouncementToolPath $announcementTool } |
                Should -Throw '*copied bundle manifest*'
            Get-Content (Join-Path $output 'keep.txt') | Should -Be 'existing output'
            @(Get-ChildItem -LiteralPath $lane -Directory -Filter '.viewer-package-stage-*').Count | Should -Be 0
            return
        }
        $result = Invoke-PackageTool -ViewerRoot $viewer -RepositoryRoot $repository `
            -CliTargetDirectory $cliTarget -PackageParentRoot $lane -PackageSourceRoot $source `
            -OutputRoot $output -EvidenceRoot $evidence -WorkingRoot $script:Root -AnnouncementToolPath $announcementTool

        $result.Ok | Should -BeTrue
        foreach ($file in Get-ChildItem -LiteralPath $output -Recurse -File -Force) {
            @(Get-Item -LiteralPath $file.FullName -Stream * | Where-Object Stream -NE ':$DATA').Count | Should -Be 0
        }
        if ($StreamTiming -ne 'none') {
            Test-Path (Join-Path $output 'previous.bin') | Should -BeFalse
            foreach ($target in $streamTargets) {
                Get-Content -LiteralPath $target -Stream unvalidated | Should -Be "$StreamTiming stamping"
            }
        }
        $metadata = Get-Content (Join-Path $output 'bundle-metadata.json') -Raw | ConvertFrom-Json
        $metadata.source_commit | Should -Be 'fixture'
        $metadata.viewer_source_fingerprint | Should -Be 'fixture-inputs'
        Should -Invoke Invoke-PackageFlutterBuild -Times 0 -Exactly
        $result.OutputRoot | Should -Be $output
        $result.LaunchTest.Ok | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $evidence 'package-summary.json') | Should -BeTrue
        (Get-FileHash -LiteralPath (Join-Path $output 'tasks.exe')).Hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $cliTarget 'release/tasks.exe')).Hash
        $after = @(Get-ChildItem -LiteralPath $repository -Recurse -File | ForEach-Object { "$($_.FullName):$((Get-FileHash -LiteralPath $_.FullName).Hash)" })
        $after | Should -Be $before
        Test-Path -LiteralPath (Join-Path $repository 'target') | Should -BeFalse
    }

    It 'builds Flutter by default even if an old release directory exists' {
        $viewer = Join-Path $script:Root 'viewer'
        $source = Join-Path $viewer 'build/windows/x64/runner/Release'
        New-Item -ItemType Directory -Force -Path $source | Out-Null
        Set-Content (Join-Path $source 'tasks_viewer.exe') 'old bundle'
        # Missing CLI prevents packaging, but must never prevent the default rebuild.
        $result = Invoke-PackageTool -ViewerRoot $viewer -RepositoryRoot $script:Root
        $result.Ok | Should -BeFalse
        Should -Invoke Invoke-PackageFlutterBuild -Times 1 -Exactly -ParameterFilter { $ViewerRoot -eq $viewer }
    }

    It 'preserves existing output and invalidates the stamp when the default build fails' {
        $viewer = Join-Path $script:Root 'viewer'
        $source = Join-Path $viewer 'build/windows/x64/runner/Release'
        $output = Join-Path $script:Root 'target/viewer-release'
        New-Item -ItemType Directory -Force -Path $source, $output | Out-Null
        Set-Content (Join-Path $source 'viewer-build-stamp.json') '{}'
        Set-Content (Join-Path $output 'keep.txt') 'existing package'
        Mock Invoke-PackageFlutterBuild { throw 'intentional build failure' }
        { Invoke-PackageTool -ViewerRoot $viewer -RepositoryRoot $script:Root } |
            Should -Throw '*intentional build failure*'
        Test-Path (Join-Path $source 'viewer-build-stamp.json') | Should -BeFalse
        Get-Content (Join-Path $output 'keep.txt') | Should -Be 'existing package'
    }

    It 'refuses an unstamped prebuilt bundle without replacing existing output' {
        $source = Join-Path $script:Root 'prebuilt'
        $output = Join-Path $script:Root 'target/viewer-release'
        New-Item -ItemType Directory -Force -Path $source, $output | Out-Null
        Set-Content (Join-Path $output 'keep.txt') 'existing package'
        Mock Get-SourceIdentity { [pscustomobject]@{ Commit = 'fixture'; Dirty = $false } }
        { Invoke-PackageTool -ViewerRoot $script:Root -RepositoryRoot $script:Root -PackageSourceRoot $source } |
            Should -Throw '*prebuilt*stamp*'
        Get-Content (Join-Path $output 'keep.txt') | Should -Be 'existing package'
        Should -Invoke Invoke-PackageFlutterBuild -Times 0 -Exactly
    }

    It 'refuses a prebuilt bundle from another commit or older source inputs' -ForEach @(
        @{ Commit = 'old-commit'; Fingerprint = 'fixture-inputs' }
        @{ Commit = 'fixture'; Fingerprint = 'old-inputs' }
    ) {
        $source = Join-Path $script:Root 'prebuilt'
        New-Item -ItemType Directory -Force -Path $source | Out-Null
        @{ source_commit = $Commit; source_fingerprint = $Fingerprint } |
            ConvertTo-Json | Set-Content (Join-Path $source 'viewer-build-stamp.json')
        Mock Get-SourceIdentity { [pscustomobject]@{ Commit = 'fixture'; Dirty = $false } }
        { Invoke-PackageTool -ViewerRoot $script:Root -RepositoryRoot $script:Root -PackageSourceRoot $source } |
            Should -Throw '*prebuilt*stale*'
        Test-Path (Join-Path $script:Root 'target/viewer-release') | Should -BeFalse
    }

    It 'refuses a stamped bundle changed after building: <Change>' -ForEach @(
        @{ Change = 'replacement' }
        @{ Change = 'missing' }
        @{ Change = 'extra' }
    ) {
        $viewer = Join-Path $script:Root 'viewer'
        $source = Join-Path $viewer 'build/windows/x64/runner/Release'
        $output = Join-Path $script:Root 'target/viewer-release'
        New-Item -ItemType Directory -Force -Path (Join-Path $source 'data'), $output | Out-Null
        Set-Content (Join-Path $source 'tasks_viewer.exe') 'original executable'
        Set-Content (Join-Path $source 'data/payload.bin') 'original payload'
        Set-Content (Join-Path $output 'keep.txt') 'existing output'
        # Default build stamps the fixture before missing CLI/catalog inputs stop packaging.
        $result = Invoke-PackageTool -ViewerRoot $viewer -RepositoryRoot $script:Root
        $result.Ok | Should -BeFalse
        $stamp = Get-Content (Join-Path $source 'viewer-build-stamp.json') -Raw | ConvertFrom-Json
        @($stamp.bundle_files).Count | Should -Be 2
        $stamp.bundle_files[0] | Should -Be "$((Get-FileHash (Join-Path $source 'data/payload.bin')).Hash.ToLowerInvariant())  data/payload.bin"
        $stamp.bundle_files[1] | Should -Be "$((Get-FileHash (Join-Path $source 'tasks_viewer.exe')).Hash.ToLowerInvariant())  tasks_viewer.exe"
        switch ($Change) {
            'replacement' { Set-Content (Join-Path $source 'tasks_viewer.exe') 'rebuilt from different dirty sources' }
            'missing' { Remove-Item -LiteralPath (Join-Path $source 'data/payload.bin') }
            'extra' { Set-Content (Join-Path $source 'data/extra.bin') 'unexpected payload' }
        }
        { Invoke-PackageTool -ViewerRoot $viewer -RepositoryRoot $script:Root -PackageSourceRoot $source } |
            Should -Throw '*prebuilt*bundle manifest*'
        Get-Content (Join-Path $output 'keep.txt') | Should -Be 'existing output'
    }

    It 'refuses an output outside the selected package parent before writing' {
        { Invoke-PackageTool -ViewerRoot $script:Root -RepositoryRoot $script:Root `
                -PackageParentRoot (Join-Path $script:Root 'lane') -OutputRoot (Join-Path $script:Root 'elsewhere') } |
            Should -Throw '*must stay inside*'
        Test-Path -LiteralPath (Join-Path $script:Root 'elsewhere') | Should -BeFalse
    }
}
