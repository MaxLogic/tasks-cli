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

function Get-AttachmentClipboardSnapshot {
    param([type]$ClipboardType, [string]$ImagePath)
    $ErrorActionPreference = 'Stop'
    $files = @()
    $dropCount = 0L
    $hasImage = $false
    if ($ClipboardType::ContainsFileDropList()) {
        # Preserve clipboard order. Rust classifies missing paths/directories.
        $drop = $ClipboardType::GetFileDropList()
        $dropCount = $drop.Count
        $files = @($drop | Select-Object -First 33 | ForEach-Object { [string]$_ })
    } elseif ($ClipboardType::ContainsData('PNG')) {
        $png = $ClipboardType::GetData('PNG')
        if ($png -is [byte[]]) { $png = New-Object IO.MemoryStream(,$png) }
        if ($png -isnot [IO.Stream]) { throw 'The PNG clipboard format is not a stream.' }
        try {
            if ($png.CanSeek -and $png.Length -gt 20971520) {
                throw (Get-AttachmentClipboardLimitError -Measured $png.Length -Limit 20971520 -Unit 'bytes')
            }
            if ($png.CanSeek) { $png.Position = 0 }
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
        $hasImage = $true
    } elseif ($ClipboardType::ContainsImage()) {
        $image = $ClipboardType::GetImage()
        try {
            $bitmapBytes = [decimal]$image.Width * [decimal]$image.Height * 4
            if ($bitmapBytes -gt 268435456) {
                throw (Get-AttachmentClipboardLimitError -Measured $bitmapBytes -Limit 268435456 -Unit 'bitmap_bytes')
            }
            $output = [IO.File]::Open($ImagePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $image.Save($output, [Drawing.Imaging.ImageFormat]::Png) }
            finally { $output.Dispose() }
        } finally { $image.Dispose() }
        $pngSize = (Get-Item -LiteralPath $ImagePath).Length
        if ($pngSize -gt 20971520) {
            throw (Get-AttachmentClipboardLimitError -Measured $pngSize -Limit 20971520 -Unit 'bytes')
        }
        $hasImage = $true
    }
    return @{ count = $dropCount; files = @($files); image = $hasImage; too_large = $false }
}

# Allows unit tests to inject a synthetic clipboard type without desktop access.
if ($FunctionsOnly) { return }
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
try {
    $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if (-not [IO.Path]::IsPathRooted($request.image_path)) {
        throw 'An absolute image output path is required.'
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $reply = Get-AttachmentClipboardSnapshot -ClipboardType ([System.Windows.Forms.Clipboard]) -ImagePath $request.image_path
    # An empty reply is the clipboard_empty marker; never echo clipboard data in errors.
    Write-Output ($reply | ConvertTo-Json -Compress)
} catch {
    if ($_.Exception.Message -eq 'too_large') {
        Write-Output (@{ count = 0; files = @(); image = $false; too_large = $true; measured = $_.Exception.Data['measured']; limit = $_.Exception.Data['limit']; unit = $_.Exception.Data['unit'] } | ConvertTo-Json -Compress)
        exit 0
    }
    [Console]::Error.WriteLine('Clipboard attachment helper failed; clipboard unavailable, locked, or invalid.')
    exit 1
}
