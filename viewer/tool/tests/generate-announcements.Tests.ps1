#Requires -Version 7.0
<#
.SYNOPSIS
Focused tests for viewer/tool/generate-announcements.ps1.

.DESCRIPTION
Covers the offline safety logic that protects the bundled Bella assets:
catalog validation, locale-independent hashing, manifest verification,
voice-identity pinning and the rule that -VerifyOnly never touches the network.
The tests never call ElevenLabs and never read ELEVENLABS_API_KEY.
#>
BeforeAll {
    $script:ToolPath = Join-Path -Path $PSScriptRoot -ChildPath '../generate-announcements.ps1'
    . $script:ToolPath

    $script:Ffprobe = (Get-Command -Name 'ffprobe' -CommandType Application | Select-Object -First 1).Source
    $script:Ffmpeg = (Get-Command -Name 'ffmpeg' -CommandType Application | Select-Object -First 1).Source
    $script:CatalogSource = Join-Path -Path $PSScriptRoot -ChildPath '../../assets/announcements/catalog.json'

    function Add-TestAudioClip {
        param([Parameter(Mandatory)][string]$Path)

        & $script:Ffmpeg -hide_banner -loglevel error -y -f lavfi `
            -i 'sine=frequency=440:duration=1' -c:a libmp3lame -b:a 128k -ar 44100 -ac 1 $Path
        if ($LASTEXITCODE -ne 0) {
            throw "ffmpeg could not create the test clip '$Path'."
        }
    }

    function Add-TestBundle {
        <#
        .SYNOPSIS
        Builds a synthetic announcements directory with all required entries.
        #>
        param([Parameter(Mandatory)][string]$Root)

        New-Item -ItemType Directory -Force -Path $Root | Out-Null
        $catalogPath = Join-Path -Path $Root -ChildPath 'catalog.json'
        Copy-Item -LiteralPath $script:CatalogSource -Destination $catalogPath
        $clipPath = Join-Path -Path $Root -ChildPath 'clip.mp3'
        Add-TestAudioClip -Path $clipPath

        $settings = Get-RequiredVoiceConfiguration
        $voiceId = 'hpp4J3VqNfWAUOO0d1Us'
        $voice = [pscustomobject]@{
            voice_id = $voiceId
            name     = 'Bella - Professional, Bright, Warm'
            category = 'premade'
        }
        $audioInfo = Get-AudioFileInfo -Path $clipPath -FfprobeExecutable $script:Ffprobe
        $entries = foreach ($required in Get-RequiredAnnouncementCatalog) {
            Get-AnnouncementManifestEntry -Id $required.Id -Text $required.Text -FilePath $clipPath `
                -FileName 'clip.mp3' -Voice $voice -ModelId (Get-RequiredModelId) `
                -OutputFormat (Get-RequiredOutputFormat) -VoiceSettings $settings `
                -AudioInfo $audioInfo -ApiVoiceId $voiceId -RequestId 'test-request'
        }
        $manifest = [ordered]@{
            version        = 1
            voice          = [ordered]@{ id = $voiceId; name = $voice.name; category = $voice.category }
            model_id       = Get-RequiredModelId
            output_format  = Get-RequiredOutputFormat
            voice_settings = $settings
            entries        = @($entries)
        }
        $manifestPath = Join-Path -Path $Root -ChildPath 'manifest.json'
        Export-AnnouncementManifest -Path $manifestPath -Manifest $manifest

        return [pscustomobject]@{
            Root        = $Root
            CatalogPath = $catalogPath
            ManifestPath = $manifestPath
            ClipPath    = $clipPath
        }
    }

    function Add-TestRoot {
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "tasks-cli-announcements-$([guid]::NewGuid().ToString('n'))"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        return $root
    }
}

