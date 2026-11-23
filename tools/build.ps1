# Builds dist\FS25_ServerRules.zip (files at zip root, forward slashes) and prints SHA-256.
# Usage: powershell -ExecutionPolicy Bypass -File tools\build.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dist = Join-Path $root 'dist'
if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }
$zipPath = Join-Path $dist 'FS25_ServerRules.zip'
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

$files = @('modDesc.xml', 'icon_serverRules.dds')
$files += Get-ChildItem (Join-Path $root 'scripts') -Filter *.lua | ForEach-Object { 'scripts/' + $_.Name }
$files += Get-ChildItem (Join-Path $root 'l10n') -Filter *.xml | ForEach-Object { 'l10n/' + $_.Name }
if (Test-Path (Join-Path $root 'gui')) { $files += Get-ChildItem (Join-Path $root 'gui') -File | ForEach-Object { 'gui/' + $_.Name } }

# Plain ASCII check for Lua files (the game reads them as bytes; keep them simple)
foreach ($f in $files | Where-Object { $_ -like '*.lua' }) {
    $b = [IO.File]::ReadAllBytes((Join-Path $root $f))
    if (($b | Where-Object { $_ -gt 127 }).Count -gt 0) { throw "Nicht-ASCII-Zeichen in $f" }
}

$fs = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
$zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in $files) {
        $entry = $zip.CreateEntry($f, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]'2026-01-01T00:00:00Z'   # reproducible
        $s = $entry.Open()
        $bytes = [IO.File]::ReadAllBytes((Join-Path $root ($f -replace '/', '\')))
        $s.Write($bytes, 0, $bytes.Length)
        $s.Close()
    }
} finally { $zip.Dispose(); $fs.Close() }

$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
Write-Host ("{0}  {1} Dateien  {2:N0} Bytes" -f $zipPath, $files.Count, (Get-Item $zipPath).Length)
Write-Host ("SHA-256: " + $hash)
