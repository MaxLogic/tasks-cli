# Console.Write deliberately preserves exact text; this helper only runs under the console PowerShell host.
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
try {
    Add-Type -AssemblyName System.Windows.Forms
    $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if (-not [System.Windows.Forms.Clipboard]::ContainsText()) {
        throw 'The clipboard does not contain text.'
    }
    $current = [System.Windows.Forms.Clipboard]::GetText()
    if ($request.action -eq 'read') {
        [Console]::Write($current)
    } elseif ($request.action -eq 'replace') {
        if (-not [string]::Equals($current, $request.expected, [StringComparison]::Ordinal)) {
            throw 'The clipboard changed during enrichment; run the command again.'
        }
        if (-not [string]::Equals($current, $request.replacement, [StringComparison]::Ordinal)) {
            [System.Windows.Forms.Clipboard]::SetText($request.replacement)
        }
    } else {
        throw 'Unknown clipboard operation.'
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
