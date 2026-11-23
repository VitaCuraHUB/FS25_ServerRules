# Creates icon_serverRules.dds (256x256, uncompressed A8R8G8B8): a simple scale on green.
# Usage: powershell -ExecutionPolicy Bypass -File tools\make-icon.ps1
param([string]$Out = (Join-Path $PSScriptRoot '..\icon_serverRules.dds'))

$w = 256; $h = 256
$ms = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter($ms)
$bw.Write([byte[]][char[]]'DDS ')
$bw.Write([int]124); $bw.Write([int]0x100F); $bw.Write([int]$h); $bw.Write([int]$w)
$bw.Write([int]($w * 4)); $bw.Write([int]0); $bw.Write([int]0)
for ($i = 0; $i -lt 11; $i++) { $bw.Write([int]0) }
$bw.Write([int]32); $bw.Write([int]0x41); $bw.Write([int]0); $bw.Write([int]32)
$bw.Write([int]0x00FF0000); $bw.Write([int]0x0000FF00); $bw.Write([int]0x000000FF); $bw.Write([int]0xFF000000)
$bw.Write([int]0x1000); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)

function Test-InScale([int]$x, [int]$y) {
    # post
    if ($x -ge 122 -and $x -le 133 -and $y -ge 60 -and $y -le 200) { return $true }
    # foot
    if ($x -ge 80 -and $x -le 175 -and $y -ge 196 -and $y -le 210) { return $true }
    # beam
    if ($x -ge 40 -and $x -le 215 -and $y -ge 62 -and $y -le 72) { return $true }
    # top knob
    if ((($x - 128) * ($x - 128) + ($y - 52) * ($y - 52)) -le 100) { return $true }
    # strings
    foreach ($cx in 60, 196) {
        $dy = $y - 72
        if ($dy -ge 0 -and $dy -le 60) {
            $off = [int]($dy * 0.45)
            if ([math]::Abs($x - ($cx - $off)) -le 1 -or [math]::Abs($x - ($cx + $off)) -le 1) { return $true }
        }
        # pans (half circles)
        if ($y -ge 132 -and $y -le 152) {
            $r = 30; $d = ($x - $cx) * ($x - $cx) + ($y - 132) * ($y - 132)
            if ($d -le $r * $r) { return $true }
        }
    }
    return $false
}

for ($y = 0; $y -lt $h; $y++) {
    for ($x = 0; $x -lt $w; $x++) {
        $g = [int](120 + 60 * (1 - $y / $h))
        $r = 30; $b = 40; $a = 255
        if (Test-InScale $x $y) { $r = 245; $g = 240; $b = 225 }
        $bw.Write([byte]$b); $bw.Write([byte]$g); $bw.Write([byte]$r); $bw.Write([byte]$a)
    }
}
$bw.Flush()
[IO.File]::WriteAllBytes((Resolve-Path -LiteralPath (Split-Path $Out)).Path + '\' + (Split-Path $Out -Leaf), $ms.ToArray())
Write-Host "geschrieben: $Out"
