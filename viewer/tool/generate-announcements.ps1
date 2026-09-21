#requires -Version 7.0
<#
.SYNOPSIS
Generates or verifies the bundled ElevenLabs Bella announcement clips.

.DESCRIPTION
The viewer ships fixed spoken feedback as MP3 clips produced at development time
by ElevenLabs (viewer/spec.md section 9.1). This script keeps the fixed-text
catalog (assets/announcements/catalog.json), the generated clips and the
provenance manifest (assets/announcements/manifest.json) consistent.

Only -Generate talks to the network, and it requires ELEVENLABS_API_KEY in the
current process environment. The key is never written to the repository,
manifest, assets or logs, and it is never passed on the command line.
-VerifyOnly performs offline integrity checks and fails while any catalog entry
lacks a real, hash-verified clip with provenance.

.EXAMPLE
pwsh -NoProfile -File viewer/tool/generate-announcements.ps1 -VerifyOnly

.EXAMPLE
pwsh -NoProfile -File viewer/tool/generate-announcements.ps1 -Generate
#>
[CmdletBinding(DefaultParameterSetName = 'VerifyOnly')]
param(
    [Parameter(ParameterSetName = 'VerifyOnly')]
    [switch]$VerifyOnly,

    [Parameter(ParameterSetName = 'Generate')]
    [switch]$Generate,

    [string]$AnnouncementsDirectory = (Join-Path -Path $PSScriptRoot -ChildPath '../assets/announcements'),

    [string]$CatalogPath = (Join-Path -Path $PSScriptRoot -ChildPath '../assets/announcements/catalog.json'),

    [string]$FfprobePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredModelId {
    <#
    .SYNOPSIS
    Returns the required ElevenLabs model ID.
    #>
    return 'eleven_multilingual_v2'
}

function Write-AnnouncementMessage {
    <#
    .SYNOPSIS
    Writes one progress line to the host without polluting function output.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    Write-Information -MessageData $Message -InformationAction Continue
}

function Get-RequiredOutputFormat {
    <#
    .SYNOPSIS
    Returns the required ElevenLabs output format.
    #>
    return 'mp3_44100_128'
}

function Get-RequiredVoiceConfiguration {
    <#
    .SYNOPSIS
    Returns the required ElevenLabs voice settings as a hashtable.
    #>
    return [ordered]@{
        stability         = [double]0.5
        similarity_boost  = [double]0.75
        style             = [double]0.0
        use_speaker_boost = $true
    }
}

function Get-RequiredAnnouncementCatalog {
    <#
    .SYNOPSIS
    Returns the fixed catalog required by viewer/spec.md section 9.1.
    #>
    return @(
        [pscustomobject]@{ Id = 'saving'; Text = 'Saving' }
        [pscustomobject]@{ Id = 'task_saved'; Text = 'Task saved' }
        [pscustomobject]@{ Id = 'task_done'; Text = 'Task marked done' }
        [pscustomobject]@{ Id = 'no_changes'; Text = 'No changes needed' }
        [pscustomobject]@{ Id = 'clipboard_enriched'; Text = 'Clipboard enriched' }
        [pscustomobject]@{ Id = 'clipboard_unchanged'; Text = 'Clipboard unchanged' }
        [pscustomobject]@{ Id = 'preview_ready'; Text = 'Preview ready' }
        [pscustomobject]@{ Id = 'reference_copied'; Text = 'Task reference copied' }
        [pscustomobject]@{ Id = 'project_id_copied'; Text = 'Project ID copied' }
        [pscustomobject]@{ Id = 'settings_saved'; Text = 'Settings saved' }
        [pscustomobject]@{ Id = 'loading'; Text = 'Loading' }
        [pscustomobject]@{ Id = 'refreshing'; Text = 'Refreshing' }
        [pscustomobject]@{ Id = 'refreshed'; Text = 'Refreshed' }
        [pscustomobject]@{ Id = 'no_matching_projects'; Text = 'No projects match these filters' }
        [pscustomobject]@{ Id = 'no_matching_tasks'; Text = 'No tasks match these filters' }
        [pscustomobject]@{ Id = 'no_tasks'; Text = 'This project has no tasks' }
        [pscustomobject]@{ Id = 'no_clipboard_text'; Text = 'Clipboard contains no text' }
        [pscustomobject]@{ Id = 'draft_restored'; Text = 'Draft restored' }
        [pscustomobject]@{ Id = 'draft_discarded'; Text = 'Draft discarded' }
        [pscustomobject]@{ Id = 'voice_test'; Text = 'This is Bella. Spoken announcements are enabled.' }
    )
}

function Get-PropertyValue {
    <#
    .SYNOPSIS
    Reads a named value from a hashtable or a JSON-derived object.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ("$key" -ceq $Name) {
                return $InputObject[$key]
            }
        }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Format-InvariantNumber {
    <#
    .SYNOPSIS
    Formats a number with invariant culture so hashes never depend on locale.
    #>
    param(
        [Parameter(Mandatory)]
        [double]$Value
    )

    return $Value.ToString('0.#####', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-VoiceSettingsSignature {
    <#
    .SYNOPSIS
    Returns a locale-independent signature for a voice-settings object.
    #>
    param(
        [object]$Settings
    )

    if ($null -eq $Settings) {
        return '<missing>'
    }
    $parts = foreach ($name in @('stability', 'similarity_boost', 'style', 'use_speaker_boost')) {
        $value = Get-PropertyValue -InputObject $Settings -Name $name
        if ($null -eq $value) {
            "$name=<missing>"
            continue
        }
        if ($value -is [bool]) {
            "$name=$($value.ToString().ToLowerInvariant())"
            continue
        }
        if ($value -is [ValueType]) {
            $number = [Convert]::ToDouble($value, [System.Globalization.CultureInfo]::InvariantCulture)
            "$name=$(Format-InvariantNumber -Value $number)"
            continue
        }
        "$name=$value"
    }
    return ($parts -join ',')
}

function Get-StringSha256 {
    <#
    .SYNOPSIS
    Returns the lowercase SHA-256 of a UTF-8 string.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return [Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FileSha256 {
    <#
    .SYNOPSIS
    Returns the lowercase SHA-256 of a file.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-AnnouncementConfigHash {
    <#
    .SYNOPSIS
    Hashes the text plus every generation-relevant setting for one clip.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$VoiceId,

        [Parameter(Mandatory)]
        [string]$ModelId,

        [Parameter(Mandatory)]
        [string]$OutputFormat,

        [Parameter(Mandatory)]
        [object]$VoiceSettings
    )

    $canonical = @(
        "text=$Text"
        "voice_id=$VoiceId"
        "model_id=$ModelId"
        "output_format=$OutputFormat"
        "voice_settings=$(Get-VoiceSettingsSignature -Settings $VoiceSettings)"
    ) -join "`n"
    return Get-StringSha256 -Value $canonical
}

function Test-AnnouncementCatalog {
    <#
    .SYNOPSIS
    Validates a parsed catalog object against the required fixed catalog.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Catalog,

        [object[]]$Required = (Get-RequiredAnnouncementCatalog)
    )

    $findings = [System.Collections.Generic.List[string]]::new()
    $entries = [System.Collections.Generic.List[object]]::new()
    $decodedEntries = @(Get-PropertyValue -InputObject $Catalog -Name 'entries')

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in $decodedEntries) {
        $id = Get-PropertyValue -InputObject $entry -Name 'id'
        $text = Get-PropertyValue -InputObject $entry -Name 'text'
        if ($id -isnot [string] -or [string]::IsNullOrWhiteSpace($id)) {
            $findings.Add('Catalog entry is missing a non-empty "id" string.')
            continue
        }
        if ($text -isnot [string] -or [string]::IsNullOrEmpty($text)) {
            $findings.Add("Catalog entry '$id' is missing a non-empty 'text' string.")
            continue
        }
        if (-not $seen.Add($id)) {
            $findings.Add("Catalog contains duplicate id '$id'.")
            continue
        }
        $entries.Add([pscustomobject]@{ Id = $id; Text = $text })
    }

    foreach ($requiredEntry in $Required) {
        $match = $entries | Where-Object { $_.Id -eq $requiredEntry.Id }
        if ($null -eq $match) {
            $findings.Add("Catalog is missing required id '$($requiredEntry.Id)'.")
            continue
        }
        if ($match.Text -cne $requiredEntry.Text) {
            $findings.Add(
                "Catalog text for '$($requiredEntry.Id)' is '$($match.Text)' " +
                "but viewer/spec.md section 9.1 requires '$($requiredEntry.Text)'.")
        }
    }

    $requiredIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($requiredEntry in $Required) {
        [void]$requiredIds.Add($requiredEntry.Id)
    }
    foreach ($entry in $entries) {
        if (-not $requiredIds.Contains($entry.Id)) {
            $findings.Add(
                "Catalog contains '$($entry.Id)' which viewer/spec.md section 9.1 does not list. " +
                'Add new fixed feedback phrases to the spec table first.')
        }
    }

    return [pscustomobject]@{
        Ok       = ($findings.Count -eq 0)
        Findings = $findings
        Entries  = $entries
    }
}

function Get-AnnouncementCatalogFile {
    <#
    .SYNOPSIS
    Reads and validates assets/announcements/catalog.json.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$CatalogPath
    )

    if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
        throw "Announcement catalog '$CatalogPath' does not exist."
    }
    try {
        $catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 32
    }
    catch {
        throw "Announcement catalog '$CatalogPath' is not valid JSON: $($_.Exception.Message)"
    }
    $result = Test-AnnouncementCatalog -Catalog $catalog
    if (-not $result.Ok) {
        throw "Announcement catalog '$CatalogPath' is invalid:`n - $($result.Findings -join "`n - ")"
    }
    return [pscustomobject]@{
        Voice        = [string](Get-PropertyValue -InputObject $catalog -Name 'voice')
        ModelId      = [string](Get-PropertyValue -InputObject $catalog -Name 'model_id')
        OutputFormat = [string](Get-PropertyValue -InputObject $catalog -Name 'output_format')
        Entries      = $result.Entries
    }
}

function Get-AnnouncementManifestFile {
    <#
    .SYNOPSIS
    Reads manifest.json, returning $null when it does not exist yet.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 32
    }
    catch {
        throw "Announcement manifest '$Path' is not valid JSON: $($_.Exception.Message)"
    }
}

function Export-AnnouncementManifest {
    <#
    .SYNOPSIS
    Writes manifest.json with a trailing newline.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$Manifest
    )

    $json = $Manifest | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Path -Value ($json + "`n") -Encoding utf8 -NoNewline
}

function Resolve-FfprobeExecutable {
    <#
    .SYNOPSIS
    Resolves the ffprobe executable used to validate generated audio.
    #>
    param(
        [string]$FfprobePath
    )

    if (-not [string]::IsNullOrWhiteSpace($FfprobePath)) {
        if (-not (Test-Path -LiteralPath $FfprobePath -PathType Leaf)) {
            throw "ffprobe was not found at '$FfprobePath'."
        }
        return (Resolve-Path -LiteralPath $FfprobePath).Path
    }
    $command = Get-Command -Name 'ffprobe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) {
        throw 'ffprobe is required to validate generated MP3 clips but was not found on PATH. Install ffmpeg/ffprobe or pass -FfprobePath.'
    }
    return $command.Source
}

function Get-AudioFileInfo {
    <#
    .SYNOPSIS
    Probes an audio file and returns codec, rate, channels and duration.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$FfprobeExecutable
    )

    $arguments = @(
        '-v', 'error'
        '-select_streams', 'a:0'
        '-show_entries', 'stream=codec_name,sample_rate,bit_rate,channels'
        '-show_entries', 'format=duration'
        '-of', 'json'
        $Path
    )
    $output = & $FfprobeExecutable @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ffprobe rejected '$Path': $($output -join ' ')"
    }
    $document = ($output -join "`n") | ConvertFrom-Json -Depth 8
    $stream = @($document.streams) | Select-Object -First 1
    if ($null -eq $stream) {
        throw "ffprobe found no audio stream in '$Path'."
    }
    $duration = [double]::Parse(
        [string](Get-PropertyValue -InputObject $document.format -Name 'duration'),
        [System.Globalization.CultureInfo]::InvariantCulture)
    $bitRate = 0
    $streamBitRate = Get-PropertyValue -InputObject $stream -Name 'bit_rate'
    if ($null -ne $streamBitRate) {
        $bitRate = [int][Math]::Round(
            [double]::Parse([string]$streamBitRate, [System.Globalization.CultureInfo]::InvariantCulture) / 1000.0)
    }
    return [pscustomobject]@{
        Codec         = [string](Get-PropertyValue -InputObject $stream -Name 'codec_name')
        SampleRate    = [int](Get-PropertyValue -InputObject $stream -Name 'sample_rate')
        Channels      = [int](Get-PropertyValue -InputObject $stream -Name 'channels')
        BitRateKbps   = $bitRate
        Duration      = $duration
    }
}

