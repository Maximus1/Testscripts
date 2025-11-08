# Hardcoded Video-Pfad
$Pfad = "Z:\TV\Star Trek Lower Decks S03E07 German DL 720p BluRay x264 REPACK-iNTENTiON\star.trek.lower.decks.s03e07.german.dl.720p.bluray.x264.repack-intention.mkv"

# Hardcoded FFmpeg-Pfad
$ffmpeg = "F:\ffmpeg-2025-11-02-git-f5eb11a71d-full_build\bin\ffmpeg.exe"

if (-not (Test-Path $Pfad)) {
    Write-Host "Video-Datei nicht gefunden: $Pfad"
    exit
}

Write-Host "Analysiere Video: $Pfad"

# Differenzvideo + signalstats berechnen
#$motionData = & $ffmpeg -ss 180 -to 550 -hide_banner -i $Pfad -vf "tblend=all_mode=difference,signalstats" -an -f null - 2>&1
$motionData = & $ffmpeg -flags2 +export_mvs -i $Pfad -vf "codecview=mv=pf+bf+bb" -an -f null -



# Alle Y-Werte extrahieren
$motionValues = @()
foreach ($line in $motionData) {
    if ($line -match 'YMIN=([\d\.]+)\s+YMAX=([\d\.]+)\s+YAVG=([\d\.]+)') {
        $motionValues += [double]$matches[3]  # YAVG falls vorhanden
    } elseif ($line -match 'Y=([\d\.]+)') {
        $motionValues += [double]$matches[1]  # sonst Y
    }
}

if ($motionValues.Count -eq 0) {
    Write-Host "Keine Bewegungsdaten gefunden."
    exit
}

# Berechnungen
$avgMotion = ($motionValues | Measure-Object -Average).Average
$maxMotion = ($motionValues | Measure-Object -Maximum).Maximum
$minMotion = ($motionValues | Measure-Object -Minimum).Minimum

Write-Host "`nBewegungsanalyse (Frame-Differenzen):"
Write-Host ("  Durchschnittliche Bewegung : {0:N3}" -f $avgMotion)
Write-Host ("  Maximale Bewegung          : {0:N3}" -f $maxMotion)
Write-Host ("  Minimale Bewegung          : {0:N3}" -f $minMotion)

# Optional: CRF Empfehlung basierend auf Bewegung
if ($avgMotion -lt 1) { $crf = 24 }
elseif ($avgMotion -lt 3) { $crf = 22 }
else { $crf = 20 }

Write-Host "Empfohlener CRF-Wert: $crf"
