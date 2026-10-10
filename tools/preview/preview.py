"""Desktop-Vorschau fuer das VAPORDASH-Widget.

Fuehrt den Lua-Code des Widgets mit Lua 5.3 (wie EdgeTX 2.12) und einer
nachgebauten EdgeTX-API aus, simuliert Telemetrie, Betaflight-MSP-Antworten
und ELRS-Geraeteinfos und speichert pro Szenario ein 800x480-PNG.

    python -m venv venv && venv/Scripts/pip install lupa pillow
    venv/Scripts/python tools/preview/preview.py

Die Bilder landen in tools/preview/out/.
"""

import math
import struct
import sys
import urllib.request
from pathlib import Path

import lupa.lua53 as lua53
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = HERE / "out"
SD_ROOT = OUT / "sd"
FONT_DIR = HERE / "fonts"
FONT_URL = "https://raw.githubusercontent.com/EdgeTX/edgetx/v2.12.4/radio/src/fonts/Roboto/"

W, H = 800, 480

# EdgeTX-Schriftindex -> (Datei, Pixelgroesse) fuer 800x480 ("lrg"-Fonts)
FONT_TABLE = {
    0: ("Roboto-Regular.ttf", 22),  # STDSIZE
    1: ("Roboto-Bold.ttf", 22),     # BOLD
    2: ("Roboto-Regular.ttf", 12),  # TINSIZE
    3: ("Roboto-Regular.ttf", 18),  # SMLSIZE
    4: ("Roboto-Regular.ttf", 33),  # MIDSIZE
    5: ("Roboto-Bold.ttf", 44),     # DBLSIZE
    6: ("Roboto-Bold.ttf", 88),     # XXLSIZE
    7: ("Roboto-Bold.ttf", 66),     # XLSIZE
}

CENTER, RIGHT, VCENTER, SHADOWED, BLINK = 0x01, 0x02, 0x04, 0x08, 0x10
RGB_FLAG = 0x8000

ADDR_RADIO, ADDR_FC, ADDR_RX, ADDR_TX = 0xEA, 0xC8, 0xEC, 0xEE


def ensure_fonts():
    FONT_DIR.mkdir(exist_ok=True)
    for name in ("Roboto-Regular.ttf", "Roboto-Bold.ttf"):
        path = FONT_DIR / name
        if not path.exists():
            urllib.request.urlretrieve(FONT_URL + name, path)


