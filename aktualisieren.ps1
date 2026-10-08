# Holt die Day-Ahead-Strompreise (Schweiz, Österreich) und den EUR/CHF-Kurs
# und baut daraus strompreise.html. Bei einem Fehler bleibt die alte Seite erhalten.

$ErrorActionPreference = 'Stop'
$ordner  = $PSScriptRoot
$vorlage = Join-Path $ordner 'vorlage.html'
$ziel    = Join-Path $ordner 'strompreise.html'
$log     = Join-Path $ordner 'aktualisieren.log'

function Schreibe-Log($text) {
    $zeile = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $text
    Add-Content -Path $log -Value $zeile -Encoding UTF8
    Write-Output $zeile
}

function Hole($url) {
    for ($versuch = 1; $versuch -le 3; $versuch++) {
        try {
            $antwort = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
            return [Text.Encoding]::UTF8.GetString($antwort.RawContentStream.ToArray())
        } catch {
            if ($versuch -eq 3) { throw }
            Start-Sleep -Seconds (20 * $versuch)   # z. B. bei "Too Many Requests"
        }
    }
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $start = (Get-Date).AddDays(-31).ToString('yyyy-MM-dd')
    $ende  = (Get-Date).AddDays(2).ToString('yyyy-MM-dd')

    $zonen = @{}
    foreach ($zone in 'CH', 'AT') {
        $json = Hole "https://api.energy-charts.info/price?bzn=$zone&start=$start&end=$ende"
        $null = $json | ConvertFrom-Json   # prüft, ob gültiges JSON zurückkam
        $zonen[$zone] = $json
        Start-Sleep -Seconds 2
    }

    $fx = Hole 'https://api.frankfurter.dev/v1/latest?base=EUR&symbols=CHF' | ConvertFrom-Json
    $kurs = [double]$fx.rates.CHF
    $kursText = $kurs.ToString([Globalization.CultureInfo]::InvariantCulture)

    $jetzt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $daten = '{"generated":"' + $jetzt + '","eurchf":' + $kursText + ',"eurchfDate":"' + $fx.date +
             '","zones":{"CH":' + $zonen['CH'] + ',"AT":' + $zonen['AT'] + '}}'

    $html = [IO.File]::ReadAllText($vorlage, [Text.Encoding]::UTF8)
    $html = $html.Replace('/*DATEN*/', $daten.Replace('</', '<\/'))
    $tmp = $ziel + '.tmp'
    [IO.File]::WriteAllText($tmp, $html, (New-Object Text.UTF8Encoding $false))
    Move-Item -Path $tmp -Destination $ziel -Force

    Schreibe-Log "OK: Preise bis $ende geholt, 1 EUR = $kursText CHF"
} catch {
    Schreibe-Log ("FEHLER: " + $_.Exception.Message)
    exit 1
}