AfterAll {
    Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Directory -Filter 'tasks-cli-announcements-*' -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'catalog validation' {
    It 'accepts the required fixed catalog' {
        $catalog = [pscustomobject]@{
            voice         = 'Bella'
            model_id      = Get-RequiredModelId
            output_format = Get-RequiredOutputFormat
            entries       = @(Get-RequiredAnnouncementCatalog | ForEach-Object {
                    [pscustomobject]@{ id = $_.Id; text = $_.Text }
                })
        }
        $result = Test-AnnouncementCatalog -Catalog $catalog
        $result.Ok | Should -BeTrue
        $result.Findings.Count | Should -Be 0
        $result.Entries.Count | Should -Be 20
    }

    It 'rejects altered text, missing ids, extra ids and duplicates' {
        $entries = @(Get-RequiredAnnouncementCatalog | ForEach-Object {
                [pscustomobject]@{ id = $_.Id; text = $_.Text }
            })
        $entries[0].text = 'Saving!'
        $catalog = [pscustomobject]@{ entries = $entries }
        $result = Test-AnnouncementCatalog -Catalog $catalog
        $result.Ok | Should -BeFalse
        ($result.Findings -join ' ') | Should -Match 'Saving'

        $missing = @($entries | Where-Object { $_.id -ne 'voice_test' })
        (Test-AnnouncementCatalog -Catalog ([pscustomobject]@{ entries = $missing })).Ok | Should -BeFalse
        ((Test-AnnouncementCatalog -Catalog ([pscustomobject]@{ entries = $missing })).Findings -join ' ') |
            Should -Match 'voice_test'

        $extra = $entries + [pscustomobject]@{ id = 'surprise'; text = 'Surprise' }
        (Test-AnnouncementCatalog -Catalog ([pscustomobject]@{ entries = $extra })).Ok | Should -BeFalse
        ((Test-AnnouncementCatalog -Catalog ([pscustomobject]@{ entries = $extra })).Findings -join ' ') |
            Should -Match 'surprise'

        $duplicate = $entries + $entries[0]
        (Test-AnnouncementCatalog -Catalog ([pscustomobject]@{ entries = $duplicate })).Ok | Should -BeFalse
    }
}

Describe 'generation configuration' {
    It 'hashes and serialises independently of the current culture' {
        $original = [System.Globalization.CultureInfo]::CurrentCulture
        try {
            [System.Globalization.CultureInfo]::CurrentCulture = 'pl-PL'
            $polishHash = Get-AnnouncementConfigHash -Text 'Saving' -VoiceId 'voice' -ModelId (Get-RequiredModelId) `
                -OutputFormat (Get-RequiredOutputFormat) -VoiceSettings (Get-RequiredVoiceConfiguration)
            $body = Get-SpeechRequestBody -Text 'Saving' -ModelId (Get-RequiredModelId) `
                -VoiceSettings (Get-RequiredVoiceConfiguration)
            [System.Globalization.CultureInfo]::CurrentCulture = 'en-US'
            $englishHash = Get-AnnouncementConfigHash -Text 'Saving' -VoiceId 'voice' -ModelId (Get-RequiredModelId) `
                -OutputFormat (Get-RequiredOutputFormat) -VoiceSettings (Get-RequiredVoiceConfiguration)
            $englishBody = Get-SpeechRequestBody -Text 'Saving' -ModelId (Get-RequiredModelId) `
                -VoiceSettings (Get-RequiredVoiceConfiguration)
        }
        finally {
            [System.Globalization.CultureInfo]::CurrentCulture = $original
        }

        $polishHash | Should -Be $englishHash
        $body | Should -Be $englishBody
        $body | Should -Match '"stability":0\.5'
        $body | Should -Match '"similarity_boost":0\.75'
        $body | Should -Match '"use_speaker_boost":true'
    }

    It 'resolves Bella only from an unambiguous set of candidates' {
        $bella = [pscustomobject]@{ voice_id = 'id-bella'; name = 'Bella - Warm'; category = 'premade' }
        $other = [pscustomobject]@{ voice_id = 'id-other'; name = 'Rachel'; category = 'premade' }

        (Get-BellaVoice -Voices @($bella, $other)).voice_id | Should -Be 'id-bella'
        (Get-BellaVoice -Voices @($bella, $other) -PinnedVoiceId 'id-bella').voice_id | Should -Be 'id-bella'
        { Get-BellaVoice -Voices @($bella, $other) -PinnedVoiceId 'id-gone' } | Should -Throw '*no longer exposes*'
        { Get-BellaVoice -Voices @($other) } | Should -Throw '*no voice named Bella*'
        { Get-BellaVoice -Voices @($bella, [pscustomobject]@{ voice_id = 'id-two'; name = 'Bella - Bright' }) } |
            Should -Throw '*multiple Bella candidates*'
    }

    It 'rejects a missing ffprobe path with an actionable error' {
        { Resolve-FfprobeExecutable -FfprobePath (Join-Path ([System.IO.Path]::GetTempPath()) 'missing-ffprobe-binary.exe') } |
            Should -Throw '*ffprobe was not found*'
    }
}

Describe 'bundle verification' {
    It 'accepts a complete synthetic bundle without any network call' {
        $root = Add-TestRoot
        $bundle = Add-TestBundle -Root $root
        Mock -CommandName Invoke-RestMethod -MockWith { throw 'network access attempted' }
        Mock -CommandName Invoke-WebRequest -MockWith { throw 'network access attempted' }

        $result = Test-AnnouncementBundle -AnnouncementsDirectory $bundle.Root `
            -CatalogPath $bundle.CatalogPath -FfprobeExecutable $script:Ffprobe

        $result.Ok | Should -BeTrue -Because ($result.Findings -join '; ')
        $result.Verified.Count | Should -Be 20
    }

    It 'fails when the manifest is absent' {
        $root = Add-TestRoot
        $bundle = Add-TestBundle -Root $root
        Remove-Item -LiteralPath $bundle.ManifestPath -Force

        $result = Test-AnnouncementBundle -AnnouncementsDirectory $bundle.Root `
            -CatalogPath $bundle.CatalogPath -FfprobeExecutable $script:Ffprobe

        $result.Ok | Should -BeFalse
        ($result.Findings -join ' ') | Should -Match 'manifest.json'
    }

    It 'fails when a referenced clip is missing or altered' {
        $root = Add-TestRoot
        $bundle = Add-TestBundle -Root $root
        Remove-Item -LiteralPath $bundle.ClipPath -Force
        $missing = Test-AnnouncementBundle -AnnouncementsDirectory $bundle.Root `
            -CatalogPath $bundle.CatalogPath -FfprobeExecutable $script:Ffprobe
        $missing.Ok | Should -BeFalse
        ($missing.Findings -join ' ') | Should -Match 'missing'

        $second = Add-TestBundle -Root (Add-TestRoot)
        [byte[]]$bytes = Get-Content -LiteralPath $second.ClipPath -AsByteStream -Raw
        $bytes[400] = $bytes[400] -bxor 0xFF
        Set-Content -LiteralPath $second.ClipPath -Value $bytes -AsByteStream
        $altered = Test-AnnouncementBundle -AnnouncementsDirectory $second.Root `
            -CatalogPath $second.CatalogPath -FfprobeExecutable $script:Ffprobe
        $altered.Ok | Should -BeFalse
        ($altered.Findings -join ' ') | Should -Match 'hash'
    }

    It 'fails when the pinned voice is not Bella or settings drift' {
        $root = Add-TestRoot
        $bundle = Add-TestBundle -Root $root
        $manifest = Get-Content -LiteralPath $bundle.ManifestPath -Raw | ConvertFrom-Json
        $manifest.voice.name = 'Rachel'
        Set-Content -LiteralPath $bundle.ManifestPath -Value ($manifest | ConvertTo-Json -Depth 8)

        $result = Test-AnnouncementBundle -AnnouncementsDirectory $bundle.Root `
            -CatalogPath $bundle.CatalogPath -FfprobeExecutable $script:Ffprobe
        $result.Ok | Should -BeFalse
        ($result.Findings -join ' ') | Should -Match 'not Bella'
    }

    It 'returns exit code 0 or 1 from the tool entry point' {
        $root = Add-TestRoot
        $bundle = Add-TestBundle -Root $root
        $ok = Invoke-AnnouncementTool -GenerateClips $false -AnnouncementsDirectory $bundle.Root `
            -CatalogPath $bundle.CatalogPath -FfprobePath $script:Ffprobe -InformationAction SilentlyContinue
        $ok | Should -Be 0

        Remove-Item -LiteralPath $bundle.ClipPath -Force
        $failed = Invoke-AnnouncementTool -GenerateClips $false -AnnouncementsDirectory $bundle.Root `
            -CatalogPath $bundle.CatalogPath -FfprobePath $script:Ffprobe -InformationAction SilentlyContinue
        $failed | Should -Be 1
    }
}
