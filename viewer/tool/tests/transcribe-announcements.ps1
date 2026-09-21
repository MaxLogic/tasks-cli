#Requires -Version 7.0
<#
.SYNOPSIS
Evidence helper: transcribes every bundled clip back to text.

.DESCRIPTION
Development-time check that supports the V13 "listen to every generated file"
requirement. It sends each committed MP3 to the ElevenLabs speech-to-text API
and compares the transcript with the catalog text after normalisation. It is
not part of the shipped application, needs ELEVENLABS_API_KEY and writes a JSON
record. Human listening confirmation is still recorded separately.
#>
[CmdletBinding()]
param(
    [string]$AnnouncementsDirectory = (Join-Path -Path $PSScriptRoot -ChildPath '../../assets/announcements'),

    [string]$OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../../target/evidence/viewer/2026-09-21-bella-generation/speech-transcripts.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-ComparableText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $normalised = $Text.ToLowerInvariant()
    $normalised = [System.Text.RegularExpressions.Regex]::Replace($normalised, '[^\p{L}\p{Nd}\s]', ' ')
    return ([System.Text.RegularExpressions.Regex]::Replace($normalised, '\s+', ' ')).Trim()
}

$apiKey = $env:ELEVENLABS_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Error 'ELEVENLABS_API_KEY is not set; transcription only runs in the authorized environment.'
    exit 1
}

$catalog = Get-Content -LiteralPath (Join-Path $AnnouncementsDirectory 'catalog.json') -Raw | ConvertFrom-Json
$records = foreach ($entry in $catalog.entries) {
    $clipPath = Join-Path $AnnouncementsDirectory "$($entry.id).mp3"
    if (-not (Test-Path -LiteralPath $clipPath -PathType Leaf)) {
        throw "Missing clip '$clipPath'."
    }
    $response = Invoke-RestMethod -Method Post -Uri 'https://api.elevenlabs.io/v1/speech-to-text' `
        -Headers @{ 'xi-api-key' = $apiKey } `
        -Form @{ file = Get-Item -LiteralPath $clipPath; model_id = 'scribe_v1' } -TimeoutSec 120
    $transcript = [string]$response.text
    [pscustomobject][ordered]@{
        id         = $entry.id
        expected   = $entry.text
        transcript = $transcript
        match      = ((ConvertTo-ComparableText -Text $transcript) -ceq (ConvertTo-ComparableText -Text $entry.text))
        file       = [System.IO.Path]::GetFileName($clipPath)
        sha256     = (Get-FileHash -LiteralPath $clipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$report = [ordered]@{
    generated_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    model_id      = 'scribe_v1'
    clips         = @($records)
    mismatches    = @($records | Where-Object { -not $_.match } | ForEach-Object { $_.id })
}

$directory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding utf8

Write-Output "transcripts: $($records.Count) clips, $($report.mismatches.Count) mismatch(es) -> $OutputPath"
if ($report.mismatches.Count -gt 0) {
    exit 1
}
exit 0