function Get-ElevenLabsVoicePage {
    <#
    .SYNOPSIS
    Lists account voices through the ElevenLabs voices API.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ApiKey
    )

    try {
        $response = Invoke-RestMethod -Method Get `
            -Uri 'https://api.elevenlabs.io/v2/voices?page_size=100' `
            -Headers @{ 'xi-api-key' = $ApiKey } -TimeoutSec 60
    }
    catch {
        throw "Listing ElevenLabs voices failed: $($_.Exception.Message)"
    }
    return @(Get-PropertyValue -InputObject $response -Name 'voices')
}

function Get-BellaVoice {
    <#
    .SYNOPSIS
    Resolves the Bella voice, honouring a manifest-pinned voice ID.
    #>
    param(
        [Parameter(Mandatory)]
        [object[]]$Voices,

        [string]$PinnedVoiceId
    )

    $candidates = @($Voices | Where-Object {
            $name = [string](Get-PropertyValue -InputObject $_ -Name 'name')
            $name -match '^Bella\b'
        })

    if (-not [string]::IsNullOrWhiteSpace($PinnedVoiceId)) {
        $pinned = @($Voices | Where-Object {
                [string](Get-PropertyValue -InputObject $_ -Name 'voice_id') -ceq $PinnedVoiceId
            })
        if ($pinned.Count -eq 0) {
            throw "The manifest pins Bella voice ID '$PinnedVoiceId' but the account no longer exposes it. Generation stays pending: resolve voice access or re-pin the intended Bella voice explicitly; never silently substitute another voice."
        }
        $pinnedName = [string](Get-PropertyValue -InputObject $pinned[0] -Name 'name')
        if ($pinnedName -notmatch '^Bella\b') {
            throw "The manifest-pinned voice '$PinnedVoiceId' is now named '$pinnedName', which is not Bella."
        }
        return $pinned[0]
    }

    if ($candidates.Count -eq 0) {
        throw 'The ElevenLabs account exposes no voice named Bella. Generation stays pending until access is resolved.'
    }
    if ($candidates.Count -gt 1) {
        $described = ($candidates | ForEach-Object {
                "$([string](Get-PropertyValue -InputObject $_ -Name 'name')) [$([string](Get-PropertyValue -InputObject $_ -Name 'voice_id'))]"
            }) -join ', '
        throw "The account exposes multiple Bella candidates ($described). Generation stays pending until the intended voice is identified; pin the correct voice ID in manifest.json explicitly."
    }
    return $candidates[0]
}

