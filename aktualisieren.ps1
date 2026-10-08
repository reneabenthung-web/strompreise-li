# Holt die Day-Ahead-Strompreise der EPEX Spot Schweiz und den EUR/CHF-Kurs
# und baut daraus strompreise.html. Tageswerte seit 2015 werden in verlauf.json gesammelt.
# Bei einem Fehler bleiben die alten Dateien erhalten.

$ErrorActionPreference = 'Stop'
$ordner  = $PSScriptRoot
$vorlage = Join-Path $ordner 'vorlage.html'
$ziel    = Join-Path $ordner 'strompreise.html'
$verlauf = Join-Path $ordner 'verlauf.json'
$log     = Join-Path $ordner 'aktualisieren.log'
$inv     = [Globalization.CultureInfo]::InvariantCulture
$ersterTag = [datetime]'2015-01-01'

function Schreibe-Log($text) {
    $zeile = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $text
    Add-Content -Path $log -Value $zeile -Encoding UTF8
    Write-Output $zeile
}

function Hole($url) {
    for ($versuch = 1; $versuch -le 4; $versuch++) {
        try {
            $antwort = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 120
            return [Text.Encoding]::UTF8.GetString($antwort.RawContentStream.ToArray())
        } catch {
            if ($versuch -eq 4) { throw }
            Start-Sleep -Seconds (20 * $versuch)   # z. B. bei "Too Many Requests"
        }
    }
}

function Zahl($wert) { if ($null -eq $wert) { 'null' } else { ([double]$wert).ToString('0.###', $inv) } }

# Zeitzone Zürich (Windows- und Linux-Name)
try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById('Europe/Zurich') }
catch { $tz = [TimeZoneInfo]::FindSystemTimeZoneById('W. Europe Standard Time') }

