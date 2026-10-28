# Static STA helper. Clipboard content and output paths are data on stdin.
param([switch]$FunctionsOnly)

function Get-AttachmentClipboardLimitError {
    param([UInt64]$Measured, [UInt64]$Limit, [string]$Unit)
    $exception = New-Object InvalidOperationException('too_large')
    $exception.Data['measured'] = $Measured
    $exception.Data['limit'] = $Limit
    $exception.Data['unit'] = $Unit
    return $exception
}

# Fixed, content-free markers are consumed live by the CLI. Never emit source data.
function Write-AttachmentClipboardPhase {
    param([string]$Phase)
    [Console]::Error.WriteLine('TASKS_CLIPBOARD_PHASE_V1:' + $Phase)
    [Console]::Error.Flush()
}

function Invoke-AttachmentClipboardRead {
    param([scriptblock]$Read, [string]$Phase)
    # Read must emit one non-enumerated object (comma inside the callback).
    # The outer comma cannot restore a byte[] already enumerated by its pipeline.
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        Write-AttachmentClipboardPhase $Phase
        try { return ,(& $Read) } catch {
            $cause = $_.Exception
            while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
            # CLIPBRD_E_CANT_OPEN only: no retries for corrupt data or arbitrary failures.
            if ($cause -isnot [Runtime.InteropServices.ExternalException] -or
                $cause.ErrorCode -ne -2147221040) { throw }
            Write-AttachmentClipboardPhase 'busy'
            if ($attempt -eq 3) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Get-AttachmentDibV5Image {
    param([IO.Stream]$Dib)
    # GDI+ reads a BMP stream directly. Add only its 14-byte file header to the
    # native DIBV5; no intermediate Bitmap conversion or per-pixel PowerShell work.
    $header = New-Object byte[] 124
    $read = 0
    while ($read -lt $header.Length) {
        $count = $Dib.Read($header, $read, $header.Length - $read)
        if ($count -eq 0) { throw 'Truncated DIBV5 header.' }
        $read += $count
    }
    if ([BitConverter]::ToUInt32($header, 0) -ne 124) { return $null }
    $width = [BitConverter]::ToInt32($header, 4)
    $height = [BitConverter]::ToInt32($header, 8)
    $bits = [BitConverter]::ToUInt16($header, 14)
    $compression = [BitConverter]::ToUInt32($header, 16)
    # Other native layouts use the established GetImage fallback.
    if ($bits -ne 32 -or $compression -notin @(0, 3) -or
        [BitConverter]::ToUInt16($header, 12) -ne 1 -or
        [BitConverter]::ToUInt32($header, 32) -ne 0 -or
        [BitConverter]::ToUInt32($header, 112) -ne 0 -or
        [BitConverter]::ToUInt32($header, 116) -ne 0) { return $null }
    if ($width -le 0 -or $height -eq 0) { throw 'Invalid DIBV5 dimensions.' }
    $size = [decimal]$width * [Math]::Abs([decimal]$height) * 4
    if ($size -gt 268435456) {
        throw (Get-AttachmentClipboardLimitError -Measured $size -Limit 268435456 -Unit 'bitmap_bytes')
    }
    $bitmap = New-Object IO.MemoryStream([int](138 + $size))
    try {
        $writer = New-Object IO.BinaryWriter($bitmap)
        $writer.Write([byte[]]@(66, 77))
        $writer.Write([uint32](138 + $size))
        $writer.Write([uint32]0)
        $writer.Write([uint32]138)
        $writer.Write($header)
        $buffer = New-Object byte[] 65536
        $remaining = [long]$size
        while ($remaining -gt 0) {
            $count = $Dib.Read($buffer, 0, [int][Math]::Min($remaining, $buffer.Length))
            if ($count -eq 0) { throw 'Truncated DIBV5 pixels.' }
            $bitmap.Write($buffer, 0, $count)
            $remaining -= $count
        }
        $bitmap.Position = 0
        # Keep stream alive until image disposal (Image.FromStream contract).
        return @{ Image = [Drawing.Image]::FromStream($bitmap); Stream = $bitmap }
    } catch { $bitmap.Dispose(); throw }
}

function Get-AttachmentClipboardSnapshot {
    param([type]$ClipboardType, [string]$ImagePath)
    $ErrorActionPreference = 'Stop'
    $clipboardApi = $ClipboardType
    $files = @()
    $dropCount = 0L
    $hasImage = $false
    $data = Invoke-AttachmentClipboardRead { ,($clipboardApi::GetDataObject()) } 'reading_formats'
    $formats = @()
    if ($null -ne $data) {
        $formats = Invoke-AttachmentClipboardRead { ,($data.GetFormats($false)) } 'reading_formats'
    }
    Write-AttachmentClipboardPhase 'formats_ready'
    if ($formats -contains 'FileDrop') {
        # Preserve clipboard order. Rust classifies missing paths/directories.
        $drop = Invoke-AttachmentClipboardRead { ,($data.GetData('FileDrop', $false)) } 'reading_files'
        $dropCount = $drop.Count
        $files = @($drop | Select-Object -First 33 | ForEach-Object { [string]$_ })
    } elseif ($formats -contains 'PNG') {
        $png = Invoke-AttachmentClipboardRead { ,($data.GetData('PNG', $false)) } 'reading_png'
        if ($png -is [byte[]]) { $png = New-Object IO.MemoryStream(,$png) }
        if ($png -isnot [IO.Stream]) { throw 'The PNG clipboard format is not a stream.' }
        try {
            if ($png.CanSeek -and $png.Length -gt 20971520) {
                throw (Get-AttachmentClipboardLimitError -Measured $png.Length -Limit 20971520 -Unit 'bytes')
            }
            if ($png.CanSeek) { $png.Position = 0 }
            Write-AttachmentClipboardPhase 'copying_png'
            $output = [IO.File]::Open($ImagePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $buffer = New-Object byte[] 65536
                $total = 0L
                while (($count = $png.Read($buffer, 0, [Math]::Min($buffer.Length, 20971521 - $total))) -gt 0) {
                    $total += $count
                    if ($total -gt 20971520) {
                        throw (Get-AttachmentClipboardLimitError -Measured $total -Limit 20971520 -Unit 'bytes')
                    }
                    $output.Write($buffer, 0, $count)
                }
            } finally { $output.Dispose() }
        } finally { $png.Dispose() }
        Write-AttachmentClipboardPhase 'encoded'
        $hasImage = $true
    } elseif ($formats -contains 'Format17' -or $formats -contains 'Bitmap' -or $formats -contains 'DeviceIndependentBitmap') {
        $image = $null
        $dibImage = $null
        try {
            if ($formats -contains 'Format17') {
                $dib = Invoke-AttachmentClipboardRead { ,($data.GetData('Format17', $false)) } 'reading_image'
                if ($dib -is [byte[]]) { $dib = New-Object IO.MemoryStream(,$dib) }
                if ($dib -is [IO.Stream]) {
                    try {
                        if ($dib.CanSeek) { $dib.Position = 0 }
                        Write-AttachmentClipboardPhase 'preparing_image'
                        $dibImage = Get-AttachmentDibV5Image $dib
                        if ($null -ne $dibImage) { $image = $dibImage.Image }
                    } finally { $dib.Dispose() }
                }
            }
            if ($null -eq $image) {
                if ($formats -contains 'Bitmap') {
                    $image = Invoke-AttachmentClipboardRead { ,($data.GetData('Bitmap', $false)) } 'reading_image'
                } else {
                    $image = Invoke-AttachmentClipboardRead { ,($clipboardApi::GetImage()) } 'reading_image'
                }
            }
            Write-AttachmentClipboardPhase 'image_retrieved'
            if ($null -eq $image) { throw 'Clipboard image unavailable.' }
            $bitmapBytes = [decimal]$image.Width * [decimal]$image.Height * 4
            if ($bitmapBytes -gt 268435456) {
                throw (Get-AttachmentClipboardLimitError -Measured $bitmapBytes -Limit 268435456 -Unit 'bitmap_bytes')
            }
            Write-AttachmentClipboardPhase 'encoding_png'
            $output = [IO.File]::Open($ImagePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $image.Save($output, [Drawing.Imaging.ImageFormat]::Png) }
            finally { $output.Dispose() }
        } finally {
            if ($null -ne $image) { $image.Dispose() }
            if ($null -ne $dibImage) { $dibImage.Stream.Dispose() }
        }
        $pngSize = (Get-Item -LiteralPath $ImagePath).Length
        if ($pngSize -gt 20971520) {
            throw (Get-AttachmentClipboardLimitError -Measured $pngSize -Limit 20971520 -Unit 'bytes')
        }
        Write-AttachmentClipboardPhase 'encoded'
        $hasImage = $true
    }
    return @{ count = $dropCount; files = @($files); image = $hasImage; too_large = $false }
}

# Allows unit tests to inject a synthetic clipboard type without desktop access.
if ($FunctionsOnly) { return }
Write-AttachmentClipboardPhase 'started'
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
try {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'STA required.' }
    Write-AttachmentClipboardPhase 'sta_ready'
    Write-AttachmentClipboardPhase 'reading_request'
    $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if (-not [IO.Path]::IsPathRooted($request.image_path)) {
        throw 'An absolute image output path is required.'
    }
    Write-AttachmentClipboardPhase 'loading_assemblies'
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $reply = Get-AttachmentClipboardSnapshot -ClipboardType ([System.Windows.Forms.Clipboard]) -ImagePath $request.image_path
    # An empty reply is the clipboard_empty marker; never echo clipboard data in errors.
    Write-AttachmentClipboardPhase 'output_ready'
    Write-Output ($reply | ConvertTo-Json -Compress)
} catch {
    if ($_.Exception.Message -eq 'too_large') {
        Write-Output (@{ count = 0; files = @(); image = $false; too_large = $true; measured = $_.Exception.Data['measured']; limit = $_.Exception.Data['limit']; unit = $_.Exception.Data['unit'] } | ConvertTo-Json -Compress)
        exit 0
    }
    [Console]::Error.WriteLine('Clipboard attachment helper failed; clipboard unavailable, locked, or invalid.')
    exit 1
}