function Get-SpeechRequestBody {
    <#
    .SYNOPSIS
    Builds the Create speech JSON body with invariant number formatting.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$ModelId,

        [Parameter(Mandatory)]
        [object]$VoiceSettings
    )

    $document = [ordered]@{
        text           = $Text
        model_id       = $ModelId
        voice_settings = [ordered]@{
            stability         = [double](Get-PropertyValue -InputObject $VoiceSettings -Name 'stability')
            similarity_boost  = [double](Get-PropertyValue -InputObject $VoiceSettings -Name 'similarity_boost')
            style             = [double](Get-PropertyValue -InputObject $VoiceSettings -Name 'style')
            use_speaker_boost = [bool](Get-PropertyValue -InputObject $VoiceSettings -Name 'use_speaker_boost')
        }
    }
    return ($document | ConvertTo-Json -Depth 6 -Compress)
}

function Invoke-ElevenLabsSpeech {
    <#
    .SYNOPSIS
    Requests one MP3 clip and returns the temporary file plus request ID.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ApiKey,

        [Parameter(Mandatory)]
        [string]$VoiceId,

        [Parameter(Mandatory)]
        [string]$OutputFormat,

        [Parameter(Mandatory)]
        [string]$RequestBody
    )

    $uri = "https://api.elevenlabs.io/v1/text-to-speech/$VoiceId`?output_format=$OutputFormat"
    $temporaryPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "elevenlabs-$([guid]::NewGuid().ToString('n')).mp3"
    try {
        $response = Invoke-WebRequest -Method Post -Uri $uri `
            -Headers @{ 'xi-api-key' = $ApiKey } `
            -ContentType 'application/json' -Body $RequestBody `
            -OutFile $temporaryPath -PassThru -TimeoutSec 180
    }
    catch {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        throw "ElevenLabs create-speech failed: $($_.Exception.Message)"
    }
    $requestId = ''
    $headerValue = Get-PropertyValue -InputObject $response.Headers -Name 'request-id'
    if ($null -ne $headerValue) {
        $requestId = (@($headerValue) | Select-Object -First 1) -as [string]
    }
    return [pscustomobject]@{
        TemporaryPath = $temporaryPath
        RequestId     = [string]$requestId
        StatusCode    = [int]$response.StatusCode
    }
}

function Get-AnnouncementManifestEntry {
    <#
    .SYNOPSIS
    Builds one manifest entry after a clip has been validated.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$FileName,

        [Parameter(Mandatory)]
        [object]$Voice,

        [Parameter(Mandatory)]
        [string]$ModelId,

        [Parameter(Mandatory)]
        [string]$OutputFormat,

        [Parameter(Mandatory)]
        [object]$VoiceSettings,

        [Parameter(Mandatory)]
        [object]$AudioInfo,

        [Parameter(Mandatory)]
        [string]$ApiVoiceId,

        [string]$RequestId = ''
    )

    $voiceName = [string](Get-PropertyValue -InputObject $Voice -Name 'name')
    $voiceCategory = [string](Get-PropertyValue -InputObject $Voice -Name 'category')
    return [ordered]@{
        id               = $Id
        text             = $Text
        text_sha256      = Get-StringSha256 -Value $Text
        config_sha256    = Get-AnnouncementConfigHash -Text $Text -VoiceId $ApiVoiceId -ModelId $ModelId -OutputFormat $OutputFormat -VoiceSettings $VoiceSettings
        file             = $FileName
        sha256           = Get-FileSha256 -Path $FilePath
        bytes            = (Get-Item -LiteralPath $FilePath).Length
        duration_seconds = [Math]::Round($AudioInfo.Duration, 3)
        codec            = $AudioInfo.Codec
        sample_rate_hz   = $AudioInfo.SampleRate
        channels         = $AudioInfo.Channels
        bitrate_kbps     = $AudioInfo.BitRateKbps
        voice_id         = $ApiVoiceId
        voice_name       = $voiceName
        voice_category   = $voiceCategory
        model_id         = $ModelId
        output_format    = $OutputFormat
        voice_settings   = $VoiceSettings
        generated_utc    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        request_id       = $RequestId
    }
}

function Test-AnnouncementBundle {
    <#
    .SYNOPSIS
    Offline verification of catalog, manifest and every referenced clip.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$AnnouncementsDirectory,

        [Parameter(Mandatory)]
        [string]$CatalogPath,

        [Parameter(Mandatory)]
        [string]$FfprobeExecutable
    )

    $findings = [System.Collections.Generic.List[string]]::new()
    $verified = [System.Collections.Generic.List[object]]::new()
    $catalog = Get-AnnouncementCatalogFile -CatalogPath $CatalogPath

    if ($catalog.ModelId -cne (Get-RequiredModelId)) {
        $findings.Add("Catalog model_id '$($catalog.ModelId)' is not '$(Get-RequiredModelId)'.")
    }
    if ($catalog.OutputFormat -cne (Get-RequiredOutputFormat)) {
        $findings.Add("Catalog output_format '$($catalog.OutputFormat)' is not '$(Get-RequiredOutputFormat)'.")
    }
    if ($catalog.Voice -cne 'Bella') {
        $findings.Add("Catalog voice '$($catalog.Voice)' is not Bella.")
    }

    $manifestPath = Join-Path -Path $AnnouncementsDirectory -ChildPath 'manifest.json'
    $manifest = Get-AnnouncementManifestFile -Path $manifestPath
    if ($null -eq $manifest) {
        $findings.Add("'$manifestPath' does not exist: no clip provenance is committed yet. Run -Generate in the authorized generation environment.")
        return [pscustomobject]@{ Ok = $false; Findings = $findings; Verified = $verified }
    }

    $voice = Get-PropertyValue -InputObject $manifest -Name 'voice'
    $voiceId = [string](Get-PropertyValue -InputObject $voice -Name 'id')
    $voiceName = [string](Get-PropertyValue -InputObject $voice -Name 'name')
    if ([string]::IsNullOrWhiteSpace($voiceId)) {
        $findings.Add('manifest.json is missing voice.id.')
    }
    if ($voiceName -notmatch '^Bella\b') {
        $findings.Add("manifest.json voice.name '$voiceName' is not Bella.")
    }
    $manifestModel = [string](Get-PropertyValue -InputObject $manifest -Name 'model_id')
    if ($manifestModel -cne $catalog.ModelId) {
        $findings.Add("manifest.json model_id '$manifestModel' does not match the catalog '$($catalog.ModelId)'.")
    }
    $manifestFormat = [string](Get-PropertyValue -InputObject $manifest -Name 'output_format')
    if ($manifestFormat -cne $catalog.OutputFormat) {
        $findings.Add("manifest.json output_format '$manifestFormat' does not match the catalog '$($catalog.OutputFormat)'.")
    }
    $manifestSettings = Get-PropertyValue -InputObject $manifest -Name 'voice_settings'
    $requiredSettingsSignature = Get-VoiceSettingsSignature -Settings (Get-RequiredVoiceConfiguration)
    if ((Get-VoiceSettingsSignature -Settings $manifestSettings) -cne $requiredSettingsSignature) {
        $findings.Add("manifest.json voice_settings are not the required configuration '$requiredSettingsSignature'.")
    }

    $manifestEntries = @(Get-PropertyValue -InputObject $manifest -Name 'entries')
    foreach ($catalogEntry in $catalog.Entries) {
        $entry = $manifestEntries |
            Where-Object { [string](Get-PropertyValue -InputObject $_ -Name 'id') -ceq $catalogEntry.Id } |
            Select-Object -First 1
        if ($null -eq $entry) {
            $findings.Add("manifest.json has no entry for required clip '$($catalogEntry.Id)'.")
            continue
        }
        $entryText = [string](Get-PropertyValue -InputObject $entry -Name 'text')
        if ($entryText -cne $catalogEntry.Text) {
            $findings.Add("Clip '$($catalogEntry.Id)' text differs from the catalog; regenerate it.")
            continue
        }
        $expectedTextHash = Get-StringSha256 -Value $catalogEntry.Text
        $entryTextHash = [string](Get-PropertyValue -InputObject $entry -Name 'text_sha256')
        if ($entryTextHash -cne $expectedTextHash) {
            $findings.Add("Clip '$($catalogEntry.Id)' text_sha256 does not match its text.")
            continue
        }
        $expectedConfigHash = Get-AnnouncementConfigHash -Text $catalogEntry.Text -VoiceId $voiceId `
            -ModelId $catalog.ModelId -OutputFormat $catalog.OutputFormat -VoiceSettings $manifestSettings
        $entryConfigHash = [string](Get-PropertyValue -InputObject $entry -Name 'config_sha256')
        if ($entryConfigHash -cne $expectedConfigHash) {
            $findings.Add("Clip '$($catalogEntry.Id)' config_sha256 does not match text, voice and generation settings; regenerate it.")
            continue
        }
        $fileName = [string](Get-PropertyValue -InputObject $entry -Name 'file')
        if ([string]::IsNullOrWhiteSpace($fileName)) {
            $findings.Add("Clip '$($catalogEntry.Id)' has no file name in the manifest.")
            continue
        }
        $clipPath = Join-Path -Path $AnnouncementsDirectory -ChildPath $fileName
        if (-not (Test-Path -LiteralPath $clipPath -PathType Leaf)) {
            $findings.Add("Clip file '$fileName' for '$($catalogEntry.Id)' is missing; regenerate it.")
            continue
        }
        $actualHash = Get-FileSha256 -Path $clipPath
        $expectedHash = [string](Get-PropertyValue -InputObject $entry -Name 'sha256')
        if ($actualHash -cne $expectedHash) {
            $findings.Add("Clip file '$fileName' hash $actualHash does not match manifest sha256 $expectedHash; regenerate it.")
            continue
        }
        try {
            $audioInfo = Get-AudioFileInfo -Path $clipPath -FfprobeExecutable $FfprobeExecutable
        }
        catch {
            $findings.Add("Clip '$($catalogEntry.Id)' is not readable audio: $($_.Exception.Message)")
            continue
        }
        if ($audioInfo.Codec -cne 'mp3') {
            $findings.Add("Clip '$($catalogEntry.Id)' codec is '$($audioInfo.Codec)', not mp3.")
            continue
        }
        if ($audioInfo.SampleRate -ne 44100) {
            $findings.Add("Clip '$($catalogEntry.Id)' sample rate is $($audioInfo.SampleRate) Hz, not 44100 Hz.")
            continue
        }
        if ($audioInfo.Duration -lt 0.2 -or $audioInfo.Duration -gt 30) {
            $findings.Add("Clip '$($catalogEntry.Id)' duration $([Math]::Round($audioInfo.Duration, 3)) s is implausible for a fixed announcement.")
            continue
        }
        $verified.Add([pscustomobject]@{
                Id           = $catalogEntry.Id
                File         = $fileName
                Bytes        = (Get-Item -LiteralPath $clipPath).Length
                Duration     = [Math]::Round($audioInfo.Duration, 3)
                Sha256       = $actualHash
                VoiceId      = $voiceId
            })
    }

    foreach ($manifestEntry in $manifestEntries) {
        $entryId = [string](Get-PropertyValue -InputObject $manifestEntry -Name 'id')
        if ($null -eq ($catalog.Entries | Where-Object { $_.Id -ceq $entryId })) {
            $findings.Add("manifest.json entry '$entryId' is not in the required catalog; remove it or restore its spec entry.")
        }
    }

    return [pscustomobject]@{
        Ok       = ($findings.Count -eq 0)
        Findings = $findings
        Verified = $verified
    }
}

