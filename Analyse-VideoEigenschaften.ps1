#Animation vs. Realfilm : Bildanalyse (Farbkomplexität, Kanten), Bewegung (Motion Vectors) und Typ (Animation/Realfilm) eines Videos zur Optimierung des Transcodings.
#Bewegungsgeschwindigkeit : Hohe Bewegung (Action) vs. geringe Bewegung (Dialogszenen) zur Anpassung der CRF-Werte.
#Helligkeit : Durchschnittliche Helligkeit (Luma) des Videos zur Anpassung der Helligkeitseinstellungen.

#Helligkeitsmessung OK
#Bewegungsschätzung (Motion Vectors) ToDO
#Animation vs. Realfilm über .nfo-Datei OK
#Animation vs. Realfilm über Farbanalyse (Farbkomplexität, Kanten) ToDO
#



#region Script-Information
# PowerShell-Skript zur detaillierten Analyse von Videodateien für optimales Transcoding.
#
# ANALYSE-ZIELE:
# 1. Helligkeit: Misst die durchschnittliche Helligkeit (Luma) in einem definierten Zeitfenster durch Stichproben.
# 2. Bewegung: Schätzt die allgemeine Bewegungsintensität im Video.
# 3. Typ: Versucht, zwischen Animation und Realfilm zu unterscheiden (via .nfo-Datei).
#
# ANWENDUNG:
# Führen Sie das Skript aus und wählen Sie eine einzelne Videodatei zur Analyse aus.
# Die Ergebnisse werden auf der Konsole ausgegeben.
#endregion

#region Konfiguration
# Pfad zur FFmpeg-Anwendung. Dieser muss korrekt gesetzt sein.
$ffmpegPath = "F:\media-autobuild_suite-master1\local64\bin-video\ffmpeg.exe"
# Pfad zur ImageMagick-Anwendung.
$magickPath = "C:\Program Files\ImageMagick-7.1.2-Q16-HDRI\magick.exe"

# Konfiguration für die Helligkeitsanalyse
$brightness_SampleIntervalSeconds = 5 # Alle wie viele Sekunden soll ein Frame analysiert werden? (5-10 ist ein guter Wert)
$brightness_StartTimeSeconds = 180   # Startzeit für die Analyse (Minute 3)

# Konfiguration für die Bewegungsanalyse
$motion_NumberOfSegments = 5 # Anzahl der zu analysierenden Segmente
$motion_SegmentLengthFrames = 250 # Länge jedes Segments in Frames

#endregion

#region Hilfsfunktionen (aus vorhandenen Skripten übernommen)

function Get-FFmpegOutput {
    param ([array]$ArgumentList)
    # Führt FFmpeg mit den übergebenen Argumenten aus und fängt die Standardfehlerausgabe (stderr) ab.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ffmpegPath
    $startInfo.Arguments = $ArgumentList
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $process.Start() | Out-Null
    $output = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return $output
}

