#region Konfiguration
# Pfad zur FFmpeg-Anwendung. Dieser muss korrekt gesetzt sein, damit das Skript funktioniert.
$ffmpegPath = "F:\media-autobuild_suite-master1\local64\bin-video\ffmpeg.exe"
# Pfad zur mkvextract-Anwendung aus dem MKVToolNix-Paket.
$mkvextractPath = "C:\Program Files\MKVToolNix\mkvextract.exe"

# Ziel-Lautheit in LUFS für die Audionormalisierung (z.B. -18 für eine konsistente Lautstärke).
$targetLoudness = -18
$filePath = ''
# Liste der zu verarbeitenden Dateiendungen.
$extensions = @('.mkv', '.mp4', '.avi', '.m2ts')

# CRF-Wert (Constant Rate Factor) für Filme. Niedrigere Werte bedeuten höhere Qualität.
$crfTargetm = 18
# CRF-Wert für Serien.
$crfTargets = 20
# Encoder-Preset beeinflusst die Kodierungsgeschwindigkeit vs. Kompression (z.B. 'medium', 'slow').
$encoderPreset = 'medium'
# Der Ziel-Videocodec für die Transkodierung.
$videoCodecHEVC = 'HEVC'

# Zieldateiendung für alle verarbeiteten Dateien.
$targetExtension = '.mkv'
$script:filesnotnorm = @()
$script:filesnorm = @()

# Qualitätsstufen für die Berechnung der erwarteten Dateigröße, um unnötig große Dateien zu erkennen.
$qualitätFilm = "hoch"
$qualitätSerie = "hoch"


#endregion

#region Hilfsfunktionen

