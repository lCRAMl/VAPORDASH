# Vapor Dashboard

[English](README.md) | **Deutsch**

Telemetrie-Widget für **EdgeTX** auf der **RadioMaster TX16S MK3** (800×480), gebaut für die
**GEPRC Vapor-D5 HD O4 Pro** mit Betaflight und ExpressLRS. Es zeigt auf einem Bildschirm
alles, was die Drohne funkt. Akku, Flugzeit und Status sind groß und in Ampelfarben, damit
es auch ein Kind auf einen Blick versteht.

Die Beschriftungen auf dem Bildschirm sind englisch. Diese Seite erklärt, was sie bedeuten.

![Vapor Dashboard im Flug](docs/img/dashboard_flight.png)

## Funktionen

- **Drohnen-Akku** als großer Balken mit Prozent, Spannung (gesamt und pro Zelle), Strom und
  verbrauchten mAh. Unter 25 % blinkt „LAND!“ (landen).
- **Status** im Klartext: DISARMED (gesichert), ARMED (scharf), BLOCKED (Start gesperrt,
  mit Grund, z. B. „Throttle not low“ = Gas nicht ganz unten), FAILSAFE oder NO SIGNAL
  (keine Verbindung). Darunter steht der Flugmodus.
- **Flugzeit**, die nur läuft, solange die Drohne scharf ist. Ein neuer Akku setzt sie zurück.
- **Motoren** als Drohne von oben, mit der Drehzahl jedes Motors und der ESC-Temperatur.
- **Funk:** Verbindungsqualität, Signal, SNR, Paketrate, Sendeleistung und Rückkanal.
- **Lage & Höhe:** künstlicher Horizont, Höhe, Steigen/Sinken, Neigung, Rollen und Kurs.
- **GPS:** Satelliten, Tempo, Entfernung zum Startpunkt und Koordinaten.
- **QR-Code der letzten Position:** GPS-Kachel antippen, mit dem Handy scannen, zur Drohne
  navigieren. Die Position wird auf der SD-Karte gesichert und übersteht einen Neustart.
- **Versionen** von EdgeTX, ELRS (Funke und Drohne) und Betaflight in der Fußzeile.

## Screenshots

| | |
|:---:|:---:|
| ![Gesichert](docs/img/dashboard_disarmed.png) | ![Gesperrt](docs/img/dashboard_blocked.png) |
| Gesichert und startklar | Start gesperrt, mit Grund |
| ![Akku fast leer](docs/img/dashboard_battery_low.png) | ![Signal weg](docs/img/dashboard_link_lost.png) |
| Akku fast leer, Motor 3 steht, Motor 2 warm | Signal im Flug verloren, letzte Position in Gelb |

![QR-Code mit der letzten Position](docs/img/qr_last_position.png)

*Die Bilder stammen aus der PC-Vorschau mit simulierter Telemetrie, in Originalgröße und
mit den EdgeTX-Schriften.*

## Voraussetzungen

- **Funke:** RadioMaster TX16S MK3 (800×480) mit **EdgeTX 2.12** oder neuer
  (getestet mit 2.12.4).
- **Funkstrecke:** ExpressLRS mit CRSF-Telemetrie (z. B. das interne Modul der TX16S MK3).
- **Drohne:** Flight Controller mit **Betaflight** und eingeschalteter Telemetrie
  (entwickelt mit Betaflight 2026.6.2).
- **Optional:**
  - **GPS-Modul:** für das GPS-Feld und den QR-Code.
  - **Motordrehzahlen:** brauchen bidirektionales DShot. Bei BLHeli_S-ESCs geht das nur
    mit Bluejay-Firmware.

## Installation auf der RadioMaster TX16S MK3

### 1. Herunterladen

Auf GitHub **Code → Download ZIP** wählen und entpacken, oder das Repository klonen.
Gebraucht wird nur der Ordner `WIDGETS/VAPORDASH`.

### 2. Auf die SD-Karte kopieren

1. Funke einschalten und per USB-C mit dem PC verbinden.
2. Auf der Funke **USB Storage (SD)** wählen. Die SD-Karte erscheint am PC als Laufwerk.
3. Den Ordner `VAPORDASH` in den Ordner `WIDGETS` der SD-Karte kopieren. Danach gibt es
   `/WIDGETS/VAPORDASH/main.lua`.