class Canvas:
    def __init__(self):
        self.img = Image.new("RGB", (W, H), (200, 200, 200))
        self.draw = ImageDraw.Draw(self.img, "RGBA")
        self.fonts = {}
        self.ops = 0
        self.blink_on = True

    def font(self, idx):
        if idx not in self.fonts:
            name, size = FONT_TABLE.get(idx, FONT_TABLE[0])
            self.fonts[idx] = ImageFont.truetype(str(FONT_DIR / name), size)
        return self.fonts[idx]

    @staticmethod
    def color(flags, default=(0, 0, 0)):
        if not flags & RGB_FLAG:
            return default
        c = (flags >> 16) & 0xFFFF
        return (((c >> 11) & 31) * 255 // 31, ((c >> 5) & 63) * 255 // 63, (c & 31) * 255 // 31)


def check_int(*values):
    for v in values:
        if isinstance(v, float) and not v.is_integer():
            raise ValueError(f"EdgeTX erwartet Ganzzahlen, bekam {v}")


class Sim:
    """Simulierte Drohne + Funkstrecke fuer ein Szenario.

    MSP-Antworten kommen wie ueber ELRS langsam zurueck (msp_rate Byte pro
    10-ms-Tick). Eine neue MSP-Anfrage verwirft den noch nicht gesendeten
    Rest der vorigen Antwort -- so verhaelt sich Betaflights msp_shared.c.
    """

    def __init__(self, sensors, rssi=100, fc=None, chunk=57, msp_rate=0.35, msp_delay=20):
        self.now = 0
        self.sensors = dict(sensors)   # Name -> Wert
        self.rssi = rssi
        self.fc = fc or {}              # MSP-Antwortdaten
        self.chunk = chunk
        self.msp_rate = msp_rate
        self.msp_delay = msp_delay
        self.queue = []                 # (Zustellzeit, cmd, data, art)
        self.pushes = []
        self.msp_seq = 0

    def frame(self, cmd, data, at=None, kind="info"):
        self.queue.append((self.now + 10 if at is None else at, cmd, list(data), kind))

    def on_push(self, cmd, data):
        self.pushes.append((cmd, data))
        if cmd == 0x28:
            def info(origin, name, sw):
                return [ADDR_RADIO, origin] + list(name.encode()) + [0] + list(b"ELRS") + [0, 0, 0, 0] + sw + [5, 1]
            self.frame(0x29, info(ADDR_TX, "RM XROSS 2400", [0, 3, 5, 3]))
            if self.rssi > 0:
                self.frame(0x29, info(ADDR_RX, "GEPRC ELRS RX", [0, 3, 5, 3]))
                fc_name = list(b"Betaflight: GEPR") + [0] + [0] * 12 + [0, 1]
                self.frame(0x29, [ADDR_RADIO, ADDR_FC] + fc_name)
        elif cmd == 0x7A and data[0] == ADDR_FC and self.rssi > 0:
            status, cmd_id = data[2], data[4]
            # Betaflight ueberschreibt den Antwortpuffer: Rest der alten Antwort geht verloren
            self.queue = [q for q in self.queue if q[3] != "msp" or q[0] <= self.now]
            payload = self.msp_payload(cmd_id)
            if payload is None:
                return
            body = [len(payload), cmd_id] + payload
            version = (status >> 5) & 3
            first = True
            sent = 0
            while body or first:
                head = 0x10 if first else 0
                st = head | (self.msp_seq & 0x0F) | (version << 5)
                self.msp_seq += 1
                room = self.chunk - 1
                part, body = body[:room], body[room:]
                sent += len(part) + 3
                at = self.now + self.msp_delay + int(sent / self.msp_rate)
                self.frame(0x7B, [ADDR_RADIO, ADDR_FC, st] + part, at=at, kind="msp")
                first = False

    def msp_payload(self, cmd):
        if cmd == 3:
            text = list(b"2026.6.2")
            return [26, 6, 2, len(text)] + text
        if cmd == 139 and "motors" in self.fc:
            out = [len(self.fc["motors"])]
            for rpm, invalid, temp in self.fc["motors"]:
                out += list(struct.pack("<IHBHHH", rpm, invalid, temp, 0, 0, 0))
            return out
        if cmd == 150:
            flags = self.fc.get("arming", 0)
            out = list(struct.pack("<HHHIBHBB", 125, 0, 0x2B, 0, 0, 12, 4, 0))
            out += [1, 0]                       # 1 Byte erweiterte Flugmodus-Flags
            out += [30] + list(struct.pack("<I", flags))
            out += [0] + list(struct.pack("<H", 47)) + [4, 3, 0]
            return out
        return None


def make_runtime(sim, canvas):
    lua = lua53.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    lua_load = lua.eval("load")
    table = lua.table_from

    font_flags = {"STDSIZE": 0, "BOLD": 0x100, "TINSIZE": 0x200, "SMLSIZE": 0x300,
                  "MIDSIZE": 0x400, "DBLSIZE": 0x500, "XXLSIZE": 0x600, "XLSIZE": 0x700}
    for k, v in font_flags.items():
        g[k] = v
    g.CENTER, g.RIGHT, g.VCENTER, g.SHADOWED, g.BLINK = CENTER, RIGHT, VCENTER, SHADOWED, BLINK
    g.SOLID, g.DOTTED = 0, 1
    g.VALUE, g.SOURCE, g.BOOL, g.CHOICE = 0, 1, 2, 10

    def rgb(*args):
        if len(args) == 1:
            r, gg, b = (args[0] >> 16) & 255, (args[0] >> 8) & 255, args[0] & 255
        else:
            r, gg, b = args
        c565 = ((r >> 3) << 11) | ((gg >> 2) << 5) | (b >> 3)
        return (c565 << 16) | RGB_FLAG

    g.WHITE, g.BLACK = rgb(255, 255, 255), rgb(0, 0, 0)

    def fill_rect(x, y, w, h, flags=0, transp=0):
        check_int(x, y, w, h)
        canvas.ops += 1
        if w <= 0 or h <= 0 or transp >= 15:
            return
        a = int((15 - transp) * 255 / 15)
        canvas.draw.rectangle([x, y, x + w - 1, y + h - 1], fill=canvas.color(flags) + (a,))

    def draw_rect(x, y, w, h, flags=0, thick=1, transp=0):
        check_int(x, y, w, h)
        canvas.ops += 1
        a = int((15 - transp) * 255 / 15)
        for t in range(thick):
            canvas.draw.rectangle([x + t, y + t, x + w - 1 - t, y + h - 1 - t],
                                  outline=canvas.color(flags) + (a,))

    def text_size(s, flags=0):
        f = canvas.font((flags >> 8) & 0xF)
        asc, desc = f.getmetrics()
        return int(round(f.getlength(s))), asc + desc

    def draw_text(x, y, s, flags=0):
        check_int(x, y)
        canvas.ops += 1
        if flags & BLINK and not canvas.blink_on:
            return
        f = canvas.font((flags >> 8) & 0xF)
        w, h = text_size(s, flags)
        if flags & VCENTER:
            y -= h // 2
        if flags & RIGHT:
            x -= w
        elif flags & CENTER:
            x -= w // 2
        if flags & SHADOWED:
            canvas.draw.text((x + 1, y + 1), s, font=f, fill=(0, 0, 0))
        canvas.draw.text((x, y), s, font=f, fill=canvas.color(flags, (0, 0, 0)), anchor="la")

    def filled_circle(x, y, r, flags=0):
        check_int(x, y, r)
        canvas.ops += 1
        canvas.draw.ellipse([x - r, y - r, x + r, y + r], fill=canvas.color(flags))

    def circle_outline(x, y, r, flags=0):
        check_int(x, y, r)
        canvas.ops += 1
        canvas.draw.ellipse([x - r, y - r, x + r, y + r], outline=canvas.color(flags))

    def filled_tri(x1, y1, x2, y2, x3, y3, flags=0):
        check_int(x1, y1, x2, y2, x3, y3)
        canvas.ops += 1
        canvas.draw.polygon([(x1, y1), (x2, y2), (x3, y3)], fill=canvas.color(flags))

    def line(x1, y1, x2, y2, pattern=0, flags=0):
        check_int(x1, y1, x2, y2)
        canvas.ops += 1
        canvas.draw.line([(x1, y1), (x2, y2)], fill=canvas.color(flags), width=1)

    def draw_bitmap(bmp, x, y, scale=None):
        check_int(x, y)
        canvas.ops += 1
        canvas.img.paste(bmp, (x, y), bmp)

    g.lcd = table({
        "RGB": rgb, "drawFilledRectangle": fill_rect, "drawRectangle": draw_rect,
        "drawText": draw_text, "sizeText": text_size, "drawFilledCircle": filled_circle,
        "drawCircle": circle_outline, "drawFilledTriangle": filled_tri, "drawLine": line,
        "drawBitmap": draw_bitmap,
    })

    def bitmap_open(path):
        real = ROOT / path.lstrip("/")
        return Image.open(real).convert("RGBA") if real.exists() else None

    def bitmap_size(bmp):
        return bmp.size if bmp is not None else (0, 0)

    g.Bitmap = table({"open": bitmap_open, "getSize": bitmap_size})

    def load_script(path, *args):
        real = ROOT / path.lstrip("/")
        if not real.exists():
            return None
        fn = lua_load(real.read_text(encoding="utf-8"), "@" + path)
        if isinstance(fn, tuple):
            raise RuntimeError(f"Lua-Fehler in {path}: {fn[1]}")
        return fn

    g.loadScript = load_script

    ids = {}

    def field_info(name):
        if name in sim.sensors:
            ids.setdefault(name, 1000 + len(ids))
            return table({"id": ids[name], "name": name})
        return None

    by_id = {}

    def get_value(src):
        if src == "tx-voltage":
            return 7.9
        if isinstance(src, int):
            name = next((n for n, i in ids.items() if i == src), None)
            if name is None:
                return 0
            src = name
        v = sim.sensors.get(src, 0)
        if isinstance(v, dict):
            return table(v)
        return v

    g.getFieldInfo = field_info
    g.getValue = get_value
    g.getRSSI = lambda: (sim.rssi, 45, 42)
    g.getTime = lambda: sim.now
    g.getDateTime = lambda: table({"year": 2026, "mon": 10, "day": 10, "hour": 14, "min": 32, "sec": 5})
    g.getVersion = lambda: ("2.12.4", "tx16smk3", 2, 12, 4, "EdgeTX")
    g.getGeneralSettings = lambda: table({"battMin": 6.6, "battMax": 8.4, "battWarn": 7.0})
    g.model = table({"getInfo": lambda: table({"name": "VAPOR-D5"})})

    def push(*args):
        if not args:
            return True
        cmd, data = args
        sim.on_push(cmd, [data[i] for i in range(1, len(data) + 1)])
        return True

    def pop():
        for i, (at, cmd, data, kind) in enumerate(sim.queue):
            if at <= sim.now:
                sim.queue.pop(i)
                return cmd, table(data)
        return None

    g.crossfireTelemetryPush = push
    g.crossfireTelemetryPop = pop

    # SD-Karte: /WIDGETS/... -> tools/preview/out/sd/WIDGETS/...
    def sd_path(path):
        return SD_ROOT / path.lstrip("/")

    def io_open(path, mode="r"):
        real = sd_path(path)
        if mode.startswith("r"):
            return open(real, "r", encoding="utf-8") if real.exists() else None
        real.parent.mkdir(parents=True, exist_ok=True)
        return open(real, "a" if mode.startswith("a") else "w", encoding="utf-8")

    g.io = table({
        "open": io_open,
        "read": lambda f, n=None: f.read(n) if n else f.read(),
        "write": lambda f, *parts: f.write("".join(str(x) for x in parts)),
        "close": lambda f: f.close(),
    })
    g.EVT_TOUCH_TAP = 0x7001
    g.EVT_TOUCH_FIRST = 0x7002
    g.EVT_TOUCH_BREAK = 0x7003
    g.EVT_TOUCH_SLIDE = 0x7004

    # Python-Funktionen sind in Lua "userdata"; auf dem Sender sind es echte
    # Lua-Funktionen (type(f) == "function"). Deshalb einpacken.
    lua.execute("""
        local function wrap(f) return function(...) return f(...) end end
        for _, k in ipairs({"loadScript", "getFieldInfo", "getValue", "getRSSI", "getTime",
            "getDateTime", "getVersion", "getGeneralSettings",
            "crossfireTelemetryPush", "crossfireTelemetryPop"}) do
          _G[k] = wrap(_G[k])
        end
        for _, t in ipairs({lcd, Bitmap, model, io}) do
          for k, v in pairs(t) do t[k] = wrap(v) end
        end

        -- CPU-Limit wie bei EdgeTX-Widgets: Hook alle 200 Befehle, Abbruch
        -- nach mehr als 100 Hooks (= ~20.000 Befehle) je Aufruf.
        local sethook = debug.sethook
        __cpu = { count = 0 }
        local function hook()
          __cpu.count = __cpu.count + 1
          if __cpu.count > 100 then error("CPU limit") end
        end
        function __cpu_begin() __cpu.count = 0; sethook(hook, "", 200) end
        function __cpu_end() sethook(); return __cpu.count * 200 end

        -- Wie auf dem Sender (EdgeTX 2.12, lua/linit.c): Strings haben keine
        -- Methoden, und diese Bibliotheken gibt es in der Widget-Umgebung nicht.
        debug.setmetatable("", nil)
        coroutine, debug, os, utf8, package, require = nil, nil, nil, nil, nil, nil
    """)
    return lua


def base_sensors():
    return {
        "RxBt": 25.1, "Curr": 0.4, "Capa": 3, "Bat%": 100, "FM": "AIR*",
        "Ptch": 0.01, "Roll": -0.02, "Yaw": 1.57, "Alt": 0.1, "VSpd": 0.0,
        "GPS": {"lat": 52.52, "lon": 13.405}, "GSpd": 0.0, "GAlt": 0, "Sats": 12,
        "1RSS": -48, "2RSS": 0, "RQly": 100, "RSNR": 11, "ANT": 0, "RFMD": 9,
        "TPWR": 100, "TRSS": -55, "TQly": 100, "TSNR": 9,
    }


class Scenario:
    """fullscreen: wie EdgeTX im App-Modus nach langem Druecken (Standard). Ohne Vollbild
    bekommt das Widget event = nil und keine Touch-Meldungen.
    tap: (x, y) kurzer Tipp, (x, y, "lang") Beruehrung ueber 250 ms."""

    def __init__(self, name, title, options=None, sd=None, fullscreen=True):
        self.name, self.title = name, title
        self.fullscreen = fullscreen
        self.options = options or {"Cells": 6, "MotorPoll": 2}
        self.sd = sd or {}   # Dateien, die vorher auf der SD-Karte liegen
        self.steps = []      # (sensors-update, rssi, fc-update, seconds, tap)

    def step(self, seconds, sensors=None, rssi=None, fc=None, tap=None):
        self.steps.append((sensors or {}, rssi, fc or {}, seconds, tap))
        return self


def scenarios():
    idle = {"motors": [(0, 0, 0)] * 4}
    flying = {"motors": [(21760, 12, 42), (22040, 9, 43), (20910, 15, 40), (21380, 11, 41)]}
    flight_values = {
        "FM": "AIR", "RxBt": 22.7, "Curr": 18.3, "Capa": 496, "Bat%": 62,
        "Ptch": 0.14, "Roll": 0.21, "Yaw": 4.71, "Alt": 12.4, "VSpd": 1.2,
        "GSpd": 34.2, "GAlt": 15, "Sats": 11, "GPS": {"lat": 52.5210780, "lon": 13.405},
    }
    out = []
    out.append(Scenario("01_gesichert", "Gesichert, startklar").step(3, fc=idle))
    out.append(Scenario("02_flug", "Im Flug").step(2, fc=idle).step(1, {"FM": "AIR"}, fc=flying)
               .step(206, flight_values))
    out.append(Scenario("03_gesperrt", "Start gesperrt").step(12, {"FM": "ACRO!", "Ptch": 0.4},
               fc=dict(idle, arming=(1 << 7) | (1 << 8) | (1 << 29))))
    out.append(Scenario("04_akku_leer", "Akku fast leer, Motor 3 steht").step(2, fc=idle)
               .step(281, dict(flight_values, **{"FM": "ACRO", "RxBt": 20.6, "Curr": 31.5, "Capa": 1152,
                                                 "Bat%": 18, "VSpd": -2.4, "RQly": 71, "1RSS": -92}),
                     fc={"motors": [(24100, 10, 55), (23880, 14, 76), (0, 0, 0), (24400, 9, 54)]}))
    out.append(Scenario("05_failsafe", "Failsafe").step(2, fc=idle).step(1, {"FM": "AIR"}, fc=flying)
               .step(95, flight_values).step(3, {"FM": "!FS!", "RQly": 0, "1RSS": -118}))
    out.append(Scenario("06_kein_signal", "Noch nie verbunden").step(3, rssi=0))
    out.append(Scenario("07_signal_weg", "Verbindung im Flug verloren").step(2, fc=idle)
               .step(1, {"FM": "AIR"}, fc=flying).step(130, flight_values).step(5, rssi=0))
    out.append(Scenario("08_gps_wartet", "GPS wartet, Motor-Abfrage aus",
                        options={"Cells": 0, "MotorPoll": 1})
               .step(3, {"FM": "ANGL?", "Sats": 4, "GPS": 0, "RxBt": 24.2, "Bat%": None}))
    out.append(Scenario("09_ohne_gps_daten", "Betaflight schickt keine GPS-Daten")
               .step(3, {"GPS": None, "Sats": None, "GSpd": None, "GAlt": None}, fc=idle))
    out.append(Scenario("10_gesperrt_esc", "Bidir. DShot an, ESC ohne Bluejay")
               .step(20, {"FM": "AIR!"},
                     fc={"motors": [(0, 10000, 0)] * 4, "arming": (1 << 20) | (1 << 29)}))
    gps_tile = (709, 354)
    out.append(Scenario("11_qr_aktuell", "GPS-Kachel angetippt, verbunden", fullscreen=True).step(2, fc=idle)
               .step(1, {"FM": "AIR"}, fc=flying).step(60, flight_values).step(4, tap=gps_tile))
    out.append(Scenario("12_qr_letzte", "Signal weg, GPS-Kachel lange angetippt", fullscreen=True)
               .step(2, fc=idle).step(1, {"FM": "AIR"}, fc=flying).step(60, flight_values).step(3, rssi=0)
               .step(4, tap=gps_tile + ("lang",)))
    saved = "52.521078;13.405000;15;10.10.2026 14:31:40;11\n"
    out.append(Scenario("13_qr_nach_neustart", "Funke neu gestartet, gesicherte Position",
                        sd={"/WIDGETS/VAPORDASH/lastpos.txt": saved}, fullscreen=True)
               .step(1, rssi=0).step(4, tap=gps_tile))
    out.append(Scenario("14_qr_ohne_position", "Noch nie eine Position", fullscreen=True).step(1, rssi=0)
               .step(2, tap=gps_tile))
    out.append(Scenario("15_qr_geschlossen", "Fenster geoeffnet und wieder zu", fullscreen=True)
               .step(2, fc=idle).step(4, tap=gps_tile).step(1, tap=(400, 240)))
    out.append(Scenario("16_ohne_vollbild", "Kein Vollbild: Tippen wirkt nicht", fullscreen=False)
               .step(2, fc=idle)
               .step(2, tap=gps_tile))
    return out


def run(sc):
    import shutil
    shutil.rmtree(SD_ROOT, ignore_errors=True)
    for path, content in sc.sd.items():
        real = SD_ROOT / path.lstrip("/")
        real.parent.mkdir(parents=True, exist_ok=True)
        real.write_text(content, encoding="utf-8")

    sensors = base_sensors()
    first_sensors, first_rssi = sc.steps[0][0], sc.steps[0][1]
    if first_rssi == 0 and not first_sensors:
        sensors = {}
    sim = Sim(sensors, rssi=100 if first_rssi is None else first_rssi, chunk=20 if sc.name == "02_flug" else 57)
    canvas = Canvas()
    lua = make_runtime(sim, canvas)
    g = lua.globals()
    widget_def = g.loadScript("/WIDGETS/VAPORDASH/main.lua")()
    zone = lua.table_from({"x": 0, "y": 0, "w": W, "h": H})
    g.__cpu_begin()
    widget = widget_def.create(zone, lua.table_from(sc.options))
    cpu_max = g.__cpu_end()

    def refresh(event=0, touch=None):
        nonlocal cpu_max
        if not sc.fullscreen:
            event, touch = None, None   # EdgeTX: kein Vollbild -> keine Ereignisse
        g.__cpu_begin()
        widget_def.refresh(widget, event, touch)
        cpu_max = max(cpu_max, g.__cpu_end())

    for sensors_upd, rssi, fc_upd, seconds, tap in sc.steps:
        for k, v in sensors_upd.items():
            if v is None:
                sim.sensors.pop(k, None)
            else:
                sim.sensors[k] = v
        if rssi is not None:
            sim.rssi = rssi
        sim.fc.update(fc_upd)
        # moeglichst echte 50-ms-Schritte, bei langen Abschnitten groeber
        frames = int(min(400, max(20, seconds * 20)))
        dt = max(1, int(seconds * 100 / frames))
        for f in range(frames):
            sim.now += dt
            canvas.ops = 0
            # Tipp wie bei EdgeTX: FIRST (mit Position), BREAK beim Loslassen,
            # TAP nur bei Beruehrungen unter 250 ms
            long_tap = tap is not None and len(tap) > 2
            release = 8 if long_tap else 2
            if tap and f == 0:
                refresh(g.EVT_TOUCH_FIRST, lua.table_from({"x": tap[0], "y": tap[1]}))
            elif tap and f == release:
                refresh(g.EVT_TOUCH_BREAK, lua.table_from({"x": 0, "y": 0}))
            elif tap and f == release + 1 and not long_tap:
                refresh(g.EVT_TOUCH_TAP, lua.table_from({"x": tap[0], "y": tap[1], "tapCount": 1}))
            else:
                refresh()

    # Letztes Bild in der "an"-Phase des Blinkens und auf frischem Hintergrund
    sim.now = (sim.now // 100 + 1) * 100
    canvas.img.paste((200, 200, 200), [0, 0, W, H])
    canvas.ops = 0
    refresh()
    link = widget.link
    stats = {"CPU max": cpu_max, "Motor-Antw.": link.motorReplies,
             "Fenster": widget.popup is not None}
    popup = widget.popup
    if popup is not None and popup.payload:
        stats["QR erwartet"] = popup.payload
        try:
            import zxingcpp
            found = zxingcpp.read_barcodes(canvas.img)
            stats["QR gelesen"] = found[0].text if found else None
        except ImportError:
            pass
    saved = SD_ROOT / "WIDGETS/VAPORDASH/lastpos.txt"
    if saved.exists():
        stats["SD"] = saved.read_text(encoding="utf-8").strip()
    return canvas.img, canvas.ops, sim, stats


def main():
    ensure_fonts()
    OUT.mkdir(exist_ok=True)
    results = []
    for sc in scenarios():
        img, ops, sim, stats = run(sc)
        path = OUT / f"{sc.name}.png"
        img.save(path)
        pushes = {}
        for cmd, data in sim.pushes:
            key = f"0x{cmd:02X}" + (f"/msp{data[4]}" if cmd == 0x7A else "")
            pushes[key] = pushes.get(key, 0) + 1
        warn = "  !!! CPU-LIMIT !!!" if stats["CPU max"] > 18000 else ""
        print(f"{sc.name:20s} {ops:4d} Zeichenbefehle  {stats}{warn}")
        if "QR erwartet" in stats and stats.get("QR gelesen", stats["QR erwartet"]) != stats["QR erwartet"]:
            print("   !!! QR-Code falsch gelesen !!!")
        results.append((sc, img))

    cols = 2
    rows = math.ceil(len(results) / cols)
    sheet = Image.new("RGB", (cols * (W + 20) + 20, rows * (H + 50) + 20), (30, 30, 34))
    d = ImageDraw.Draw(sheet)
    label_font = ImageFont.truetype(str(FONT_DIR / "Roboto-Bold.ttf"), 22)
    for i, (sc, img) in enumerate(results):
        x = 20 + (i % cols) * (W + 20)
        y = 20 + (i // cols) * (H + 50)
        d.text((x, y), f"{sc.name}: {sc.title}", font=label_font, fill=(230, 230, 230))
        sheet.paste(img, (x, y + 32))
    sheet.save(OUT / "uebersicht.png")
    print("gespeichert in", OUT)


if __name__ == "__main__":
    sys.exit(main())