# Summiert Preise je Kalendertag (Zürcher Zeit): Base = zeitgewichteter Schnitt,
# Peak = Montag–Freitag 08–20 Uhr, dazu Min und Max
function Sammle-Tage($preise, $tage) {
    $ts = $preise.unix_seconds; $ps = $preise.price
    for ($i = 0; $i -lt $ts.Count; $i++) {
        if ($null -eq $ps[$i]) { continue }
        $dauer = if ($i + 1 -lt $ts.Count) { [Math]::Min($ts[$i + 1] - $ts[$i], 3600) } else { 3600 }
        $lokal = [TimeZoneInfo]::ConvertTimeFromUtc([DateTimeOffset]::FromUnixTimeSeconds($ts[$i]).UtcDateTime, $tz)
        $tag = $lokal.ToString('yyyy-MM-dd')
        $p = [double]$ps[$i]
        $e = $tage[$tag]
        if ($null -eq $e) { $e = @{ s = 0.0; d = 0.0; ps = 0.0; pd = 0.0; min = $p; max = $p }; $tage[$tag] = $e }
        $e.s += $p * $dauer; $e.d += $dauer
        if ($p -lt $e.min) { $e.min = $p }
        if ($p -gt $e.max) { $e.max = $p }
        $wt = [int]$lokal.DayOfWeek
        if ($wt -ge 1 -and $wt -le 5 -and $lokal.Hour -ge 8 -and $lokal.Hour -lt 20) { $e.ps += $p * $dauer; $e.pd += $dauer }
    }
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $heute = [TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $tz).Date

    # Bisherigen Verlauf laden: Zeilen [Tag, Base, Peak, Min, Max, EUR/CHF]
    $zeilen = [ordered]@{}
    if (Test-Path $verlauf) {
        foreach ($z in (Get-Content $verlauf -Raw -Encoding UTF8 | ConvertFrom-Json).tage) { $zeilen[$z[0]] = $z }
    }
    $neu = $zeilen.Count -eq 0

    # Aktuelle Preise: letzte 31 Tage bis übermorgen
    $start = $heute.AddDays(-31).ToString('yyyy-MM-dd')
    $ende  = $heute.AddDays(2).ToString('yyyy-MM-dd')
    $aktuellJson = Hole "https://api.energy-charts.info/price?bzn=CH&start=$start&end=$ende"
    $aktuell = $aktuellJson | ConvertFrom-Json

    $tage = @{}
    Sammle-Tage $aktuell $tage

    # Beim ersten Lauf: alle Jahre seit 2015 nachladen
    if ($neu) {
        for ($jahr = $ersterTag.Year; $jahr -le $heute.Year; $jahr++) {
            $von = "$jahr-01-01"; $bis = "$jahr-12-31"
            if ($jahr -eq $heute.Year) { $bis = $start }
            Write-Output "Lade Verlauf $jahr ..."
            Sammle-Tage ((Hole "https://api.energy-charts.info/price?bzn=CH&start=$von&end=$bis") | ConvertFrom-Json) $tage
            Start-Sleep -Seconds 3
        }
    }

    # Wechselkurse je Tag (EZB, nur Werktage; sonst gilt der letzte bekannte Kurs)
    $fxVon = if ($neu) { $ersterTag.AddDays(-7) } else { $heute.AddDays(-40) }
    $fx = Hole ("https://api.frankfurter.dev/v1/" + $fxVon.ToString('yyyy-MM-dd') + ".." + $heute.ToString('yyyy-MM-dd') + "?base=EUR&symbols=CHF") | ConvertFrom-Json
    $kurse = @{}
    foreach ($eigenschaft in $fx.rates.PSObject.Properties) { $kurse[$eigenschaft.Name] = [double]$eigenschaft.Value.CHF }
    $kursTage = @($kurse.Keys | Sort-Object)
    $letzterKursTag = $kursTage[-1]
    $kurs = $kurse[$letzterKursTag]

    # Abgeschlossene Tage (vor heute) in den Verlauf übernehmen; Tage und Kurse laufen beide sortiert
    $heuteText = $heute.ToString('yyyy-MM-dd')
    $ki = 0; $tagesKurs = $null
    foreach ($tag in ($tage.Keys | Where-Object { $_ -lt $heuteText -and $_ -ge '2015-01-01' } | Sort-Object)) {
        while ($ki -lt $kursTage.Count -and $kursTage[$ki] -le $tag) { $tagesKurs = $kurse[$kursTage[$ki]]; $ki++ }
        $e = $tage[$tag]
        $peak = if ($e.pd -gt 0) { $e.ps / $e.pd } else { $null }
        $zeilen[$tag] = @($tag, ($e.s / $e.d), $peak, $e.min, $e.max, $tagesKurs)
    }

    $sortiert = @($zeilen.Keys | Sort-Object)
    $verlaufJson = '[' + (($sortiert | ForEach-Object {
        $z = $zeilen[$_]
        '["' + $z[0] + '",' + (Zahl $z[1]) + ',' + (Zahl $z[2]) + ',' + (Zahl $z[3]) + ',' + (Zahl $z[4]) + ',' + (Zahl $z[5]) + ']'
    }) -join ",`n") + ']'

    $kursText = $kurs.ToString($inv)
    $jetzt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $daten = '{"generated":"' + $jetzt + '","eurchf":' + $kursText + ',"eurchfDate":"' + $letzterKursTag +
             '","zones":{"CH":' + $aktuellJson + '},"verlauf":' + $verlaufJson + '}'

    $html = [IO.File]::ReadAllText($vorlage, [Text.Encoding]::UTF8)
    $html = $html.Replace('/*DATEN*/', $daten.Replace('</', '<\/'))
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText($ziel + '.tmp', $html, $utf8)
    [IO.File]::WriteAllText($verlauf + '.tmp', '{"tage":' + $verlaufJson + '}', $utf8)
    Move-Item -Path ($ziel + '.tmp') -Destination $ziel -Force
    Move-Item -Path ($verlauf + '.tmp') -Destination $verlauf -Force

    Schreibe-Log ("OK: Preise bis $ende geholt, Verlauf " + $sortiert[0] + " bis " + $sortiert[-1] + ", 1 EUR = $kursText CHF")
} catch {
    Schreibe-Log ("FEHLER: " + $_.Exception.Message)
    exit 1
}