function Get-BasicVideoInfo {
    param ([string]$FilePath)
    # Extrahiert grundlegende Video-Metadaten (Dauer, FPS) aus der FFmpeg-Ausgabe.
    $info = @{}
    $output = Get-FFmpegOutput -ArgumentList "-i", "`"$FilePath`""

    if ($output -match "fps,\s*(\d+(\.\d+)?)") {
        $info.FPS = [double]$matches[1]
    } else {
        $info.FPS = 25 # Fallback-Wert
    }

    if ($output -match "Duration:\s*(\d+):(\d+):(\d+)\.(\d+)") {
        $h = [int]$matches[1]; $m = [int]$matches[2]; $s = [int]$matches[3]; $ms = [int]$matches[4]
        $info.Duration = $h * 3600 + $m * 60 + $s + ($ms / 100)
    } else {
        $info.Duration = 0
    }
    return $info
}

function Get-VideoType {
    param ([string]$FilePath)
    # Prüft, ob eine .nfo-Datei existiert und das Genre "Animation", "Zeichentrick" oder "Anime" enthält.
    $nfoPath = [System.IO.Path]::ChangeExtension($FilePath, ".nfo")
    if (Test-Path $nfoPath) {
        $nfoContent = Get-Content -Path $nfoPath -Raw
        if ($nfoContent -match "<genre>Animation</genre>" -or
            $nfoContent -match "<genre>Zeichentrick</genre>" -or
            $nfoContent -match "<genre>Anime</genre>") {
            return "Animation"
        }
    }
    return "Realfilm"
}

#endregion

#region Analyse-Funktionen (Neu)

function Get-VideoBrightnessInfo {
    param (
        [string]$FilePath,
        [double]$Duration,
        [double]$FPS
    )

    Write-Host "Starte Helligkeitsanalyse..." -ForegroundColor Cyan

    # Erstelle einen temporären Unterordner im Verzeichnis der Videodatei.
    $videoDirectory = Split-Path -Path $FilePath -Parent
    $tempFolderName = "temp_frames_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $tempFrameFolder = Join-Path -Path $videoDirectory -ChildPath $tempFolderName
    New-Item -ItemType Directory -Path $tempFrameFolder | Out-Null

    try {
        # Berechne Start- und Endzeit für die Analyse
        $endTimeSeconds = $Duration * 0.90 # Ende bei 90% der Gesamtdauer
        if ($brightness_StartTimeSeconds -ge $endTimeSeconds) {
            Write-Warning "Analysezeitraum ist ungültig (Startzeit ist nach Endzeit). Überspringe Helligkeitsanalyse."
            return $null
        }

        # Berechne die Rate für den fps-Filter (z.B. 1/5 für alle 5 Sekunden ein Bild)
        $fpsRate = "1/$brightness_SampleIntervalSeconds"

        # FFmpeg-Argumente als String zusammenbauen, um Probleme mit der Parameterübergabe zu vermeiden.
        $outputFramePattern = Join-Path -Path $tempFrameFolder -ChildPath "frame_%05d.png"
        $ffmpegArgsString = "-i `"$FilePath`" -ss $brightness_StartTimeSeconds -to $endTimeSeconds -vf `"fps=$fpsRate,format=gray`" -an `"$outputFramePattern`""

        # Führe FFmpeg aus, um die Frames zu extrahieren
        # Der direkte Aufruf mit Start-Process ist hier robuster als die Wrapper-Funktion.
        $process = Start-Process -FilePath $ffmpegPath -ArgumentList $ffmpegArgsString -NoNewWindow -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            Write-Warning "FFmpeg wurde mit einem Fehlercode beendet: $($process.ExitCode). Keine Frames extrahiert."
            # Hier könnte man die FFmpeg-Fehlerausgabe loggen, falls gewünscht.
            return $null
        }

        # Prüfen, ob Frames existieren
        $frames = Get-ChildItem -Path $tempFrameFolder -Filter "*.png"
        if ($frames.Count -eq 0) {
            Write-Warning "Keine Frames erzeugt. FFmpeg hat möglicherweise nichts extrahiert."
            return $null
        }

        # Helligkeit jedes Frames mit ImageMagick messen
        $helligkeitsWerte = @()
        foreach ($frame in $frames) {
            $res = & $magickPath $frame.FullName -format "%[fx:mean*255]" info:
            $helligkeitsWerte += [double]$res
        }

        # Statistik berechnen
        $min = [math]::Round(($helligkeitsWerte | Measure-Object -Minimum).Minimum, 2)
        $max = [math]::Round(($helligkeitsWerte | Measure-Object -Maximum).Maximum, 2)
        $avg = [math]::Round(($helligkeitsWerte | Measure-Object -Average).Average, 2)

        return [PSCustomObject]@{
            Average = $avg
            Minimum = $min
            Maximum = $max
        }
    }
    finally {
        # Stelle sicher, dass der temporäre Ordner immer gelöscht wird
        if (Test-Path $tempFrameFolder) {
            Remove-Item -Path $tempFrameFolder -Recurse -Force
        }
    }
}

function Get-VideoMotionInfo {
    param (
        [string]$FilePath,
        [double]$Duration
    )

    Write-Host "Starte Bewegungsanalyse..." -ForegroundColor Cyan

    # Berechne Start- und Endzeit für die Analyse
    $startTimeSeconds = $brightness_StartTimeSeconds
    $endTimeSeconds = $Duration * 0.90

    if ($startTimeSeconds -ge $endTimeSeconds) {
        Write-Warning "Analysezeitraum ist ungültig (Startzeit ist nach Endzeit). Überspringe Bewegungsanalyse."
        return $null
    }

    $analysisWindowDuration = $endTimeSeconds - $startTimeSeconds
    $segmentSpacing = $analysisWindowDuration / ($motion_NumberOfSegments + 1)

    $allMotionValuesX = @()
    $allMotionValuesY = @()

    # Führe die Analyse für mehrere verteilte Segmente durch
    for ($i = 1; $i -le $motion_NumberOfSegments; $i++) {
        $segmentStartTime = $startTimeSeconds + ($i * $segmentSpacing)
        Write-Host "  -> Analysiere Bewegungssegment $i von $motion_NumberOfSegments bei $([TimeSpan]::FromSeconds($segmentStartTime).ToString('hh\:mm\:ss'))"

        # FFmpeg-Argumente als String zusammenbauen, um Probleme mit der Parameterübergabe zu vermeiden.
        $ffmpegArgsString = "-ss $segmentStartTime -i `"$FilePath`" -vf mestimate -frames:v $motion_SegmentLengthFrames -an -f null -"

        # Der direkte Aufruf mit Start-Process und Umleitung der Ausgabe ist hier robuster.
        $tempErrorFile = [System.IO.Path]::GetTempFileName()
        $process = Start-Process -FilePath $ffmpegPath -ArgumentList $ffmpegArgsString -NoNewWindow -Wait -PassThru -RedirectStandardError $tempErrorFile
        $output = Get-Content -Path $tempErrorFile -Raw
        Remove-Item -Path $tempErrorFile -Force

        if ($process.ExitCode -ne 0) {
            Write-Warning "FFmpeg wurde bei der Bewegungsanalyse mit einem Fehlercode beendet: $($process.ExitCode)."
        }

        # Extrahiere die durchschnittliche Größe der Bewegungsvektoren (p-mv-x, p-mv-y) für dieses Segment
        $motionMatches = $output | Select-String -Pattern "p-mv-x:([0-9.]+) p-mv-y:([0-9.]+)" -AllMatches
        # Sicherheitsprüfung: Nur verarbeiten, wenn Treffer gefunden wurden.
        if ($null -ne $motionMatches) {
            $allMotionValuesX += $motionMatches.Matches.Groups[1].Value | ForEach-Object { [double]$_ }
            $allMotionValuesY += $motionMatches.Matches.Groups[2].Value | ForEach-Object { [double]$_ }
        }
    }

    if ($allMotionValuesX.Count -eq 0) {
        Write-Warning "Konnte keine Bewegungsinformationen extrahieren."
        return $null
    }

    # Berechne den Gesamtdurchschnitt der absoluten Bewegung über alle Segmente
    $averageMotionX = ($allMotionValuesX | Measure-Object -Average).Average
    $averageMotionY = ($allMotionValuesY | Measure-Object -Average).Average
    $averageMotion = [Math]::Abs($averageMotionX) + [Math]::Abs($averageMotionY)

    return [Math]::Round($averageMotion, 2)
}