4. Das Laufwerk am PC auswerfen und das USB-Kabel abziehen.

### 3. Telemetrie-Sensoren suchen

1. Das Modell der Drohne auswählen, die Drohne mit Akku einschalten und warten, bis sie
   verbunden ist.
2. **MDL** drücken, zur Seite **Telemetrie** gehen und **Start Sensorsuche** (*Discover new*)
   wählen.
3. Warten, bis Sensoren wie `RxBt`, `FM`, `RQly` und `Ptch` erscheinen, dann
   **Stop Sensorsuche**.

Die GPS-Sensoren (`GPS`, `Sats`) tauchen erst auf, wenn das GPS der Drohne Daten liefert.
Gegebenenfalls die Suche später im Freien noch einmal starten.

### 4. Bildschirm einrichten

1. **TELE** kurz drücken. Es öffnet sich **UI Setup** mit den Bildschirmen (*Seite 1, 2, …*).
   Einen Bildschirm wählen oder mit **+** einen neuen anlegen.
2. Bei **Layout** die Einstellung **App mode** wählen (ein Widget über den ganzen Bildschirm).
3. **Widget einrichten** (*Setup widgets*) wählen, auf die Fläche tippen und
   **Vapor Dashboard** auswählen. Danach öffnen sich die Widget-Einstellungen (siehe unten).
4. Mit **RTN** zurück zum Hauptbildschirm.

### 5. Touch einschalten (für den QR-Code)

EdgeTX gibt Fingertipps im App-Modus erst an das Widget weiter, wenn man **einmal lange auf
den Bildschirm drückt**. Solange das nicht passiert ist, steht in der Kopfzeile
„For touch: long-press“ (für Touch lang drücken). Zurück geht es mit **langem Druck auf
RTN**. Nach einem Neustart der Funke ist das wieder nötig.

### Update auf eine neue Version

Den Ordner `WIDGETS/VAPORDASH` erneut auf die SD-Karte kopieren und die Dateien
überschreiben. Die gesicherte Position (`lastpos.txt`) bleibt erhalten. Falls Änderungen
nicht ankommen: Die `.luac`-Dateien im Ordner auf der SD-Karte löschen. EdgeTX legt sie
beim nächsten Start neu an.

## Einstellungen

### Widget

| Einstellung (auf dem Bildschirm) | Bedeutung |
|---|---|
| Battery cells (0 = auto) | Akku-Zellen. Standard 6 (6S). Bei 0 schätzt das Widget die Zellzahl aus der Spannung. |
| Poll motor RPM | Motordrehzahl abfragen: Off (aus) / Normal / Fast (schnell). „Fast“ aktualisiert öfter, braucht aber mehr Funk-Bandbreite. |

### Betaflight

