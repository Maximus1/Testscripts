import os
import ctypes
import sys
import requests
import threading
import time
from datetime import date
from pathlib import Path
from PIL import Image, ImageDraw
from pystray import Icon as icon, Menu as menu, MenuItem as item

def resource_path(relative_path):
    """ Ermittelt den absoluten Pfad zu einer Ressource, funktioniert für den Entwicklungsmodus und für PyInstaller. """
    try:
        # PyInstaller erstellt einen temporären Ordner und speichert den Pfad in _MEIPASS.
        base_path = sys._MEIPASS
    except Exception:
        # _MEIPASS ist nicht gesetzt, wir sind im normalen Entwicklungsmodus.
        base_path = os.path.abspath(".")

    return os.path.join(base_path, relative_path)


class WallpaperApp:
    def __init__(self):
        self.auto_update_enabled = True
        self.auto_update_thread = None
        self.stop_event = threading.Event()
        self.icon = self._create_tray_icon()

    def _create_tray_icon(self):
        # Versucht, das Icon aus einer Datei zu laden, andernfalls wird ein Standard-Icon erzeugt.
        try:
            image = Image.open(resource_path("app.ico"))
        except FileNotFoundError:
            print("Icon 'app.ico' nicht gefunden. Erzeuge Standard-Icon.")
            image = Image.new('RGB', (64, 64), 'black')
            ImageDraw.Draw(image).rectangle((16, 16, 48, 48), fill='white')

        # Definiert das Menü für das Symbol
        tray_menu = menu(
            item('Jetzt aktualisieren', self.update_wallpaper),
            item(
                'Automatisch alle 24h',
                self.toggle_auto_update,
                checked=lambda item: self.auto_update_enabled
            ),
            menu.SEPARATOR,
            item('Beenden', self.exit_app)
        )
        return icon('BingWallpaper', image, "Bing Wallpaper", tray_menu)

    def get_bing_wallpaper(self):
        try:
            # Bing API für das Tagesbild
            url = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=de-DE"
            response = requests.get(url, timeout=10)
            data = response.json()
            image_url = "https://www.bing.com" + data["images"][0]["url"]
            
            # Speicherpfad vorbereiten
            folder = Path.home() / "Pictures" / "BingWallpaper"
            folder.mkdir(parents=True, exist_ok=True)
            filename = folder / f"bing_{date.today()}.jpg"
            
            # Nur speichern, wenn noch nicht vorhanden
            if not filename.exists():
                img_data = requests.get(image_url, timeout=10).content
                with open(filename, "wb") as f:
                    f.write(img_data)
                print(f"Hintergrundbild gespeichert: {filename}")
            else:
                print("Heutiges Bild bereits vorhanden.")
            
            return str(filename)
        except Exception as e:
            print(f"Fehler beim Herunterladen des Bildes: {e}")
            return None

    def set_wallpaper(self, image_path):
        if image_path and os.path.exists(image_path):
            # Desktop-Hintergrund mit Windows-API ändern
            ctypes.windll.user32.SystemParametersInfoW(20, 0, image_path, 3)
            print(f"Hintergrundbild gesetzt: {image_path}")

    def update_wallpaper(self, icon=None, item=None):
        print("Starte Update des Hintergrundbildes...")
        image_path = self.get_bing_wallpaper()
        self.set_wallpaper(image_path)

    def auto_update_loop(self):
        """Diese Schleife läuft im Hintergrund und führt alle 24 Stunden ein Update aus."""
        while not self.stop_event.is_set():
            self.update_wallpaper()
            # Warte 24 Stunden (86400 Sekunden), aber prüfe alle 60 Sekunden, ob das Programm beendet werden soll.
            self.stop_event.wait(timeout=24 * 60 * 60)

    def toggle_auto_update(self, icon, item):
        self.auto_update_enabled = not self.auto_update_enabled
        if self.auto_update_enabled:
            self.start_auto_update_thread()
            print("Automatisches Update aktiviert.")
        else:
            self.stop_auto_update_thread()
            print("Automatisches Update deaktiviert.")

    def start_auto_update_thread(self):
        if self.auto_update_thread is None or not self.auto_update_thread.is_alive():
            self.stop_event.clear()
            self.auto_update_thread = threading.Thread(target=self.auto_update_loop, daemon=True)
            self.auto_update_thread.start()

    def stop_auto_update_thread(self):
        self.stop_event.set()

    def exit_app(self, icon, item):
        self.stop_auto_update_thread()
        self.icon.stop()

    def run(self):
        self.start_auto_update_thread()
        self.icon.run()

if __name__ == "__main__":
    app = WallpaperApp()
    app.run()
