# film-genre-videofile.ps1
# PowerShell-Skript: Wählt ein Video aus, liest den Dateinamen und sucht Genres via OMDb API

# Deinen OMDb API-Key hier eintragen:
$OMDbApiKey = "7827077b"

if ($OMDbApiKey -eq "DEIN_API_KEY_HIER") {
    Write-Error "Bitte trage deinen OMDb API-Key in der Variable `$OMDbApiKey` ein."
    exit
}

# Video-Datei-Auswahldialog
Add-Type -AssemblyName System.Windows.Forms
$openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
$openFileDialog.Filter = "Video-Dateien (*.mp4;*.mkv;*.avi)|*.mp4;*.mkv;*.avi|Alle Dateien (*.*)|*.*"
$openFileDialog.Title = "Wähle eine Videodatei aus"

if ($openFileDialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Output "Keine Datei ausgewählt."
    exit
}

$videoPath = $openFileDialog.FileName
$videoName = [System.IO.Path]::GetFileNameWithoutExtension($videoPath)

# Bereinige Dateinamen: Entferne Auflösungen, Punkte, Unterstriche, Bindestriche
if ([string]::IsNullOrEmpty($videoName)) {
    Write-Error "Dateiname ist leer!"
    exit
}

# Escape Bindestrich richtig oder setze in Character Class
$cleanName = $videoName -replace '\d{3,4}p', ''            # 720p, 1080p etc. entfernen
$cleanName = $cleanName -replace '(?i)S\d{1,2}E\d{1,2}', ''  # Staffel/Episode entfernen
$cleanName = $cleanName -replace '[\._\-]', ' '            # Punkte, Unterstriche, Bindestriche -> Leerzeichen
$cleanName = $cleanName -replace '\s{2,}', ' '             # Mehrfache Leerzeichen reduzieren
$cleanName = $cleanName -replace '\b(HD|SD|DL|WEB|BluRay|BRRip|HDRip|x264|x265|HEVC|H\.264|H\.265|AAC|DTS|DD5\.1|REPACK|PROPER|german)\b', ''  # Häufige Tags entfernen
$cleanName = $cleanName -replace '\s+[a-zA-Z0-9]+$', ''
$cleanName = $cleanName.Trim()

Write-Output "Verwendeter Suchname: $cleanName"

# Prüft, ob der Original-Dateiname ein Serienmuster enthält.
if ($videoName -match '(?i)S\d{1,2}E\d{1,2}') {
    $mediaType = "series"
    Write-Host "Serienmuster erkannt. Suche nach Typ 'series'." -ForegroundColor Cyan
    $apiUrl = "https://www.thetvdb.com/search?query=$($cleanName -replace ' ', '+')"
}
else {
    $mediaType = "movie"
    Write-Host "Kein Serienmuster erkannt. Suche nach Typ 'movie'." -ForegroundColor Cyan
    # OMDb API-Abfrage für Movies
    $apiUrl = "http://www.omdbapi.com/?apikey=$OMDbApiKey&t=$($cleanName -replace ' ', '+')"

}



try {
    $response = Invoke-RestMethod -Uri $apiUrl
} catch {
    Write-Warning "Fehler bei der Abfrage für '$cleanName'"
    exit
}

if ($response.Response -eq "False") {
    Write-Output "Kein Ergebnis gefunden: $($response.Error)"
    exit
}

Write-Output "`nGefundene Informationen:"
Write-Output "  Titel: $($response.Title)"
Write-Output "  Genre: $($response.Genre)"
Write-Output "  Typ: $($response.Type)"
Write-Output "  Jahr: $($response.Year)"
