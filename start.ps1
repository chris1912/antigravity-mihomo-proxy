$ErrorActionPreference = 'Stop'

$mainPath = Join-Path -Path $PSScriptRoot -ChildPath 'AntigravityProxy.ps1'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$env:ANTIGRAVITY_MIHOMO_TOOL_ROOT = $PSScriptRoot

try {
    $source = [System.IO.File]::ReadAllText($mainPath, $utf8NoBom)
    . ([scriptblock]::Create($source))
    exit 0
}
catch {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "Antigravity proxy startup failed: $($_.Exception.Message)",
        'Antigravity Proxy',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}
finally {
    Remove-Item -LiteralPath 'Env:ANTIGRAVITY_MIHOMO_TOOL_ROOT' -ErrorAction SilentlyContinue
}