function Test-IsNormalized {
    # Überprüft, ob eine MKV-Datei bereits ein "NORMALIZED=true"-Tag in ihren Metadaten enthält.
    param (
        [string]$file
    )

    if (!(Test-Path $mkvextractPath)) {
        Write-Error "mkvextract.exe nicht gefunden unter $mkvextractPath"
        "`n==== mkvextract.exe nicht gefunden unter $mkvextractPath ====" | Add-Content -LiteralPath (Join-Path $destFolder "Normalization_Check.log")
        return $false
    }

    # Erstellt eine temporäre XML-Datei, um die Tag-Ausgabe von mkvextract zu speichern.
    $tempXml = [System.IO.Path]::GetTempFileName()

    try {
        # Extrahiert die Metadaten-Tags der Videodatei und leitet sie in die temporäre XML-Datei um.
        & $mkvextractPath tags "$file" > $tempXml 2>$null

        # Liest den gesamten Inhalt der XML-Datei.
        $xmlText = Get-Content -Path $tempXml -Raw -Encoding UTF8

        if ([string]::IsNullOrWhiteSpace($xmlText)) {
            throw "Extrahierter XML-Inhalt ist leer oder ungültig."
        }
        # Versucht, den Text als XML zu parsen. Schlägt dies fehl, ist es wahrscheinlich keine gültige MKV-Datei.
        try {
            [xml]$xml = $xmlText
        } catch {
            $script:filesnotnorm += $file # Datei zur Verarbeitung hinzufügen
            Write-Warning "Konnte XML nicht parsen (vermutlich keine MKV): $file"
            "`n==== Konnte XML nicht parsen (vermutlich keine MKV): $file ====" | Add-Content -LiteralPath (Join-Path $destFolder "Normalization_Check.log")
            return $false
        }

        # Durchsucht das XML-Dokument nach einem 'NORMALIZED'-Tag mit dem spezifischen Wert 'true'.
        $normalized = $xml.SelectNodes('//Simple[Name="NORMALIZED"]/String') |
                      Where-Object { $_.InnerText -eq 'true' }

        if ($null -eq $normalized -or $normalized.Count -eq 0) {
            $script:filesnotnorm += $file
            return $false
        } else {
            $script:filesnorm += $file
            return $true
        }
    }
    catch {
        $script:filesnotnorm += $file
        # Fängt alle Fehler während der Verarbeitung ab (z.B. bei beschädigten Dateien) und stuft die Datei sicherheitshalber als "nicht normalisiert" ein.
        Write-Warning "Fehler beim Verarbeiten von $file`nGrund: $_"
        "`n==== Fehler beim Verarbeiten von $file`nGrund: $_ ====" | Add-Content -LiteralPath (Join-Path $destFolder "Normalization_Check.log")
        return $false
    }
    finally {
        # Stellt sicher, dass die temporäre XML-Datei nach der Verarbeitung immer gelöscht wird.
        if (Test-Path $tempXml) {
            Remove-Item $tempXml -Force
        }
    }
}
function Get-MediaInfo {
    param ([string]$filePath, [string]$logDatei)
    # Sammelt umfassende Metadaten einer Videodatei durch die Kombination mehrerer Analysefunktionen.

    if (!(Test-Path -LiteralPath $filePath)) {
        Write-Host "FEHLER: Datei nicht gefunden: $filePath" -ForegroundColor Red
        return $null
    }

    $ffmpegOutput = Get-FFmpegOutput -FilePath $filePath
    $mediaInfo = @{}

    # Ruft grundlegende Videoinformationen wie Dauer, Codec und Auflösung ab.
    $mediaInfo += Get-BasicVideoInfo -Output $ffmpegOutput -FilePath $filePath
    # Ermittelt Farbinformationen wie Bittiefe und HDR-Status.
    $mediaInfo += Get-ColorAndHDRInfo -Output $ffmpegOutput
    # Extrahiert Audioinformationen wie Kanalanzahl und Codec.
    $mediaInfo += Get-AudioInfo -Output $ffmpegOutput
    # Prüft, ob das Video Interlaced-Material enthält.
    $mediaInfo += Get-InterlaceInfo -FilePath $filePath
    # Prüft, ob der Dateiname einem Serienmuster (SxxExx) entspricht.
    $mediaInfo += Test-IsSeries -filename $filePath -logDatei $logDatei -sourceInfo $mediaInfo


    # Analysiert, ob eine Neukodierung basierend auf der Dateigröße im Verhältnis zur Laufzeit empfohlen wird.
    $mediaInfo += Get-RecodeAnalysis -MediaInfo $mediaInfo -logDatei $logDatei

    # Speichert die ursprünglichen Dauer-Werte, da sie in späteren Analysen überschrieben werden könnten.
    if ($mediaInfo.Duration -and -not $mediaInfo.ContainsKey("Duration1")) {
        $mediaInfo.Duration1 = $mediaInfo.Duration
    }
    if ($mediaInfo.DurationFormatted -and -not $mediaInfo.ContainsKey("DurationFormatted1")) {
        $mediaInfo.DurationFormatted1 = $mediaInfo.DurationFormatted
    }
    # Gibt eine Zusammenfassung der ermittelten Medieninformationen auf der Konsole aus.
    Write-Host "Video: $($mediaInfo.DurationFormatted1) | $($mediaInfo.VideoCodec) | $($mediaInfo.Resolution) | Interlaced: $($mediaInfo.Interlaced) | FPS: $($mediaInfo.FPS)" -ForegroundColor DarkCyan
    Write-Host "Audio: $($mediaInfo.AudioChannels) Kanäle | $($mediaInfo.AudioCodec)" -ForegroundColor DarkCyan
    return $mediaInfo
}
#region Hilfsfunktionen zu Get-MediaInfo
function Get-FFmpegOutput {
    param ([string]$FilePath)
    # Führt 'ffmpeg -i' für eine Datei aus und fängt die Standardfehlerausgabe (stderr) ab, die die Metadaten enthält.

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ffmpegPath
    $startInfo.Arguments = "-hwaccel d3d11va -i `"$FilePath`""
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
    param (
        [string]$Output,
        [string]$FilePath
    )
    # Extrahiert grundlegende Video-Metadaten (Größe, FPS, Dauer, Codec, Auflösung) aus der FFmpeg-Ausgabe.
    $info = @{}
    $size = (Get-Item $FilePath).Length
    $info.FileSizeBytes = $size

    if ($Output -match "fps,\s*(\d+(\.\d+)?)") {
        $info.FPS = [double]$matches[1]
    }

    if ($Output -match "Duration:\s*(\d+):(\d+):(\d+)\.(\d+)") {
        $h = [int]$matches[1]; $m = [int]$matches[2]; $s = [int]$matches[3]; $ms = [int]$matches[4]
        $info.Duration = $h * 3600 + $m * 60 + $s + ($ms / 100)
        $info.DurationFormatted1 = "{0:D2}:{1:D2}:{2:D2}.{3:D2}" -f $h, $m, $s, $ms
    }

    if ($Output -match "Video:\s*([^\s,]+)") {
        $info.VideoCodecSource = $matches[1]
        $info.VideoCodec = $matches[1]
    }

    if ($Output -match "Video:.*?,\s+(\d+)x(\d+)") {
        $info.Resolution = "$($matches[1])x$($matches[2])"
    }
    return $info
}
function Get-ColorAndHDRInfo {
    param ([string]$Output)
    $info = @{}
    # Analysiert die FFmpeg-Ausgabe, um Farbinformationen wie Bittiefe, Farbraum und HDR-Formate zu ermitteln.

    if ($Output -match "yuv\d{3}p(\d{2})\w*\(([^)]*)\)") {
        $info.BitDepth = [int]$matches[1]
        $info.Is12BitOrMore = $info.BitDepth -ge 12
        $colorParts = $matches[2].Split("/")
        foreach ($part in $colorParts) {
            switch ($part.Trim()) {
                { $_ -match "^(tv|pc)$" }     { $info.ColorRange = $_ }
                { $_ -match "^bt\d+" }        { $info.ColorPrimaries = $_ }
                { $_ -match "smpte|hlg|pq" }  { $info.TransferCharacteristics = $_ }
            }
        }
    } elseif ($Output -match "yuv\d{3}p(\d{2})") {
        $info.BitDepth = [int]$matches[1]
        $info.Is12BitOrMore = $info.BitDepth -ge 12
    } else {
        $info.BitDepth = 8
        $info.Is12BitOrMore = $false
    }

    if ($Output -match "(HDR10\+?|Dolby\s+Vision|HLG|PQ|BT\.2020|smpte2084|arib-std-b67)") {
        $info.HDR = $true
        $info.HDR_Format = $matches[1]
    } else {
        $info.HDR = $false
        $info.HDR_Format = "Kein HDR"
    }

    return $info
}
function Get-AudioInfo {
    param ([string]$Output)
    $info = @{}
    # Extrahiert Audio-Metadaten (Kanalanzahl und Codec) aus der FFmpeg-Ausgabe.

    if ($Output -match "Audio:.*?,\s*\d+\s*Hz,\s*([0-9\.]+)\s*channels?") {
        $info.AudioChannels = [int]$matches[1]
    } elseif ($Output -match "Audio:.*?,\s*\d+\s*Hz,\s*([^\s,]+),") {
        switch -Regex ($matches[1]) {
            "mono"   { $info.AudioChannels = 1 }
            "stereo" { $info.AudioChannels = 2 }
            "5\.1"   { $info.AudioChannels = 6 }
            "7\.1"   { $info.AudioChannels = 8 }
            default  { $info.AudioChannels = 0 }
        }
    }

    if ($Output -match "Audio:\s*([\w\-\d]+)") {
        $info.AudioCodec = $matches[1]
    }

    return $info
}
function Get-InterlaceInfo {
    param ([string]$FilePath)
    $info = @{}
    # Verwendet den 'idet'-Filter von FFmpeg, um festzustellen, ob ein Video Interlaced-Material ist.

    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $ffmpegPath
        $startInfo.Arguments = "-i `"$FilePath`" -filter:v idet -frames:v 1500 -an -f null NUL"
        $startInfo.RedirectStandardError = $true
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $startInfo
        $proc.Start() | Out-Null
        $output = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()

        $match = [regex]::Matches($output, "Multi frame detection:\s*TFF:\s*(\d+)\s*BFF:\s*(\d+)\s*Progressive:\s*(\d+)")
        if ($match.Count -gt 0) {
            $last = $match[$match.Count - 1]
            $tff = [int]$last.Groups[1].Value
            $bff = [int]$last.Groups[2].Value
            $prog = [int]$last.Groups[3].Value
            $info.Interlaced = ($tff + $bff) -gt $prog
        }
    } catch {
        $info.Interlaced = $false
    }

    return $info
}
function Test-IsSeries {
    param(
        # Erkennt anhand des Dateinamens (SxxExx-Muster), ob es sich um eine Serie handelt, und prüft, ob eine Skalierung auf 720p nötig ist.
        [string]$filename,
        [hashtable]$sourceInfo,
        [string]$logDatei
    )
    $info = @{}
    if ($filename -match "S\d+E\d+") {
        $info.IsSeries = $true
        if ($sourceInfo.Resolution -match "^(\d+)x(\d+)$") {
            $width = [int]$matches[1]
            $height = [int]$matches[2]
            if ($width -gt 1280 -or $height -gt 720) {
                $info.resize = $true
                $info.Force720p = $true
                Write-Host "Auflösung > 1280x720 erkannt: Resize und Force720p aktiviert." -ForegroundColor Yellow
                "`n==== Auflösung > 1280x720 erkannt: Resize und Force720p aktiviert. ====" | Add-Content -LiteralPath $logDatei
            } else {
                $info.resize = $false
                $info.Force720p = $false
            }
        }
        Write-Host "Datei als Serie erkannt: $filename" -ForegroundColor Green
        "`n==== Datei als Serie erkannt: $filename ====" | Add-Content -LiteralPath $logDatei
    }
    else {
        $info.IsSeries = $false
        $info.Force720p = $false
        Write-Host "Datei nicht als Serie erkannt: $filename"
        "`n==== Datei nicht als Serie erkannt: $filename ====" | Add-Content -LiteralPath $logDatei
    }
    return $info
}
function Get-RecodeAnalysis {
    param (
        # Vergleicht die tatsächliche Dateigröße mit einer erwarteten Größe, um zu entscheiden, ob eine Neukodierung zur Platzersparnis sinnvoll ist.
        [hashtable]$MediaInfo,
        [string]$logDatei
    )

    # Prüft zuerst, ob der Codec bereits dem Zielcodec entspricht.
    if ($sourceInfo.VideoCodecSource -ne $videoCodecHEVC) {
        $mediaInfo = @{ RecodeRecommended = $true }
        Write-Host "Recode erforderlich: Video-Codec ist '$($sourceInfo.VideoCodecSource)' und nicht '$videoCodecHEVC'." -ForegroundColor Yellow
        "`n==== Recode erforderlich: Video-Codec ist '$($sourceInfo.VideoCodecSource)' und nicht '$videoCodecHEVC'. ====" | Add-Content -LiteralPath $logDatei
    }
    else {
        # Wenn der Codec bereits korrekt ist, wird die Dateigröße geprüft.
        $fileSizeBytes = $MediaInfo.FileSizeBytes
        $fileSizeMB = $fileSizeBytes / 1MB
        $duration = $MediaInfo.Duration
        # Berechnet die erwartete Dateigröße basierend auf der Laufzeit und vordefinierten Qualitätsraten.
        $expectedSizeMB = Measure-ExpectedSizeMB -durationSeconds $duration -isSeries $MediaInfo.IsSeries -logDatei $logDatei
        # Empfiehlt eine Neukodierung, wenn die Datei signifikant (hier >50%) größer als erwartet ist.
        if ($fileSizeMB -gt ($expectedSizeMB * 1.5)) {
            $mediaInfo = @{ RecodeRecommended = $true }
            Write-Host "Recode empfohlen: Datei ist deutlich größer als erwartet ($([math]::Round($fileSizeMB,2)) MB > $expectedSizeMB MB)" -ForegroundColor Yellow
            "`n==== Recode empfohlen: Datei ist deutlich größer als erwartet ($([math]::Round($fileSizeMB,2)) MB > $expectedSizeMB MB) ====" | Add-Content -LiteralPath $logDatei
        }
        else {
            $mediaInfo = @{ RecodeRecommended = $false }
            Write-Host "Kein Recode nötig: Dateigröße ist im erwarteten Bereich ($([math]::Round($fileSizeMB,2)) MB ≤ $expectedSizeMB MB)" -ForegroundColor Green
            "`n==== Kein Recode nötig: Dateigröße ist im erwarteten Bereich ($([math]::Round($fileSizeMB,2)) MB ≤ $expectedSizeMB MB) ====" | Add-Content -LiteralPath $logDatei
        }
    }

    return $mediaInfo
}
function Measure-ExpectedSizeMB {
    param (
        # Berechnet eine erwartete Zieldateigröße in MB basierend auf der Videolänge und unterschiedlichen Raten für Filme und Serien.
        [double]$durationSeconds,
        [bool]$isSeries,
        [string]$logDatei
    )

    # Vordefinierte Bitraten (in MB pro Sekunde) für verschiedene Qualitätsstufen bei Filmen.
    $filmRates = @{
        "niedrig" = 0.25
        "mittel"  = 0.4
        "hoch"    = 0.7
        "sehrhoch"= 1.0
    }
    # Vordefinierte Bitraten (in MB pro Sekunde) für verschiedene Qualitätsstufen bei Serien.
    $serieRates = @{
        "niedrig" = 0.1
        "mittel"  = 0.14
        "hoch"    = 0.3
        "sehrhoch"= 0.5
    }

    # Wählt die passende Raten-Tabelle und Qualitätsstufe basierend auf dem Medientyp.
    if ($isSeries -eq $true) {
        $quality = $qualitätSerie.ToLower()
        $rates = $serieRates
    }
    else {
        $quality = $qualitätFilm.ToLower()
        $rates = $filmRates
    }

    # Fallback auf 'mittel', falls eine ungültige Qualitätsstufe konfiguriert wurde.
    if (-not $rates.ContainsKey($quality)) {
        Write-Warning "Qualität '$quality' nicht definiert. Nutze 'mittel'."
        "`n==== Qualität '$quality' nicht definiert. Nutze 'mittel'. ====" | Add-Content -LiteralPath $logDatei
        $quality = "mittel"
    }

    $mbPerSecond = $rates[$quality]
    $expectedSizeMB = [math]::Round($mbPerSecond * $durationSeconds, 2)
    return $expectedSizeMB
}
#endregion
function Get-MediaInfo2 {
    param (
        # Eine schlankere Version von Get-MediaInfo, die speziell für die Analyse von Ausgabedateien nach der Konvertierung gedacht ist.
        [string]$filePath
    )

    $mediaInfoout = @{}

    try {
        # FFmpeg-Analyse durchführen
        $infoOutput = Get-FFmpegOutput -FilePath $filePath

        # Extrahiert die Dauer aus der FFmpeg-Ausgabe.
        if ($infoOutput -match "Duration:\s*(\d+):(\d+):(\d+)\.(\d+)") {
            $h = [int]$matches[1]
            $m = [int]$matches[2]
            $s = [int]$matches[3]
            $ms = [int]$matches[4]
            $mediaInfoout.Duration = $h * 3600 + $m * 60 + $s + ($ms / 100)
            $mediaInfoout.DurationFormatted = "{0:D2}:{1:D2}:{2:D2}.{3:D2}" -f $h, $m, $s, $ms
        } else {
            Write-Host "WARNUNG: Konnte Dauer nicht extrahieren" -ForegroundColor Yellow
            $mediaInfoout.Duration = 0
            $mediaInfoout.DurationFormatted = "00:00:00.00"
        }

        # Ruft Basis-Videoinformationen ab.
        $videoInfo = Get-BasicVideoInfo -Output $infoOutput -FilePath $filePath
        $videoInfo.Remove("Duration") | Out-Null
        $videoInfo.Remove("DurationFormatted") | Out-Null
        $mediaInfoout += $videoInfo

        # Ruft Audioinformationen ab.
        $mediaInfoout += Get-AudioInfo -Output $infoOutput

        # Gibt eine Zusammenfassung der erfassten Daten aus.
        Write-Host "Video: $($mediaInfoout.DurationFormatted) | $($mediaInfoout.VideoCodec) | $($mediaInfoout.Resolution)" -ForegroundColor DarkCyan
        Write-Host "Audio: $($mediaInfoout.AudioChannels) Kanäle | $($mediaInfoout.AudioCodec)" -ForegroundColor DarkCyan
    }
    catch {
        Write-Host "FEHLER: Medienanalyse fehlgeschlagen: $_" -ForegroundColor Red
        $mediaInfoout.Duration = 0
        $mediaInfoout.DurationFormatted = "00:00:00.00"
        $mediaInfoout.AudioChannels = 0
        $mediaInfoout.VideoCodec = "Fehler"
        $mediaInfoout.AudioCodec = "Fehler"
        $mediaInfoout.Resolution = "Unbekannt"
    }
    return $mediaInfoout
}
function Get-LoudnessInfo {
    param (
        [string]$filePath # Der Pfad zur zu analysierenden Videodatei.
    )
    # Analysiert die Audiospur einer Datei mit dem FFmpeg 'ebur128'-Filter, um die Lautheit (LUFS) zu bestimmen.
    try {
        # Erstellt eine temporäre Datei, um die Analyseausgabe von FFmpeg zu speichern.
        $tempOutputFile = [System.IO.Path]::GetTempFileName()
        # Startet den FFmpeg-Prozess für die Lautheitsanalyse. Die Ausgabe wird in die temporäre Datei umgeleitet.
        Write-Host "Starte FFmpeg zur Lautstärkeanalyse..." -ForegroundColor Cyan;
        "`n==== Starte FFmpeg zur Lautstärkeanalyse für $filePath ====" | Add-Content -LiteralPath $logDatei

        $ffmpegProcess = Start-Process -FilePath $ffmpegPath -ArgumentList "-i", "`"$($filePath)`"", "-vn", "-hide_banner", "-threads", "12", "-filter_complex", "[0:a:0]ebur128=metadata=1", "-f", "null", "NUL" -NoNewWindow -PassThru -RedirectStandardError $tempOutputFile
        $ffmpegProcess.WaitForExit()
        # Liest die Analyseergebnisse aus der temporären Datei.
        $ffmpegOutput = Get-Content -Path $tempOutputFile -Raw
        # Löscht die temporäre Datei nach der Analyse.
        Remove-Item -Path $tempOutputFile -Force -ErrorAction SilentlyContinue
        return $ffmpegOutput
    }
    catch {
        Write-Host "FEHLER: Fehler beim Ausführen von FFmpeg: $_" -ForegroundColor Red
        "`n==== Fehler beim Ausführen von FFmpeg: $_ ====" | Add-Content -LiteralPath $logDatei
        return $null
    }
}
function Set-VolumeGain {# Funktion zur Anpassung der Lautstärke mit FFmpeg
    param (
        [string]$filePath, # Pfad zur Eingabedatei
        [double]$gain, # Der anzuwendende Gain-Wert in dB
        [string]$outputFile, # Pfad für die Ausgabedatei
        [int]$audioChannels, # Anzahl der Audiokanäle in der Eingabedatei
        [string]$videoCodec, # Video Codec der Eingabedatei
        [bool]$interlaced, # Gibt an, ob das Video interlaced ist
        [int]$bitDepth
    )
    try {
        Write-Host "Starte FFmpeg zur Lautstärkeanpassung..." -ForegroundColor Cyan

        $ffmpegArguments = @(
            "-hide_banner",
            "-loglevel", "error",
            "-stats",
            "-y",
            "-hwaccel", "d3d11va", # Hardwarebeschleunigung für die Dekodierung aktivieren
            "-threads", "12", # Nutze alle verfügbaren CPU-Threads für maximale Leistung
            "-i", "`"$($filePath)`""
        )

# Prüfen ob BitDepth != 8 → immer reencode zu HEVC 8bit
        $needsReencodeDueToBitDepth = $false
        if ($bitDepth -ne 8) {
            Write-Host "⚠️ BitDepth ist $bitDepth, Reencode zu HEVC 8bit erforderlich" -ForegroundColor Yellow
            "`n==== BitDepth ist $bitDepth, Reencode zu HEVC 8bit erforderlich ====" | Add-Content -LiteralPath $logDatei
        $needsReencodeDueToBitDepth = $true
        }

        # Prüfen, ob es sich um eine alte AVI-Datei handelt, die eine Sonderbehandlung benötigt
        $isAviFile = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant() -eq '.avi'

        if ($isAviFile) {
            Write-Host "🎞️ AVI-Spezialbehandlung: Visuelle Verbesserung und Transkodierung zu HEVC 1080p..." -ForegroundColor Magenta
            "`n==== AVI-Spezialbehandlung: Visuelle Verbesserung und Transkodierung zu HEVC 1080p... ====" | Add-Content -LiteralPath $logDatei

            # Stellt die Filterkette dynamisch zusammen, basierend darauf, ob das Material interlaced ist.
            $baseFilter = "hqdn3d=1.0:1.5:3.0:4.5,scale=1920:-2,cas=strength=0.15"
            if ($interlaced) {
                Write-Host "  -> AVI ist interlaced, wende Deinterlacing an." -ForegroundColor Cyan
                $videoFilter = "bwdif=0:-1:0," + $baseFilter
            } else {
                Write-Host "  -> AVI ist progressiv, kein Deinterlacing nötig." -ForegroundColor Cyan
                $videoFilter = $baseFilter
            }

            $ffmpegArguments += @(
                "-c:v", "libx265",
                "-pix_fmt", "yuv420p",
                "-preset", "medium",
                "-crf", "20", # Etwas höhere Qualität für das restaurierte Material
                "-vf", $videoFilter,
                "-x265-params", "aq-mode=4:psy-rd=1.5:psy-rdoq=0.7:rd=3:bframes=8:ref=4:deblock=-1,-1:me=umh:subme=5:rdoq-level=1"
            )
        }
        # Prüft verschiedene Bedingungen, um zu entscheiden, ob eine Video-Neukodierung erforderlich ist.
        elseif ($sourceInfo.Force720p -or $sourceInfo.NeedsRecode -or $needsReencodeDueToBitDepth -or ($videoCodec -ne $videoCodecHEVC)) {
            Write-Host "🎞️ Transcode aktiv..." -ForegroundColor Cyan

            $ffmpegArguments += @(
                "-c:v", "libx265",
                "-pix_fmt", "yuv420p",  # 8 Bit erzwingen
                "-avoid_negative_ts", "make_zero",
                "-preset", $encoderPreset,
                "-x265-params", "nr=0:aq-mode=1:frame-threads=12:qcomp=0.7",
                "-max_muxing_queue_size", "1024"
            )

            # Wendet unterschiedliche CRF-Werte für Filme und Serien an, um die Qualität zu steuern.
            if ($sourceInfo.IsSeries -eq $true) {
                # Wenn die Framerate einer Serie über 25 FPS liegt, wird sie auf 25 FPS begrenzt.
                if($sourceInfo.FPS -gt 25){
                    Write-Host "🎞️ Framerate > 25 FPS erkannt. Begrenze auf 25 FPS." -ForegroundColor Magenta
                    $ffmpegArguments += @("-r", "25")
                }
                $ffmpegArguments += @("-crf", "$crfTargets")
                Write-Host "🎞️ Auf Serienauflösung-Anpassungen... $crfTargets" -ForegroundColor Cyan
                "`n==== Auf Serienauflösung-Anpassungen... $crfTargets ====" | Add-Content -LiteralPath $logDatei
            } else {
                $ffmpegArguments += @("-crf", "$crfTargetm")
                Write-Host "🎞️ Auf Filmauflösung-Anpassungen... $crfTargetm" -ForegroundColor Cyan
                "`n==== Auf Filmauflösung-Anpassungen... $crfTargetm ====" | Add-Content -LiteralPath $logDatei
            }

            # Wendet die entsprechenden Videofilter an (Deinterlacing, Skalierung, Rauschreduktion).
            if ($sourceInfo.Interlaced -eq $true) {
                if ($sourceInfo.Force720p -eq $true) {
                    Write-Host "↘️ Deinterlace + Scaling auf 720p" -ForegroundColor Cyan
                    "`n==== Deinterlace (Single-Rate) + Scaling auf 1280p Breite (720p Höhe max) ====" | Add-Content -LiteralPath $logDatei
                    $ffmpegArguments += @("-vf", "bwdif=0:-1:0,scale=1280:-2,hqdn3d=1.5:1.5:6:6")
                } else {
                    Write-Host "↘️ Deinterlace" -ForegroundColor Cyan
                    "`n==== Deinterlace (Single-Rate) ====" | Add-Content -LiteralPath $logDatei
                    $ffmpegArguments += @("-vf", "bwdif=0:-1:0,hqdn3d=1.5:1.5:6:6")
                }
            }
            if ($sourceInfo.Force720p -eq $true) {
                Write-Host "↘️ Scaling auf 1280p Breite (720p Höhe max)" -ForegroundColor Cyan
                "`n==== Scaling auf 1280p Breite (720p Höhe max) ====" | Add-Content -LiteralPath $logDatei
                $ffmpegArguments += @("-vf", "scale=1280:-2")
            }
        } else {
            # Kopiert den Videostream 1:1, wenn keine Neukodierung erforderlich ist.
            Write-Host "📼 Video wird kopiert (HEVC, 8 Bit und Größe OK)" -ForegroundColor Green
            "`n==== Video wird kopiert (HEVC, 8 Bit und Größe OK) ====" | Add-Content -LiteralPath $logDatei
            $ffmpegArguments += @("-c:v", "copy")
        }

        # Entscheidet über die Audiokodierung basierend auf der Lautstärkeabweichung und der Kanalanzahl.
        if ([math]::Abs($gain) -gt 0.2) {
            switch ($audioChannels) {
                { $_ -gt 2 } {
                    Write-Host "🔊 Audio: Surround → Transcode" -ForegroundColor Cyan;
                    "`n==== Audio: Surround → Transcode ====" | Add-Content -LiteralPath $logDatei
                    # libfdk_aac mit VBR 5 für hohe Surround-Qualität
                    $ffmpegArguments += @(
                        "-c:a", "libfdk_aac", # Bester AAC-Encoder
                        "-vbr", "5",          # Höchste VBR-Qualität für Surround
                        "-afterburner", "1"   # Zusätzliche Qualitätsoptimierung
                    )
                }
                2 {
                    Write-Host "🔉 Audio: Stereo → Transcode" -ForegroundColor Cyan;
                    "`n==== Audio: Stereo → Transcode ====" | Add-Content -LiteralPath $logDatei
                    # libfdk_aac mit VBR 4 für exzellente Stereo-Qualität (transparent)
                    $ffmpegArguments += @(
                        "-c:a", "libfdk_aac", # Bester AAC-Encoder
                        "-vbr", "4",          # Exzellente VBR-Qualität für Stereo
                        "-afterburner", "1"   # Zusätzliche Qualitätsoptimierung
                    )
                }
                default {
                    Write-Host "🔈 Audio: Mono → Transcode" -ForegroundColor Cyan;
                    "`n==== Audio: Mono → Transcode ====" | Add-Content -LiteralPath $logDatei
                    # libfdk_aac mit VBR 3 für gute und effiziente Mono-Qualität
                    $ffmpegArguments += @(
                        "-c:a", "libfdk_aac", # Bester AAC-Encoder
                        "-profile:a", "aac_he_v2", # High-Efficiency Profil für niedrige Bitraten
                        "-afterburner", "1"   # Zusätzliche Qualitätsoptimierung
                    )
                }
            }
        }
        else {
            $ffmpegArguments += @(
                "-c:a", "copy" # Copy audio stream if gain is negligible (±0.2 dB)
            )
        }
        # Fügt die finalen Argumente hinzu: Lautstärkeanpassung, Untertitel kopieren und Metadaten setzen.
        $ffmpegArguments += @(
            "-af", "volume=${gain}dB",
            "-c:s", "copy",
            "-metadata", "LUFS=$targetLoudness",
            "-metadata", "gained=$gain",
            "-metadata", "normalized=true",
            "`"$($outputFile)`""
        )

        Write-Host "🧾 FFmpeg-Argumente: $($ffmpegArguments -join ' ')" -ForegroundColor DarkCyan
        "`n==== FFmpeg-Argumente: $($ffmpegArguments -join ' ') ====" | Add-Content -LiteralPath $logDatei


        # Startet den FFmpeg-Prozess mit den zusammengestellten Argumenten.
        $process = Start-Process -FilePath $ffmpegPath -ArgumentList $ffmpegArguments -NoNewWindow -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -eq 0) {
            Write-Host "Lautstärkeanpassung abgeschlossen für: $($filePath)" -ForegroundColor Green
            "`n==== Lautstärkeanpassung abgeschlossen für: $($filePath) ====" | Add-Content -LiteralPath $logDatei
            return $true
        } else {
            Write-Host "FEHLER: FFmpeg-Prozess mit Exit-Code $($process.ExitCode) beendet" -ForegroundColor Red
            "`n==== FEHLER: FFmpeg-Prozess mit Exit-Code $($process.ExitCode) beendet ====" | Add-Content -LiteralPath $logDatei
            return $false
        }

    }
    catch {Write-Host "FEHLER: Fehler bei der Lautstärkeanpassung: $_" -ForegroundColor Red; "`n==== FEHLER bei der Lautstärkeanpassung: $_ ====" | Add-Content -LiteralPath $logDatei}
    return $false
}
function Test-OutputFile {# Überprüfe die Ausgabedatei, sobald der Prozess abgeschlossen ist
    param ( # Vergleicht die erstellte Ausgabedatei mit der Quelldatei, um die erfolgreiche Konvertierung zu validieren.

        [string]$outputFile,
        [string]$sourceFile,
        [string]$logDatei,
        [object]$sourceInfo,
        [string]$targetExtension
        )
    Write-Host "Überprüfe Ausgabedatei und ggf. Quelldatei" -ForegroundColor Cyan
    "`n==== Überprüfe Ausgabedatei und ggf. Quelldatei ====" | Add-Content -LiteralPath $logDatei

    # Eine kurze Pause, um sicherzustellen, dass das Betriebssystem den Dateihandle vollständig freigegeben hat.
    Start-Sleep -Seconds 2

    Test_Fileintregity -Outputfile $outputFile -ffmpegPath $ffmpegPath -destFolder $destFolder -file $sourceFile -logDatei $logDatei

    $outputInfo = Get-MediaInfo2 -filePath $outputFile
    # Prüft, ob die Metadaten der Ausgabedatei erfolgreich gelesen werden konnten.
    if ($outputInfo.Duration -eq 0 -or $outputInfo.AudioChannels -eq 0) {
        Write-Host "  FEHLER: Konnte Mediendaten für die Ausgabedatei nicht korrekt extrahieren." -ForegroundColor Red
        "`n==== FEHLER: Konnte Mediendaten für die Ausgabedatei nicht korrekt extrahieren. ====" | Add-Content -LiteralPath $logDatei
        return $false
    }else {
        Write-Host "  Die Ausgabedatei wurde erfolgreich erfasst." -ForegroundColor Green
        "`n==== Die Ausgabedatei wurde erfolgreich erfasst. ====" | Add-Content -LiteralPath $logDatei
        Write-Host "  Quelldatei-Dauer: $($sourceInfo.DurationFormatted1) | Audiokanäle: $($sourceInfo.AudioChannels)" -ForegroundColor Blue
        Write-Host "  Ausgabedatei-Dauer: $($outputInfo.DurationFormatted) | Audiokanäle: $($outputInfo.AudioChannels)" -ForegroundColor Blue

        # Ruft die Dateigrößen in Bytes für einen exakten numerischen Vergleich ab.
        $sizeSourceBytes = (Get-Item -LiteralPath $sourceFile).Length
        $sizeOutputBytes = (Get-Item -LiteralPath $outputFile).Length

        # Formatiert die Dateigrößen in ein lesbares MB-Format nur für die Konsolenausgabe.
        $fileSizeSourceFormatted = "{0:N2} MB" -f ($sizeSourceBytes / 1MB)
        $fileSizeOutputFormatted = "{0:N2} MB" -f ($sizeOutputBytes / 1MB)

        Write-Host "  Quelldatei-Größe: $($fileSizeSourceFormatted)" -ForegroundColor DarkCyan
        Write-Host "  Ausgabedatei-Größe: $($fileSizeOutputFormatted)" -ForegroundColor DarkCyan

        # Prüft, ob die Ausgabedatei mehr als 3 MB größer ist als die Quelldatei.
        if ($sizeOutputBytes -gt ($sizeSourceBytes + 3MB)) {
            $diffMB = [math]::Round(($sizeOutputBytes - $sizeSourceBytes) / 1MB, 2)
            Write-Host "  WARNUNG: Die Ausgabedatei ist $diffMB MB größer als die Quelldatei!" -ForegroundColor Red
            "`n==== WARNUNG: Die Ausgabedatei ist $diffMB MB größer als die Quelldatei! ====" | Add-Content -LiteralPath $logDatei
            return $false
        }
        else {
            $diffMB = [math]::Round(($sizeSourceBytes - $sizeOutputBytes) / 1MB, 2)
            Write-Host "  Die Ausgabedatei ist $diffMB MB kleiner als die Quelldatei." -ForegroundColor Green
            "`n==== Die Ausgabedatei ist $diffMB MB kleiner als die Quelldatei. ====" | Add-Content -LiteralPath $logDatei
            Write-Host "  Die Ausgabedatei hat die Größe der Quelldatei erfolgreich reduziert." -ForegroundColor Green
            "`n==== Die Ausgabedatei hat die Größe der Quelldatei erfolgreich reduziert. ====" | Add-Content -LiteralPath $logDatei
            Write-Host "  Das entspricht $([math]::Round(($sizeOutputBytes / $sizeSourceBytes) * 100, 2))% der ursprünglichen Größe." -ForegroundColor Green
            "`n==== Das entspricht $([math]::Round(($sizeOutputBytes / $sizeSourceBytes) * 100, 2))% der ursprünglichen Größe. ====" | Add-Content -LiteralPath $logDatei
        }
    }
# Überprüfe die Laufzeit beider Dateien (mit einer kleinen Toleranz von 1 Sekunde)
    $durationDiff = [Math]::Abs($sourceInfo.Duration1 - $outputInfo.Duration)
    if ($durationDiff -gt 1) {
        Write-Host "  WARNUNG: Die Laufzeiten unterscheiden sich um $durationDiff Sekunden!" -ForegroundColor Red
        "`n==== WARNUNG: Die Laufzeiten unterscheiden sich um $durationDiff Sekunden! ====" | Add-Content -LiteralPath $logDatei
        return $false
    }else {
        Write-Host "  Die Laufzeiten stimmen überein." -ForegroundColor Green
        "`n==== Die Laufzeiten stimmen überein. ====" | Add-Content -LiteralPath $logDatei
    }
# Überprüfe die Anzahl der Audiokanäle beider Dateien
    if ($sourceInfo.AudioChannels -ne $outputInfo.AudioChannels) {
        Write-Host "  WARNUNG: Die Anzahl der Audiokanäle hat sich geändert! (Quelle: $($sourceInfo.AudioChannels), Ausgabe: $($outputInfo.AudioChannels))" -ForegroundColor Red
        "`n==== WARNUNG: Die Anzahl der Audiokanäle hat sich geändert! (Quelle: $($sourceInfo.AudioChannels), Ausgabe: $($outputInfo.AudioChannels)) ====" | Add-Content -LiteralPath $logDatei
        return $false
    }else {
        Write-Host "  Die Anzahl der Audiokanäle ist gleich geblieben." -ForegroundColor Green
        "`n==== Die Anzahl der Audiokanäle ist gleich geblieben. ====" | Add-Content -LiteralPath $logDatei
        return $true
    }
}
function Test_Fileintregity {
    # Überprüft die Integrität einer Mediendatei, indem FFmpeg versucht, sie zu dekodieren. Fehler werden protokolliert.
    param (
        [Parameter(Mandatory = $true)]
        [string]$outputFile,

        [Parameter(Mandatory = $true)]
        [string]$ffmpegPath,

        [Parameter(Mandatory = $true)]
        [string]$destFolder,

        [Parameter(Mandatory = $true)]
        [string]$logDatei,
        [string]$file
    )


    Write-Host "Überprüfe Ausgabedatei: $outputFile"
    "`n==== Überprüfe Ausgabedatei: $outputFile ====" | Add-Content -LiteralPath $logDatei


    # Erstellt eine temporäre Datei, um die Fehlerausgabe von FFmpeg zu speichern.
    $tempFehlerDatei = [System.IO.Path]::GetTempFileName()

    # Bereitet die FFmpeg-Argumente für die Integritätsprüfung der Ausgabedatei vor.
    $argumentso = @()
    $argumentso = @(
        "-v", "error",
        "-hwaccel", "d3d11va",
        "-i", "`"$outputFile`"",
        "-f", "null",
        "-"
    ) -join ' '

    $argumentsi = @()
    $argumentsi = @(
        "-v", "error",
        "-hwaccel", "d3d11va",
        "-i", "`"$file`"",
        "-f", "null",
        "-"
    ) -join ' '

    # Konfiguriert den FFmpeg-Prozess für die Prüfung der Ausgabedatei.
    $processInfoo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfoo.FileName = $ffmpegPath
    $processInfoo.Arguments = $argumentso
    $processInfoo.RedirectStandardError = $true
    $processInfoo.RedirectStandardOutput = $true
    $processInfoo.UseShellExecute = $false
    $processInfoo.CreateNoWindow = $true

    # Startet den FFmpeg-Prozess.
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfoo
    $process.Start() | Out-Null

    # Liest die Fehlerausgabe und wartet auf das Prozessende.
    [string]$ffmpegFehlero = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitCodeo = $process.ExitCode

    # Speichert die Fehlerausgabe in der temporären Datei.
    $ffmpegFehlero | Out-File -FilePath $tempFehlerDatei -Encoding UTF8

    # Wertet das Ergebnis aus. Eine saubere Datei hat Exit-Code 0 und keine Fehlerausgabe.
    if (($exitCodeo -eq 0 -and [string]::IsNullOrWhiteSpace($ffmpegFehlero)) -or
        ($ffmpegFehlero -match "Application provided invalid, non monotonically increasing dts to muxer in stream 0")) {
        Write-Host "OK: $outputFile" -ForegroundColor Green
        "`n==== OK: $outputFile ====" | Add-Content -LiteralPath $logDatei
    } else {
        "`n==== Überprüfung gestartet am $($date) ====" | Add-Content -LiteralPath $logDatei
        Write-Host "FEHLER in Datei: $outputFile" -ForegroundColor Red
        Add-Content -LiteralPath $logDatei -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $outputFile - FEHLER:"
        Add-Content -LiteralPath $logDatei -Value $ffmpegFehlero
        Add-Content -LiteralPath $logDatei -Value "$file wird auf fehler in der Quelle geprüft."
        Add-Content -LiteralPath $logDatei -Value "----------------------------------------"

        # Wenn die Ausgabedatei fehlerhaft ist, wird die Quelldatei ebenfalls geprüft.
        $processInfoi = New-Object System.Diagnostics.ProcessStartInfo
        $processInfoi.FileName = $ffmpegPath
        $processInfoi.Arguments = $argumentsi
        $processInfoi.RedirectStandardError = $true
        $processInfoi.RedirectStandardOutput = $true
        $processInfoi.UseShellExecute = $false
        $processInfoi.CreateNoWindow = $true

        # Startet die Prüfung für die Quelldatei.
        Write-Host "Überprüfe Quelldatei: $file"
        "`n==== Überprüfe Quelldatei: $file ====" | Add-Content -LiteralPath $logDatei
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfoi
        $process.Start() | Out-Null

        # Liest die Fehlerausgabe der Quelldatei.
        [string]$ffmpegFehleri = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCodei = $process.ExitCode

        $ffmpegFehleri | Out-File -FilePath $tempFehlerDatei -Encoding UTF8

        # Wertet das Ergebnis der Quelldateiprüfung aus.
        if (($exitCodei -eq 0 -and [string]::IsNullOrWhiteSpace($ffmpegFehleri)) -or
        ($ffmpegFehleri -match "Application provided invalid, non monotonically increasing dts to muxer in stream 0")) {
            Write-Host "OK: $file" -ForegroundColor Green
            "`n==== OK: $file ====" | Add-Content -LiteralPath $logDatei

            Try {
                Remove-Item $outputFile -Force -ErrorAction Stop
                Remove-Item $logDatei -Force -ErrorAction Stop
            } catch {
                Write-Host "FEHLER beim Löschen von Dateien: $_" -ForegroundColor Red
                Write-Host "  Datei: $($_.Exception.ItemName)" -ForegroundColor Red
                Write-Host "  Fehlercode: $($_.Exception.HResult)" -ForegroundColor Red
                Write-Host "  Fehlertyp: $($_.Exception.GetType().FullName)" -ForegroundColor Red
            }
        } else {
            # Wenn beide Dateien Fehler aufweisen, wird eine Warnung ausgegeben, aber die neue Datei wird behalten.
            Write-Host "FEHLER in Datei: $file" -ForegroundColor Red
            Write-Host "$file und $outputFile haben beide fehler." -ForegroundColor Red
            Write-Host "Ersetze Quelldatei mit Ausgabedatei." -ForegroundColor green
            Add-Content -LiteralPath $logDatei -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $file - FEHLER:"
            Add-Content -LiteralPath $logDatei -Value $ffmpegFehleri
            Add-Content -LiteralPath $logDatei -Value "$file und $outputFile haben beide fehler."
            Add-Content -LiteralPath $logDatei -Value "Ersetze Quelldatei mit Ausgabedatei."
            Add-Content -LiteralPath $logDatei -Value "----------------------------------------"
        }
    }
    # Löscht die temporäre Datei nach Abschluss der Prüfung.
    Remove-Item $tempFehlerDatei -Force

    "`n==== Überprüfung beendet am $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====" | Add-Content -LiteralPath $logDatei
    Write-Host "Überprüfung abgeschlossen. Ergebnis in: $logDatei"
}
function Remove-Files {
    param ( # Benennt Dateien nach erfolgreicher Verarbeitung um und löscht die Quelldatei oder verwirft die fehlerhafte Ausgabedatei.
        [string]$outputFile,
        [string]$sourceFile,
        [string]$targetExtension,
        [bool]$isOutputOk
    )
    try {
        # Wenn die Ausgabedatei die Validierung bestanden hat, wird die Quelldatei ersetzt.
        if ($isOutputOk) {
            try {
                # 1. Finalen Zieldateinamen bestimmen. -LiteralPath ist wichtig für Sonderzeichen.
                $finalFile = [System.IO.Path]::Combine((Split-Path -LiteralPath $sourceFile), "$([System.IO.Path]::GetFileNameWithoutExtension($sourceFile))$targetExtension")

                # 2. Quelldatei explizit löschen. -ErrorAction Stop stellt sicher, dass das Skript bei einem Fehler hier abbricht.
                Remove-Item -LiteralPath $sourceFile -Force -ErrorAction Stop

                # 3. Neue Datei an den finalen Ort verschieben/umbenennen. Move-Item ist hierfür robuster als Rename-Item.
                Move-Item -LiteralPath $outputFile -Destination $finalFile -Force -ErrorAction Stop

                Write-Host "  Erfolg: Quelldatei gelöscht und normalisierte Datei umbenannt zu $([System.IO.Path]::GetFileName($sourceFile))" -ForegroundColor Green
                "`n==== Erfolg: Quelldatei gelöscht und normalisierte Datei umbenannt zu $([System.IO.Path]::GetFileName($sourceFile)) ====" | Add-Content -LiteralPath $logDatei
            }
            catch {
                Write-Host "FEHLER beim Löschen von Dateien: $_" -ForegroundColor Red
                "`n==== FEHLER: Konnte Mediendaten für die Quelldatei nicht korrekt extrahieren. ====" | Add-Content -LiteralPath $logDatei
                Write-Host "  Datei: $($_.Exception.ItemName)" -ForegroundColor Red
                "`n==== Datei: $($_.Exception.ItemName) ====" | Add-Content -LiteralPath $logDatei
                Write-Host "  Fehlercode: $($_.Exception.HResult)" -ForegroundColor Red
                "`n==== Fehlercode: $($_.Exception.HResult) ====" | Add-Content -LiteralPath $logDatei
                Write-Host "  Fehlertyp: $($_.Exception.GetType().FullName)" -ForegroundColor Red
                "`n==== Fehlertyp: $($_.Exception.GetType().FullName) ====" | Add-Content -LiteralPath $logDatei

            }
        } else {
            # Wenn die Ausgabedatei fehlerhaft ist, wird sie gelöscht und die Quelldatei bleibt erhalten.
            Write-Host "  FEHLER: Test-OutputFile ist fehlgeschlagen. Test-OutputFile wird gelöscht." -ForegroundColor Red
            "`n==== FEHLER: Test-OutputFile ist fehlgeschlagen. Test-OutputFile wird gelöscht. ====" | Add-Content -LiteralPath $logDatei
            try {
                # Prüfen, ob die Quelldatei eine AVI ist. In diesem Fall soll die fehlerhafte Ausgabedatei nicht gelöscht werden.
                $isAviFile = [System.IO.Path]::GetExtension($sourceFile).ToLowerInvariant() -eq '.avi'
                if (-not $isAviFile) {
                    Remove-Item -Path $outputFile -Force
                } else {
                    Write-Host "  INFO: Die Quelldatei ist eine AVI. Die fehlerhafte Ausgabedatei '$outputFile' wird zur Analyse beibehalten." -ForegroundColor Cyan
                    "`n==== INFO: Die Quelldatei ist eine AVI. Die fehlerhafte Ausgabedatei '$outputFile' wird zur Analyse beibehalten. ====" | Add-Content -LiteralPath $logDatei
                }
            }
            catch {
                Write-Host "FEHLER beim Löschen von Dateien: $_" -ForegroundColor Red
                "`n==== FEHLER beim Löschen von Dateien: $_ ====" | Add-Content -LiteralPath $logDatei
                Write-Host "  Datei: $($_.Exception.ItemName)" -ForegroundColor Red
                Write-Host "  Fehlercode: $($_.Exception.HResult)" -ForegroundColor Red
                Write-Host "  Fehlertyp: $($_.Exception.GetType().FullName)" -ForegroundColor Red
                "`n==== FEHLERDETAILS: Datei: $($_.Exception.ItemName), Code: $($_.Exception.HResult), Typ: $($_.Exception.GetType().FullName) ====" | Add-Content -LiteralPath $logDatei
            }
        }
    }
    catch {
        Write-Host "  FEHLER bei Umbenennung/Löschen: $_" -ForegroundColor Red
        "`n==== FEHLER bei Umbenennung/Löschen: $_ ====" | Add-Content -LiteralPath $logDatei
    }
}
#endregion