#endregion

#region Hauptskript

Add-Type -AssemblyName System.Windows.Forms
$fileDialog = New-Object System.Windows.Forms.OpenFileDialog
$fileDialog.Title = "Wähle eine Videodatei zur Analyse aus"
$fileDialog.Filter = "Videodateien (*.mkv, *.mp4)|*.mkv;*.mp4|Alle Dateien (*.*)|*.*"

if ($fileDialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
    $selectedFile = $fileDialog.FileName
    Write-Host "Analysiere Datei: $selectedFile" -ForegroundColor Green
    Write-Host "--------------------------------------------------"

    # 1. Grundlegende Informationen abrufen (Dauer, FPS)
    $basicInfo = Get-BasicVideoInfo -FilePath $selectedFile
    if ($basicInfo.Duration -eq 0) {
        Write-Error "Konnte die Dauer des Videos nicht ermitteln. Abbruch."
        exit
    }
    Write-Host "Dauer: $([TimeSpan]::FromSeconds($basicInfo.Duration).ToString('hh\:mm\:ss'))"
    Write-Host "FPS: $($basicInfo.FPS)"
    Write-Host "--------------------------------------------------"

<#     # 2. Helligkeit analysieren
    $brightnessInfo = Get-VideoBrightnessInfo -FilePath $selectedFile -Duration $basicInfo.Duration -FPS $basicInfo.FPS
    if ($brightnessInfo) {
        Write-Host "ANALYSE-ERGEBNIS (HELLIGKEIT):" -ForegroundColor Yellow
        Write-Host "  Mittelwert : $($brightnessInfo.Average)"
        Write-Host "  Minimum    : $($brightnessInfo.Minimum)"
        Write-Host "  Maximum    : $($brightnessInfo.Maximum)"

        if ($brightnessInfo.Average -lt 60) {
            Write-Host "  Einschätzung: Sehr dunkles Video. Empfehlung: CRF um 1-2 senken, `aq-strength` erhöhen."
        } elseif ($brightnessInfo.Average -lt 100) {
            Write-Host "  Einschätzung: Eher dunkles bis normales Video."
        } else {
            Write-Host "  Einschätzung: Helles Video. Standard-CRF sollte gut funktionieren."
        }
        Write-Host "--------------------------------------------------"
    }
 #>
    # 3. Bewegung analysieren
    $avgMotion = Get-VideoMotionInfo -FilePath $selectedFile -Duration $basicInfo.Duration
    if ($avgMotion) {
        Write-Host "ANALYSE-ERGEBNIS (BEWEGUNG):" -ForegroundColor Yellow
        Write-Host "  Durchschnittliche Bewegung (Motion Vector Magnitude): $avgMotion"
        if ($avgMotion -gt 15) {
            Write-Host "  Einschätzung: Sehr hohe Bewegung (Action, Sport). Empfehlung: CRF um 1-2 senken."
        } elseif ($avgMotion -gt 8) {
            Write-Host "  Einschätzung: Normale bis hohe Bewegung."
        } else {
            Write-Host "  Einschätzung: Geringe Bewegung (ruhige Szenen, Dialoge). Standard-CRF ist ausreichend."
        }
        Write-Host "--------------------------------------------------"
    }

    # 4. Typ analysieren (Animation/Realfilm)
    $videoType = Get-VideoType -FilePath $selectedFile
    Write-Host "ANALYSE-ERGEBNIS (TYP):" -ForegroundColor Yellow
    Write-Host "  Erkannter Typ: $videoType"
    if ($videoType -eq "Animation") {
        Write-Host "  Empfehlung: `-tune animation` verwenden."
    } else {
        Write-Host "  Empfehlung: Standard-Encoder-Einstellungen verwenden."
    }
    Write-Host "--------------------------------------------------"

} else {
    Write-Host "Keine Datei ausgewählt. Skript wird beendet." -ForegroundColor Yellow
}

#endregion