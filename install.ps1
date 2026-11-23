# FS25_ServerRules - install or update the mod on a player PC (Windows PowerShell, built-in tools only)
# Usage (PowerShell):  irm https://raw.githubusercontent.com/VitaCuraHUB/FS25_ServerRules/main/install.ps1 | iex
# What it does: downloads FS25_ServerRules.zip from the newest release of this project, checks the
# SHA-256 against the release notes and copies the file into your Farming Simulator 25 mods folder.
# Nothing else is changed.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $repo = 'VitaCuraHUB/FS25_ServerRules'
    $name = 'FS25_ServerRules.zip'
    try {
        $profil = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\FarmingSimulator2025'
        if (-not (Test-Path $profil)) { throw 'Landwirtschafts-Simulator 25 wurde auf diesem PC nicht gefunden (Ordner "My Games\FarmingSimulator2025" fehlt). Bitte das Spiel einmal starten.' }
        $modDir = Join-Path $profil 'mods'
        $gs = Join-Path $profil 'gameSettings.xml'
        if (Test-Path $gs) {
            try {
                [xml]$x = Get-Content $gs -Raw -Encoding UTF8
                $o = $x.SelectSingleNode('//modsDirectoryOverride')
                if ($o -ne $null -and $o.GetAttribute('active') -eq 'true' -and $o.GetAttribute('directory')) { $modDir = $o.GetAttribute('directory') }
            } catch { }
        }
        if (-not (Test-Path $modDir)) { New-Item -ItemType Directory -Path $modDir -Force | Out-Null }

        $rel = @(Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $repo + '/releases') -UseBasicParsing)[0]
        if ($rel -eq $null) { throw 'Keine Version zum Herunterladen gefunden.' }
        $asset = $rel.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if ($asset -eq $null) { throw 'Die Datei fehlt in der neuesten Version.' }
        $m = [regex]::Match([string]$rel.body, 'SHA-256:\s*([0-9A-Fa-f]{64})')
        if (-not $m.Success) { throw 'Die Pruefsumme fehlt in der neuesten Version.' }
        $soll = $m.Groups[1].Value.ToUpper()

        $tmp = Join-Path $env:TEMP ('FS25_ServerRules-' + [guid]::NewGuid().ToString('N') + '.zip')
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing
        $ist = (Get-FileHash $tmp -Algorithm SHA256).Hash
        if ($ist -ne $soll) { Remove-Item $tmp -Force; throw 'Die heruntergeladene Datei ist beschaedigt (Pruefsumme stimmt nicht). Bitte noch einmal versuchen.' }
        $ziel = Join-Path $modDir $name
        Copy-Item $tmp $ziel -Force
        Remove-Item $tmp -Force
        Write-Host ''
        Write-Host ('Fertig: Server-Regeln ' + $rel.tag_name + ' ist installiert.') -ForegroundColor Green
        Write-Host ('Ordner: ' + $modDir)
        if (Get-Process FarmingSimulator2025Game -ErrorAction SilentlyContinue) { Write-Host 'Das Spiel laeuft gerade - bitte einmal beenden und neu starten.' -ForegroundColor Yellow }
    } catch {
        Write-Host ''
        Write-Host ('Das hat leider nicht geklappt: ' + $_.Exception.Message) -ForegroundColor Red
    }
}