function Invoke-AnnouncementTool {
    <#
    .SYNOPSIS
    Runs the offline verification or the authorized generation batch.
    #>
    param(
        [Parameter(Mandatory)]
        [bool]$GenerateClips,

        [Parameter(Mandatory)]
        [string]$AnnouncementsDirectory,

        [Parameter(Mandatory)]
        [string]$CatalogPath,

        [string]$FfprobePath
    )

    $ffprobeExecutable = Resolve-FfprobeExecutable -FfprobePath $FfprobePath
    $catalog = Get-AnnouncementCatalogFile -CatalogPath $CatalogPath
    $manifestPath = Join-Path -Path $AnnouncementsDirectory -ChildPath 'manifest.json'

    if (-not $GenerateClips) {
        $result = Test-AnnouncementBundle -AnnouncementsDirectory $AnnouncementsDirectory `
            -CatalogPath $CatalogPath -FfprobeExecutable $ffprobeExecutable
        foreach ($finding in $result.Findings) {
            Write-AnnouncementMessage -Message "verify: $finding"
        }
        if (-not $result.Ok) {
            Write-AnnouncementMessage -Message "verify: FAILED - $($result.Findings.Count) problem(s) across $($catalog.Entries.Count) required clips."
            return 1
        }
        $totalBytes = ($result.Verified | Measure-Object -Property Bytes -Sum).Sum
        $longest = $result.Verified | Sort-Object -Property Duration -Descending | Select-Object -First 1
        Write-AnnouncementMessage -Message ("verify: OK - {0}/{1} clips, {2} bytes total, longest {3} s ('{4}')" -f `
                $result.Verified.Count, $catalog.Entries.Count, $totalBytes, $longest.Duration, $longest.Id)
        return 0
    }

    $apiKey = $env:ELEVENLABS_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-AnnouncementMessage -Message 'generate: ELEVENLABS_API_KEY is not set. Generation only runs in the authorized generation environment; unrelated implementation can continue.'
        return 1
    }

    $modelId = Get-RequiredModelId
    $outputFormat = Get-RequiredOutputFormat
    $requiredSettings = Get-RequiredVoiceConfiguration

    if (-not (Test-Path -LiteralPath $AnnouncementsDirectory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $AnnouncementsDirectory | Out-Null
    }
    $existingManifest = Get-AnnouncementManifestFile -Path $manifestPath
    $existingEntries = @()
    $pinnedVoiceId = ''
    if ($null -ne $existingManifest) {
        $existingEntries = @(Get-PropertyValue -InputObject $existingManifest -Name 'entries')
        $pinnedVoiceId = [string](Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $existingManifest -Name 'voice') -Name 'id')
    }

    $voices = Get-ElevenLabsVoicePage -ApiKey $apiKey
    $voice = Get-BellaVoice -Voices $voices -PinnedVoiceId $pinnedVoiceId
    $apiVoiceId = [string](Get-PropertyValue -InputObject $voice -Name 'voice_id')
    $voiceName = [string](Get-PropertyValue -InputObject $voice -Name 'name')
    $voiceCategory = [string](Get-PropertyValue -InputObject $voice -Name 'category')
    Write-AnnouncementMessage -Message "generate: voice '$voiceName' [$apiVoiceId] model $modelId $outputFormat"

    $manifest = [ordered]@{
        version        = 1
        voice          = [ordered]@{ id = $apiVoiceId; name = $voiceName; category = $voiceCategory }
        model_id       = $modelId
        output_format  = $outputFormat
        voice_settings = $requiredSettings
        entries        = @()
    }

    $generated = 0
    $reused = 0
    foreach ($catalogEntry in $catalog.Entries) {
        $fileName = "$($catalogEntry.Id).mp3"
        $clipPath = Join-Path -Path $AnnouncementsDirectory -ChildPath $fileName
        $expectedConfigHash = Get-AnnouncementConfigHash -Text $catalogEntry.Text -VoiceId $apiVoiceId `
            -ModelId $modelId -OutputFormat $outputFormat -VoiceSettings $requiredSettings
        $existing = $existingEntries |
            Where-Object { [string](Get-PropertyValue -InputObject $_ -Name 'id') -ceq $catalogEntry.Id } |
            Select-Object -First 1
        $canReuse = $false
        if ($null -ne $existing -and (Test-Path -LiteralPath $clipPath -PathType Leaf)) {
            $existingConfigHash = [string](Get-PropertyValue -InputObject $existing -Name 'config_sha256')
            $existingHash = [string](Get-PropertyValue -InputObject $existing -Name 'sha256')
            $canReuse = ($existingConfigHash -ceq $expectedConfigHash) -and ($existingHash -ceq (Get-FileSha256 -Path $clipPath))
        }
        if ($canReuse) {
            $manifest.entries += $existing
            $reused++
            Write-AnnouncementMessage -Message "generate: reuse '$($catalogEntry.Id)' ($fileName)"
            continue
        }

        $body = Get-SpeechRequestBody -Text $catalogEntry.Text -ModelId $modelId -VoiceSettings $requiredSettings
        $speech = Invoke-ElevenLabsSpeech -ApiKey $apiKey -VoiceId $apiVoiceId -OutputFormat $outputFormat -RequestBody $body
        try {
            $audioInfo = Get-AudioFileInfo -Path $speech.TemporaryPath -FfprobeExecutable $ffprobeExecutable
            if ($audioInfo.Codec -cne 'mp3' -or $audioInfo.SampleRate -ne 44100 -or
                $audioInfo.Duration -lt 0.2 -or $audioInfo.Duration -gt 30) {
                throw ("generated audio for '$($catalogEntry.Id)' is not a plausible 44.1 kHz MP3 clip " +
                    "(codec=$($audioInfo.Codec), rate=$($audioInfo.SampleRate), duration=$($audioInfo.Duration)).")
            }
            Copy-Item -LiteralPath $speech.TemporaryPath -Destination $clipPath -Force
            $entryRecord = Get-AnnouncementManifestEntry -Id $catalogEntry.Id -Text $catalogEntry.Text `
                -FilePath $clipPath -FileName $fileName -Voice $voice -ModelId $modelId `
                -OutputFormat $outputFormat -VoiceSettings $requiredSettings -AudioInfo $audioInfo `
                -ApiVoiceId $apiVoiceId -RequestId $speech.RequestId
            $manifest.entries += $entryRecord
            $generated++
            Export-AnnouncementManifest -Path $manifestPath -Manifest $manifest
            Write-AnnouncementMessage -Message ("generate: wrote {0} ({1} bytes, {2} s, request {3})" -f `
                    $fileName, $entryRecord.bytes, $entryRecord.duration_seconds, $speech.RequestId)
        }
        finally {
            if (Test-Path -LiteralPath $speech.TemporaryPath) {
                Remove-Item -LiteralPath $speech.TemporaryPath -Force
            }
        }
    }

    foreach ($staleEntry in $existingEntries) {
        $staleId = [string](Get-PropertyValue -InputObject $staleEntry -Name 'id')
        if ($null -eq ($catalog.Entries | Where-Object { $_.Id -ceq $staleId })) {
            Write-AnnouncementMessage -Message "generate: warning - manifest entry '$staleId' is no longer in the catalog; its clip file was left on disk."
        }
    }

    Export-AnnouncementManifest -Path $manifestPath -Manifest $manifest
    Write-AnnouncementMessage -Message "generate: $generated generated, $reused reused"

    $verification = Test-AnnouncementBundle -AnnouncementsDirectory $AnnouncementsDirectory `
        -CatalogPath $CatalogPath -FfprobeExecutable $ffprobeExecutable
    foreach ($finding in $verification.Findings) {
        Write-AnnouncementMessage -Message "verify: $finding"
    }
    if (-not $verification.Ok) {
        Write-AnnouncementMessage -Message 'generate: FAILED post-generation verification.'
        return 1
    }
    Write-AnnouncementMessage -Message ("generate: OK - {0}/{1} clips verified offline" -f $verification.Verified.Count, $catalog.Entries.Count)
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    $toolExitCode = 1
    try {
        $generateClips = $Generate.IsPresent -and -not $VerifyOnly.IsPresent
        $toolExitCode = Invoke-AnnouncementTool -GenerateClips $generateClips `
            -AnnouncementsDirectory $AnnouncementsDirectory -CatalogPath $CatalogPath -FfprobePath $FfprobePath
    }
    catch {
        Write-AnnouncementMessage -Message "error: $($_.Exception.Message)"
        $toolExitCode = 1
    }
    exit $toolExitCode
}