#region Hauptskript
# Zeigt einen Dialog zur Auswahl des zu verarbeitenden Ordners an.
Add-Type -AssemblyName System.Windows.Forms
$PickFolder = New-Object -TypeName System.Windows.Forms.OpenFileDialog
$PickFolder.FileName = 'Mediafolder'
$PickFolder.Filter = 'Folder Selection|*.*'
$PickFolder.AddExtension = $false
$PickFolder.CheckFileExists = $false
$PickFolder.Multiselect = $false
$PickFolder.CheckPathExists = $true
$PickFolder.ShowReadOnly = $false
$PickFolder.ReadOnlyChecked = $true
$PickFolder.ValidateNames = $false

$result = $PickFolder.ShowDialog()

if ($result -eq [Windows.Forms.DialogResult]::OK) {
    $destFolder = Split-Path -Path $PickFolder.FileName
    Write-Host -Object "Ausgewählter Ordner: $destFolder" -ForegroundColor Green

    # Sucht rekursiv nach allen relevanten Videodateien im ausgewählten Ordner. Die .NET-Methode ist schneller als Get-ChildItem.
    $startTime = Get-Date
    $mkvFiles = [System.IO.Directory]::EnumerateFiles($destFolder, '*.*', [System.IO.SearchOption]::AllDirectories) | Where-Object { ($extensions -contains [System.IO.Path]::GetExtension($_).ToLowerInvariant()) -and ((Get-Item (Split-Path -Path $_ -Parent)).Name -ne "Fertig") } | Sort-Object
    $mkvFileCount = ($mkvFiles | Measure-Object).Count
    $endTime = Get-Date
    $duration = $endTime - $startTime
    Write-Host "Dateiscan-Zeit: $($duration.TotalSeconds) Sekunden" -ForegroundColor Yellow

    # Erste Schleife: Prüft alle gefundenen Dateien, ob sie bereits normalisiert sind.
    foreach ($file in $mkvFiles) {
        Write-Host "$mkvFileCount Dateien zur Tag-Prüfung verbleibend." -ForegroundColor Green
        $mkvFileCount --
        Write-Host "Verarbeite Datei: $file" -ForegroundColor Cyan

        # Überspringt Dateien, die bereits das "NORMALIZED"-Tag enthalten.
        if (Test-IsNormalized -file $file) {
            Write-Host "Datei ist bereits normalisiert. Überspringe: $($file)" -ForegroundColor DarkGray
        }
    }
    # Zweite Schleife: Verarbeitet nur die Dateien, die in der ersten Schleife als "nicht normalisiert" identifiziert wurden.
    $mkvFileCount = ($script:filesnotnorm | Measure-Object).Count
    foreach ($file in $script:filesnotnorm) {
        $logBaseName = [System.IO.Path]::GetFileName($file)
        $logDatei = Join-Path -Path $destFolder -ChildPath "$($logBaseName).log"
        Write-Host "`nStarte Verarbeitung der *nicht normalisierten* Datei: $file" -ForegroundColor Cyan
        Write-Host "$mkvFileCount Dateien zur Verarbeitung verbleibend." -ForegroundColor Green
        $mkvFileCount --

        # --- Start der Verarbeitung für nicht normalisierte Dateien ---
        try {
            # Extrahiert die Metadaten der Quelldatei.
            $sourceInfo = Get-MediaInfo -filePath $file -logDatei $logDatei
            if (!$sourceInfo) {
                throw "Konnte Mediendaten nicht extrahieren."
            }

            # Führt die Lautheitsanalyse durch.
            $ffmpegOutput = Get-LoudnessInfo -filePath $file
            if (!$ffmpegOutput) {
                throw "Konnte Lautstärkeinformationen nicht extrahieren."
            }

            # Extrahiert den integrierten Lautheitswert (I) aus der Analyse.
            if ($ffmpegOutput -match "I:\s*([-\d\.]+)\s*LUFS") {
                $integratedLoudness = [double]$matches[1]
                $gain = $targetLoudness - $integratedLoudness # Berechnet die notwendige Verstärkung (Gain).

                # Definiert den Pfad für die temporäre Ausgabedatei.
                $outputFile = [System.IO.Path]::Combine((Get-Item -LiteralPath $file).DirectoryName, "$([System.IO.Path]::GetFileNameWithoutExtension($file))_normalized$($targetExtension)")

                # Führt die Normalisierung nur durch, wenn die Abweichung einen Schwellenwert (hier 0.2 dB) überschreitet.
                if ([math]::Abs($gain) -gt 0.2) {
                    Write-Host "Passe Lautstärke an um $gain dB" -ForegroundColor Yellow;
                    "`n==== Passe Lautstärke an um $gain dB ====" | Add-Content -LiteralPath $logDatei
                    Set-VolumeGain -filePath $file -gain $gain -outputFile $outputFile -audioChannels $sourceInfo.AudioChannels -videoCodec $sourceInfo.VideoCodec -interlaced $sourceInfo.Interlaced -bitDepth $sourceInfo.BitDepth -sourceInfo $sourceInfo -logDatei $logDatei
                }
                else {
                    # Wenn keine Lautstärkeanpassung nötig ist, wird nur das Metadaten-Tag gesetzt.
                    Write-Host "Lautstärke bereits im Zielbereich. Setze nur Metadaten." -ForegroundColor Green;
                    "`n==== Lautstärke bereits im Zielbereich. Setze nur Metadaten. ====" | Add-Content -LiteralPath $logDatei

                    $outputFile = [System.IO.Path]::Combine((Get-Item -LiteralPath $file).DirectoryName, "$([System.IO.Path]::GetFileNameWithoutExtension($file))_normalized$($targetExtension)")
                    $ffmpegArgumentscopy = @(
                        "-hide_banner", "-loglevel", "error", "-stats", "-y", "-i", "`"$($file)`"",
                        "-c:v", "copy", "-c:a", "copy", "-c:s", "copy",
                        "-metadata", "LUFS=$targetLoudness", "-metadata", "gained=0", "-metadata", "normalized=true",
                        "`"$($outputFile)`""
                    )
                    Write-Host "FFmpeg-Argumente: $($ffmpegArgumentscopy -join ' ')" -ForegroundColor DarkCyan
                    "`n==== FFmpeg-Argumente: $($ffmpegArgumentscopy -join ' ') ====" | Add-Content -LiteralPath $logDatei
                    Start-Process -FilePath $ffmpegPath -ArgumentList $ffmpegArgumentscopy -NoNewWindow -Wait -PassThru -ErrorAction Stop
                }

                # Validiert die erstellte Ausgabedatei und räumt auf.
                $isOutputOk = Test-OutputFile -outputFile $outputFile -sourceFile $file -sourceInfo $sourceInfo -targetExtension $targetExtension -logDatei $logDatei
                Remove-Files -outputFile $outputFile -sourceFile $file -targetExtension $targetExtension -isOutputOk $isOutputOk

            }
            else {
                Write-Warning "Keine LUFS-Informationen gefunden. Überspringe Lautstärkeanpassung."
                "`n==== WARNUNG: Keine LUFS-Informationen gefunden. Überspringe Lautstärkeanpassung. ====" | Add-Content -LiteralPath $logDatei
            }
        }
        catch {
            Write-Error "Ein Fehler ist bei der Verarbeitung von '$file' aufgetreten: $_"
            "`n==== FEHLER bei der Verarbeitung von '$file': $_ ====" | Add-Content -LiteralPath $logDatei
        }
        finally {
            Write-Host "Verarbeitung für '$file' abgeschlossen." -ForegroundColor Green;
            "`n==== Verarbeitung für '$file' abgeschlossen. ====" | Add-Content -LiteralPath $logDatei
            Write-Host "--------------------------------------------------" -ForegroundColor DarkGray;
        }
    }
    # Nachbereitung: Sucht und löscht alle temporären "_normalized"- und ".log"-Dateien.
    Write-Host "Starte Nachbereitung: Suche und lösche temporäre Dateien..." -ForegroundColor Cyan
    $normalizedFiles = [System.IO.Directory]::EnumerateFiles($destFolder, "*_normalized*", [System.IO.SearchOption]::AllDirectories)
    foreach ($normalizedFile in $normalizedFiles) {
        try {
            Remove-Item -Path $normalizedFile -Force
            Write-Host "  Gelöscht (temporär): $normalizedFile" -ForegroundColor Green
        }
        catch {
            Write-Host "  FEHLER: Konnte temporäre Datei nicht löschen $normalizedFile : $_" -ForegroundColor Red
        }
    }

    $logFiles = [System.IO.Directory]::EnumerateFiles($destFolder, "*.log", [System.IO.SearchOption]::AllDirectories)
    foreach ($logFile in $logFiles) {
        try {
            Remove-Item -Path $logFile -Force
            Write-Host "  Gelöscht (Log): $logFile" -ForegroundColor Green
        }
        catch {
            Write-Host "  FEHLER: Konnte Log-Datei nicht löschen $logFile : $_" -ForegroundColor Red
        }
    }
    Write-Host "Alle Dateien verarbeitet." -ForegroundColor Green
}
else {
    Write-Host "Ordnerauswahl abgebrochen." -ForegroundColor Yellow
}
#endregion
