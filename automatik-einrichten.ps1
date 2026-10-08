# Richtet eine geplante Windows-Aufgabe ein, die aktualisieren.ps1 automatisch startet:
# täglich um 13:30 (neue Day-Ahead-Preise für morgen), um 07:00 und beim Anmelden.
# Entfernen: Unregister-ScheduledTask -TaskName 'Strompreise Liechtenstein' -Confirm:$false

$skript = Join-Path $PSScriptRoot 'aktualisieren.ps1'
$aktion = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$skript`""
$ausloeser = @(
    (New-ScheduledTaskTrigger -Daily -At '07:00'),
    (New-ScheduledTaskTrigger -Daily -At '13:30'),
    (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)
)
$einstellungen = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask -TaskName 'Strompreise Liechtenstein' -Action $aktion -Trigger $ausloeser `
    -Settings $einstellungen -Description 'Holt die Day-Ahead-Strompreise CH/AT für das Dashboard' -Force | Out-Null

Write-Output "Geplante Aufgabe 'Strompreise Liechtenstein' eingerichtet."