| Was | Wie |
|---|---|
| Telemetrie | Tab „Empfänger“: Telemetrie-Ausgabe einschalten |
| Akku-% | `set bat_capacity = 1300` (Größe deines Akkus), Strom und Spannung im Tab „Strom & Akku“ kalibrieren |
| Pack-Spannung | `report_cell_voltage` aus lassen (Standard) |
| Motordrehzahlen | `set dshot_bidir = ON`, `set motor_poles = 14` (bei BLHeli_S nur mit [Bluejay](https://esc-configurator.com)) |
| ESC-Temperaturen | zusätzlich `set dshot_edt = ON` (Bluejay 0.20 oder neuer) |
| GPS | Tab „Konfiguration“: GPS an (UBLOX), Tab „Anschlüsse“: GPS am richtigen UART |

Danach `save` eingeben. Die Gründe zu jeder Einstellung stehen in der
[ausführlichen Anleitung](docs/ANLEITUNG.md).

## QR-Code mit der letzten Position

1. Touch einschalten (lange auf den Bildschirm drücken).
2. **GPS-Kachel antippen**. Ein Fenster mit QR-Code, Koordinaten, Uhrzeit, Höhe und
   Entfernung zum Start öffnet sich.
3. Mit der Handy-Kamera scannen. Android öffnet die Karten-App mit einer Stecknadel.
4. Zum Schließen auf das Fenster tippen.

Der Code enthält einen `geo:`-Link, z. B. `geo:52.521078,13.405000?q=52.521078,13.405000(VAPOR-D5)`.
iPhones erkennen `geo:`-Links mit der Kamera nicht, dort die Koordinaten aus dem Fenster
übernehmen.

## Was bedeuten die Hinweise im Widget?

| Anzeige | Bedeutung und Abhilfe |
|---|---|
| **For touch: long-press** (Kopfzeile) | Fingertipps kommen noch nicht beim Widget an. Einmal lange auf den Bildschirm drücken. |
| **NO SIGNAL** | Keine Verbindung zur Drohne: Akku ab oder außer Reichweite. |
| **LINK LOST!** (blinkt) | Verbindung im Flug verloren. Die letzte Position steht gelb im GPS-Feld und im QR-Code. |
| **BLOCKED** + Grund | Betaflight verhindert den Start. Der Grund steht darunter, z. B. „Throttle not low“ (Gas nicht ganz unten). |
| **STATUS ?** | Der Flugmodus-Sensor `FM` fehlt. Telemetrie in Betaflight prüfen, Sensoren neu suchen. |
| Motoren: **waiting for data...** | Die Antwort von Betaflight ist unterwegs. Über ELRS dauert das ein paar Sekunden. |
| Motoren: **ESC sends no RPM** | Bidirektionales DShot ist an, die ESC antwortet aber nicht (BLHeli_S ohne Bluejay). Bluejay flashen oder `dshot_bidir = OFF`. |
| Motoren: **No RPM: bidir. DShot on?** | Die Drohne ist scharf, aber alle Drehzahlen sind 0: `dshot_bidir` ist aus. |
| GPS: **missing** / **No GPS data** | Betaflight schickt keine GPS-Daten. GPS in Betaflight einschalten, Sensoren neu suchen. |
| GPS: **no fix yet** | Das GPS liefert Daten, hat aber noch keinen Fix. Ins Freie gehen und ein paar Minuten warten. |

Taucht statt des Dashboards eine Meldung wie `ERROR in refresh(): …` auf, bitte die Meldung
als Issue melden.

## Weitere Unterlagen

- **[docs/ANLEITUNG.md](docs/ANLEITUNG.md):** ausführliche Anleitung. Sie erklärt, wie die
  Werte entstehen (Scharf-Erkennung, Flugzeit, MSP-Abfragen), was am echten Gerät zu prüfen
  ist und wie die PC-Vorschau funktioniert.
- **[design/](design/):** erste Skizze, Wireframe und frühe Vorschaubilder.
- **[docs/EdgeTX_Handbuch_DE.pdf](docs/EdgeTX_Handbuch_DE.pdf):** EdgeTX-Benutzerhandbuch
  auf Deutsch.

## Projektstruktur

```
WIDGETS/VAPORDASH/      kommt auf die SD-Karte nach /WIDGETS/
  main.lua              Widget-Einstieg, Optionen, Touch
  lib/telemetry.lua     Sensoren, Status, Flugzeit, Akku, GPS, gesicherte Position
  lib/crsf.lua          MSP-Abfragen an Betaflight, ELRS-Geräteinfos
  lib/ui.lua            Zeichnen aller Felder und des QR-Fensters
  lib/qr.lua            QR-Code-Erzeuger
  icons/, images/       Symbole und Hintergrundbild
tools/preview/          PC-Vorschau (Lua 5.3 + nachgebaute EdgeTX-API)
docs/                   Anleitung, Screenshots, EdgeTX-Handbuch
design/                 Skizzen und Vorschaubilder
```

## Quellen und Dank

- **Symbole** (Akku, Uhr, Drohne, Signal, Satellit, Verbindung) stammen aus dem Widget
  [edgetx-telemetry-dashboard](https://github.com/dbarrios83/edgetx-telemetry-dashboard)
  von dbarrios83. Dessen Aufbau war auch das Vorbild für das Design.
- **QR-Code-Erzeugung** nach der Referenz-Implementierung von
  [Project Nayuki](https://www.nayuki.io/page/qr-code-generator-library) (MIT-Lizenz).
- **Deutsches EdgeTX-Handbuch:** Übersetzung des EdgeTX User Manual, CC BY-SA 4.0
  (Details im PDF).
