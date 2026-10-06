#requires -Version 7.0
<#
.SYNOPSIS
Verifies the downloaded viewer's native accessibility tree on Windows 11.
.DESCRIPTION
Run after checking the archive checksum and extracting its complete directory.
Uses a unique temporary backlog and settings root. No Flutter SDK is required.
Opens the candidate and Settings without keyboard, pointer or NVDA input.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundleRoot,
    [string]$EvidenceRoot
)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$requestedEvidenceRoot = $EvidenceRoot
. (Join-Path $repository 'viewer/tool/verify-windows.ps1')
$bundle = [IO.Path]::GetFullPath($BundleRoot)
$EvidenceRoot = $requestedEvidenceRoot
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $EvidenceRoot = Join-Path $repository ('target/evidence/release-viewer-' + [guid]::NewGuid().ToString('n'))
}
$evidence = [IO.Path]::GetFullPath($EvidenceRoot)
if (Test-Path -LiteralPath $evidence) { throw 'Use a new evidence directory for this candidate.' }
$null = New-Item -ItemType Directory -Path $evidence
$hashes = Assert-BundleHash -BundleRoot $bundle
if ($hashes.Findings.Count -gt 0) { throw ($hashes.Findings -join ' ') }
$working = [IO.Path]::GetTempPath()
$fixtureRoot = Resolve-VerifyFixtureRoot -WorkingRoot $working -RepositoryRoot $repository
try {
    $fixture = Initialize-ViewerVerifyFixture -FixtureRoot $fixtureRoot -CliExecutable (Join-Path $bundle 'tasks.exe') `
        -Seed 20260922 -AlphaTaskCount 28 -BetaTaskCount 4 -CommandTimeoutSeconds 120
    $manifest = Get-Content -LiteralPath $fixture.ManifestPath -Raw | ConvertFrom-Json
    $alpha = $manifest.projects[0]
    $arguments = @('-NoProfile', '-File', (Join-Path $repository 'viewer/tool/verify-release-uia.ps1'),
        '-BundleRoot', $bundle, '-DataRoot', $fixtureRoot, '-SettingsRoot', $fixture.SettingsRoot,
        '-ExpectedProjectName', "$($alpha.name) ($($alpha.project_key))",
        '-ExpectedOpenCount', [string]$fixture.AlphaOpen, '-ExpectedTotalCount', [string]$fixture.AlphaTotal,
        '-TimeoutSeconds', '45')
    $result = Invoke-CapturedProcess -FilePath (Get-Command pwsh).Source -Arguments $arguments `
        -WorkingDirectory $repository -TimeoutSeconds 105
    $null = Write-GateLog -EvidenceRoot $evidence -Name 'release-uia.txt' `
        -Text (Format-GateLog -Command 'verify-release-uia.ps1 (downloaded candidate)' -Result $result)
    if ($result.TimedOut -or $result.ExitCode -ne 0) { throw "Viewer accessibility failed; see $evidence/release-uia.txt" }
    $proof = $result.StdOut | ConvertFrom-Json
    if (-not $proof.Ok -or -not $proof.SettingsChecks.Ok) { throw 'The viewer or Settings accessibility check failed.' }
    $metadata = Get-Content -LiteralPath (Join-Path $bundle 'bundle-metadata.json') -Raw | ConvertFrom-Json
    $proof | Add-Member -NotePropertyName SourceCommit -NotePropertyValue $metadata.source_commit
    $proof | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evidence 'release-uia.json') -Encoding utf8NoBOM
    Write-Output "Passed: $($proof.NodeCount) native $($proof.AccessibilityBackend) nodes and Settings. Evidence: $evidence"
}
finally {
    $null = Clear-ViewerVerifyFixture -FixtureRoot $fixtureRoot -WorkingRoot $working -RepositoryRoot $repository
}
