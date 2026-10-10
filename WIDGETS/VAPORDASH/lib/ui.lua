-- Zeichnet das Vapor-D5-Dashboard.
-- Ausgelegt fuer 800x480 (RadioMaster TX16S MK3) im App-Modus (Vollbild).
-- Schriftgroessen bei 800x480: TINSIZE 12, SMLSIZE 18, STD/BOLD 22,
-- MIDSIZE 33, DBLSIZE 44 fett, XLSIZE 66 fett, XXLSIZE 88 fett.

local M = {}

local ICON_DIR = "/WIDGETS/VAPORDASH/icons/"
-- Hintergrundbild in Displaygroesse (800x480); fehlt es, wird ein Verlauf gezeichnet.
local BACKGROUND_IMAGE = "/WIDGETS/VAPORDASH/images/background.png"
local floor = math.floor

-- Bereiche {x, y, w, h} relativ zur Zone. Oben links bleibt Platz fuer
-- den EdgeTX-Knopf, den das System im App-Modus selbst zeichnet.
local L = {
  header = { 90, 4, 706, 56 },
  batt   = { 4, 64, 272, 192 },
  arm    = { 280, 64, 266, 192 },
  time   = { 550, 64, 246, 192 },
  link   = { 4, 260, 173, 188 },
  motors = { 181, 260, 260, 188 },
  att    = { 445, 260, 173, 188 },
  gps    = { 622, 260, 174, 188 },
  footer = { 4, 452, 792, 26 },
  popup  = { 4, 64, 792, 384 },   -- QR-Fenster ueber allen Kacheln
}
local DESIGN_W, DESIGN_H = 800, 480

-- Betaflight Quad-X: Motor 1 hinten rechts, 2 vorne rechts,
-- 3 hinten links, 4 vorne links. {rechts(+1)/links(-1), hinten(+1)/vorne(-1)}
local MOTOR_POS = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

-- Gruende fuer die Startsperre (Betaflight 2026.6, fc/runtime_config.h),
-- Bit-Nummer -> kurzer Text. Reihenfolge = Wichtigkeit.
local ARM_REASONS = {
  [0] = "Kein Gyro-Sensor",
  [1] = "Failsafe aktiv",
  [2] = "Kein Funksignal",
  [3] = "Arm-Schalter erst aus",
  [4] = "Failsafe-Schalter an",
  [5] = "Notstopp (Runaway)",
  [6] = "Absturz erkannt",
  [7] = "Gas nicht ganz unten",
  [8] = "Drohne steht zu schief",
  [9] = "Startet noch - warten",
  [10] = "Prearm-Schalter fehlt",
  [11] = "Prozessor überlastet",
  [12] = "Kalibriert - stillhalten",
  [13] = "CLI am PC offen",
  [14] = "OSD-Menü offen",
  [15] = "BST aktiv",
  [16] = "Mit PC verbunden",
  [17] = "Paralyze aktiv",
  [18] = "Warte auf GPS",
  [19] = "Rettungs-Schalter an",
  [20] = "Motor-Telemetrie fehlt",
  [21] = "Neustart nötig",
  [22] = "DShot-Fehler",
  [23] = "Lagesensor kalibrieren",
  [24] = "Motor-Protokoll fehlt",
  [25] = "Turtle-Schalter an",
  [26] = "Höhe-halten-Schalter an",
  [27] = "Pos.-halten-Schalter an",
  [28] = "Autopilot-Schalter an",
  [29] = "Arm-Schalter erst aus",
}
local ARM_SWITCH_BIT = 29

local MODE_NAMES = {
  ACRO = "Akro", AIR = "Akro (Airmode)", ANGL = "Stabil (Angle)",
  STAB = "Stabil", HOR = "Horizont", RTH = "GPS-Heimflug",
  ALTH = "Höhe halten", POSH = "Position halten", PHFL = "Pos.-Halten Fehler",
  PASS = "Direkt", MANU = "Manuell", CHIR = "Chirp-Test",
  WAIT = "Warte auf GPS", ["!FS!"] = "Failsafe", ["!ERR"] = "Fehler",
}

local COMPASS = { "N", "NO", "O", "SO", "S", "SW", "W", "NW" }
local WEEKDAYS = { "So", "Mo", "Di", "Mi", "Do", "Fr", "Sa" }

-- Einheitskreis fuer den kuenstlichen Horizont
local CIRCLE = {}
for i = 0, 31 do
  local a = i * math.pi / 16
  CIRCLE[i + 1] = { math.cos(a), math.sin(a) }
end

local C, ICONS, BG, BG_IMAGE

local function initColors()
  local rgb = lcd.RGB
  C = {
    white = rgb(255, 255, 255), black = rgb(0, 0, 0),
    label = rgb(165, 176, 188), dim = rgb(95, 102, 112),
    green = rgb(48, 209, 88), yellow = rgb(255, 204, 0),
    orange = rgb(255, 140, 0), red = rgb(255, 59, 48), darkRed = rgb(150, 20, 16),
    gray = rgb(110, 110, 116),
    greenDisc = rgb(20, 74, 40), yellowDisc = rgb(80, 66, 10), redDisc = rgb(84, 24, 20),
    segOff = rgb(38, 42, 50), motorInner = rgb(20, 20, 24), popup = rgb(14, 16, 22),
    body = rgb(55, 55, 62), arm = rgb(150, 150, 158),
    sky = rgb(58, 130, 220), earth = rgb(150, 95, 45),
  }
  -- Hintergrund: senkrechter Verlauf dunkelblau -> fast schwarz
  BG = {}
  for i = 0, 23 do
    local k = i / 23
    BG[i + 1] = rgb(floor(24 - 20 * k), floor(42 - 36 * k), floor(68 - 56 * k))
  end
end

local function loadIcons()
  ICONS = {}
  if not Bitmap or not Bitmap.open then return end
  for _, name in ipairs({ "battery", "clock", "drone", "signal", "sat",
      "connection-ok", "connection-warn", "connection-low", "connection-dead" }) do
    ICONS[name] = Bitmap.open(ICON_DIR .. name .. ".png")
  end
  -- Bitmap.open liefert auch bei fehlender Datei oder zu wenig Speicher ein
  -- (leeres) Objekt; erst getSize zeigt, ob das Bild wirklich geladen wurde.
  local bmp = Bitmap.open(BACKGROUND_IMAGE)
  local w = (bmp and Bitmap.getSize) and Bitmap.getSize(bmp) or 0
  BG_IMAGE = (w and w > 0) and bmp or nil
end

-------------------------------------------------------------------------------
-- Zeichen-Grundfunktionen (EdgeTX verlangt ganzzahlige Koordinaten)
-------------------------------------------------------------------------------

local function rect(x, y, w, h, color, transp)
  lcd.drawFilledRectangle(floor(x), floor(y), floor(w), floor(h), color, transp or 0)
end

local function frame(x, y, w, h, color, thick, transp)
  lcd.drawRectangle(floor(x), floor(y), floor(w), floor(h), color, thick or 1, transp or 0)
end

local function text(x, y, s, flags)
  lcd.drawText(floor(x), floor(y), s, flags)
end

local function textW(s, font)
  return (lcd.sizeText(s, font))
end

local function circle(x, y, r, color)
  lcd.drawFilledCircle(floor(x + 0.5), floor(y + 0.5), floor(r), color)
end

local function tri(x1, y1, x2, y2, x3, y3, color)
  lcd.drawFilledTriangle(floor(x1 + 0.5), floor(y1 + 0.5), floor(x2 + 0.5), floor(y2 + 0.5),
    floor(x3 + 0.5), floor(y3 + 0.5), color)
end

local function icon(bmp, x, y)
  if bmp then lcd.drawBitmap(bmp, floor(x), floor(y)) end
end

local function roundRect(x, y, w, h, r, color)
  rect(x + r, y, w - 2 * r, h, color)
  rect(x, y + r, r, h - 2 * r, color)
  rect(x + w - r, y + r, r, h - 2 * r, color)
  circle(x + r, y + r, r, color)
  circle(x + w - r - 1, y + r, r, color)
  circle(x + r, y + h - r - 1, r, color)
  circle(x + w - r - 1, y + h - r - 1, r, color)
end

local function thickLine(x1, y1, x2, y2, width, color)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len == 0 then return end
  local ox, oy = -dy / len * width / 2, dx / len * width / 2
  tri(x1 + ox, y1 + oy, x2 + ox, y2 + oy, x2 - ox, y2 - oy, color)
  tri(x1 + ox, y1 + oy, x2 - ox, y2 - oy, x1 - ox, y1 - oy, color)
end

-- Erste Schrift aus der Liste, in der der Text in maxW passt.
local function fitFont(s, maxW, fonts)
  for i = 1, #fonts do
    if textW(s, fonts[i]) <= maxW then return fonts[i] end
  end
  return fonts[#fonts]
end

-- Weisse Schrift mit schwarzem Rand (gut lesbar auf bunten Flaechen).
local function outlined(x, y, s, flags, color)
  text(x - 2, y - 2, s, flags + C.black)
  text(x + 2, y - 2, s, flags + C.black)
  text(x - 2, y + 2, s, flags + C.black)
  text(x + 2, y + 2, s, flags + C.black)
  text(x, y, s, flags + color)
end

-- Kachel: durchsichtig, nur ein feiner Rahmen ueber dem Hintergrundbild.
local function panel(r, title, bmp)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  frame(x, y, w, h, C.white, 1, 10)
  if title then
    local tx = x + 10
    if bmp then
      icon(bmp, x + 7, y + 5)
      tx = x + 37
    end
    text(tx, y + 17, title, SMLSIZE + VCENTER + C.label)
  end
end

local function titleRight(r, s, flags)
  text(r[1] + r[3] - 10, r[2] + 17, s, SMLSIZE + VCENTER + RIGHT + flags)
end

local function row(r, yOff, label, value, color)
  text(r[1] + 10, r[2] + yOff, label, SMLSIZE + VCENTER + C.label)
  text(r[1] + r[3] - 10, r[2] + yOff, value, SMLSIZE + VCENTER + RIGHT + (color or C.white))
end

local function blinkOn(now)
  return floor(now / 50) % 2 == 0
end

-------------------------------------------------------------------------------
-- Formatierung
-- Hinweis: In der Widget-Umgebung von EdgeTX haben Strings keine Methoden,
-- also immer string.xxx(s, ...) statt s:xxx(...) schreiben.
-------------------------------------------------------------------------------

local function dec(v, digits)
  local s = string.format("%." .. digits .. "f", v)
  return (string.gsub(s, "%.", ","))
end

local function int(v)
  return tostring(floor(v + 0.5))
end

local function thousands(n)
  local s = string.reverse(int(n))
  s = string.gsub(s, "(%d%d%d)", "%1.")
  s = string.reverse(s)
  if string.sub(s, 1, 1) == "." then s = string.sub(s, 2) end
  return s
end

local function fmtTime(sec)
  return string.format("%02d:%02d", floor(sec / 60), floor(sec % 60))
end

local function fmtDistance(m)
  if m < 1000 then return int(m) .. " m" end
  return dec(m / 1000, 2) .. " km"
end

local function batteryColor(pct)
  if pct >= 50 then return C.green end
  if pct >= 25 then return C.yellow end
  return C.red
end

local function weekday(y, m, d)
  local t = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
  if m < 3 then y = y - 1 end
  return (y + floor(y / 4) - floor(y / 100) + floor(y / 400) + t[m] + d) % 7
end

-- Wichtigster Grund der Startsperre + Anzahl weiterer Gruende.
-- EdgeTX-Lua rechnet mit 32-Bit-Ganzzahlen und einfach genauen Floats:
-- Bits deshalb mit Ganzzahl-Operatoren pruefen, nicht per Division.
local function armReason(flags)
  local first, count, armSwitch = nil, 0, false
  flags = floor(flags)
  for bit = 0, 30 do
    if (flags >> bit) & 1 == 1 then
      if bit == ARM_SWITCH_BIT then
        armSwitch = true
      else
        count = count + 1
        if not first then first = bit end
      end
    end
  end
  if not first and armSwitch then first, count = ARM_SWITCH_BIT, 1 end
  if not first then return nil, 0 end
  return ARM_REASONS[first] or ("Grund " .. first), count - 1
end

-------------------------------------------------------------------------------
-- Felder
-------------------------------------------------------------------------------

local function drawBackground(x, y, w, h)
  if BG_IMAGE then
    icon(BG_IMAGE, x, y)
    return
  end
  local bandH = h / #BG
  for i = 1, #BG do
    local by = floor(y + (i - 1) * bandH)
    rect(x, by, w, floor(y + i * bandH) - by, BG[i])
  end
end

local function drawMiniBattery(x, y, w, h, pct, low)
  frame(x, y, w, h, C.white, 1)
  rect(x + w, y + h / 2 - 3, 3, 6, C.white)
  if pct then
    local fw = floor((w - 4) * pct / 100 + 0.5)
    if fw > 0 then
      rect(x + 2, y + 2, fw, h - 4, low and C.red or (pct < 40 and C.yellow or C.green))
    end
  end
end

-- interactive == false: EdgeTX schickt keine Touch-Meldungen (kein Vollbild)
local function drawHeader(r, tel, interactive)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  panel(r)
  local cy = y + h / 2

  local name = "VAPOR-D5"
  if model and model.getInfo then
    local info = model.getInfo()
    if info and info.name and info.name ~= "" then name = info.name end
  end
  local nameFont = fitFont(name, 300, { DBLSIZE, MIDSIZE, BOLD })
  text(x + 14, cy, name, nameFont + VCENTER + C.white)
  local nameEnd = x + 14 + textW(name, nameFont)

  -- rechts: Akku der Funke
  local xr = x + w - 12
  local tx = tel.txVolt and (dec(tel.txVolt, 1) .. " V") or "--"
  text(xr, cy, tx, BOLD + VCENTER + RIGHT + (tel.txLow and C.red or C.white))
  xr = xr - textW(tx, BOLD) - 10
  drawMiniBattery(xr - 31, cy - 8, 28, 16, tel.txPct, tel.txLow)
  xr = xr - 41
  text(xr, cy, "Funke", SMLSIZE + VCENTER + RIGHT + C.label)
  xr = xr - textW("Funke", SMLSIZE) - 16
  rect(xr, y + 12, 1, h - 24, C.dim)
  xr = xr - 16

  -- Verbindung
  local label, color, bmp
  if tel.connected then
    local lq = tel.lq or 0
    if lq >= 80 then
      label, color, bmp = "Verbunden", C.green, ICONS["connection-ok"]
    elseif lq >= 50 then
      label, color, bmp = "Signal schwach", C.yellow, ICONS["connection-warn"]
    else
      label, color, bmp = "Signal sehr schwach", C.red, ICONS["connection-low"]
    end
  elseif tel.arm == "lost" then
    label, color, bmp = "Verbindung weg!", C.red, ICONS["connection-dead"]
  else
    label, color, bmp = "Keine Verbindung", C.gray, ICONS["connection-dead"]
  end
  text(xr, cy, label, BOLD + VCENTER + RIGHT + color)
  xr = xr - textW(label, BOLD) - 8
  icon(bmp, xr - 30, cy - 15)

  -- Hinweis zwischen Name und Verbindung: Touch erst nach langem Druecken
  if interactive == false then
    local l1, l2 = "Für Touch:", "lang drücken"
    local avail = (xr - 46) - (nameEnd + 16)
    local f = fitFont(l2, avail, { SMLSIZE, TINSIZE })
    if textW(l2, f) <= avail and textW(l1, f) <= avail then
      local hx = nameEnd + 16 + avail / 2
      text(hx, cy - 10, l1, f + VCENTER + CENTER + C.yellow)
      text(hx, cy + 11, l2, f + VCENTER + CENTER + C.label)
    end
  end
end

local function drawBattery(r, tel, now)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  panel(r, "DROHNEN-AKKU", ICONS.battery)

  local live = tel.connected
  local pct = tel.everConnected and tel.pct or nil
  local col = pct and batteryColor(pct) or C.gray
  if not live then col = C.gray end

  local landNow = live and pct and pct < 25
  if landNow then
    if blinkOn(now) then titleRight(r, "LANDEN!", C.red) end
  elseif tel.cellCount then
    titleRight(r, tel.cellCount .. "S", C.label)
  end

  -- Akku-Symbol mit 10 Segmenten
  local bx, by, bw, bh = x + 10, y + 36, w - 34, 76
  local outline = live and C.white or C.gray
  if landNow and blinkOn(now) then outline = C.red end
  frame(bx, by, bw, bh, outline, 3)
  rect(bx + bw + 1, by + bh / 2 - 15, 8, 30, outline)
  local segs, pad, gap = 10, 7, 3
  local sw = (bw - 2 * pad - gap * (segs - 1)) / segs
  local filled = 0
  if pct then
    filled = floor(pct * segs / 100 + 0.5)
    if pct > 0 and filled == 0 then filled = 1 end
  end
  for i = 0, segs - 1 do
    local sx = bx + pad + floor(i * (sw + gap))
    rect(sx, by + pad, floor(sw), bh - 2 * pad, (i < filled) and col or C.segOff)
  end
  local pctText = pct and (int(pct) .. " %") or "--"
  outlined(bx + bw / 2, by + bh / 2, pctText, XLSIZE + VCENTER + CENTER, live and C.white or C.label)

  -- Werte darunter
  local vc = live and C.white or C.label
  local r1, r2 = y + 134, y + 166
  text(x + 10, r1, tel.volt and (dec(tel.volt, 1) .. " V") or "-- V", BOLD + VCENTER + vc)
  local cell = tel.cellVolt and (dec(tel.cellVolt, 2) .. " V pro Zelle") or "-- V pro Zelle"
  text(x + w - 10, r1, cell, SMLSIZE + VCENTER + RIGHT + C.label)

  local curr = tel.curr and (dec(tel.curr, 1) .. " A") or "-- A"
  text(x + 10, r2, curr, BOLD + VCENTER + vc)
  local capa = tel.capa and (int(tel.capa) .. " mAh") or "-- mAh"
  text(x + w - 10, r2, capa, BOLD + VCENTER + RIGHT + vc)
  -- Platz zwischen Strom (links) und mAh (rechts), je 6 px Abstand
  local free = w - 32 - textW(curr, BOLD) - textW(capa, BOLD)
  for _, word in ipairs({ "verbraucht", "verbr." }) do
    if textW(word, SMLSIZE) <= free then
      text(x + w - 16 - textW(capa, BOLD), r2, word, SMLSIZE + VCENTER + RIGHT + C.label)
      break
    end
  end
end

local STATES = {
  safe     = { "GESICHERT", "Motoren aus", "green" },
  armed    = { "SCHARF", "Motoren an - Abstand halten!", "red" },
  locked   = { "GESPERRT", "Start nicht möglich", "orange" },
  failsafe = { "FAILSAFE", "Signal verloren!", "red", true },
  lost     = { "SIGNAL WEG!", "Drohne war scharf!", "red", true },
  offline  = { "KEIN SIGNAL", "Drohne aus oder zu weit weg", "gray" },
  unknown  = { "STATUS ?", "Flugmodus fehlt", "gray" },
}

local function drawArm(r, tel, link, now)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  panel(r, "STATUS", ICONS.drone)

  local st = STATES[tel.arm] or STATES.unknown
  local color = C[st[3]]
  if st[4] and not blinkOn(now) then color = C.darkRed end

  local px, py, pw, ph = x + 6, y + 34, w - 12, 92
  roundRect(px, py, pw, ph, 14, color)
  local big = fitFont(st[1], pw - 16, { DBLSIZE, MIDSIZE, BOLD })
  text(px + pw / 2, py + 37, st[1], big + VCENTER + CENTER + C.white)
  text(px + pw / 2, py + 74, st[2], fitFont(st[2], pw - 12, { SMLSIZE, TINSIZE }) + VCENTER + CENTER + C.white)

  -- darunter: Flugmodus bzw. Grund der Sperre
  local label, value, vcolor = nil, nil, C.white
  if tel.arm == "locked" then
    label = "Grund"
    if link.armingFlags then
      local reason, more = armReason(link.armingFlags)
      value = reason or "unbekannt"
      if more > 0 then value = value .. " (+" .. more .. ")" end
    else
      value = "wird abgefragt..."
      vcolor = C.label
    end
    vcolor = link.armingFlags and C.orange or vcolor
  elseif tel.arm == "offline" then
    label, value, vcolor = "Tipp", "Drohnen-Akku anstecken", C.label
  elseif tel.arm == "lost" then
    label, value, vcolor = "Tipp", "Letzte Position: GPS-Feld", C.yellow
  elseif tel.arm == "unknown" then
    label, value, vcolor = "Tipp", "Betaflight: Telemetrie an?", C.label
  elseif tel.gpsWait and tel.arm == "safe" then
    label, value, vcolor = "Hinweis", "GPS noch nicht bereit", C.yellow
  else
    label = "Flugmodus"
    value = MODE_NAMES[tel.mode or ""] or tel.mode or "--"
  end
  text(x + w / 2, y + 144, label, SMLSIZE + VCENTER + CENTER + C.label)
  text(x + w / 2, y + 172, value, fitFont(value, w - 16, { MIDSIZE, BOLD, SMLSIZE }) + VCENTER + CENTER + vcolor)
end

local function drawTime(r, tel)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  panel(r, "FLUGZEIT", ICONS.clock)
  local sec = tel.flightSec or 0
  if tel.timerRunning then
    titleRight(r, "läuft", C.green)
    circle(x + w - 20 - textW("läuft", SMLSIZE), y + 17, 5, C.green)
  elseif sec > 0 then
    titleRight(r, "Pause", C.label)
  end

  local s = fmtTime(sec)
  local f = fitFont(s, w - 12, { XXLSIZE, XLSIZE, DBLSIZE })
  text(x + w / 2, y + 108, s, f + VCENTER + CENTER + C.white)

  if sec == 0 and not tel.timerRunning then
    local hint = "startet beim Scharfschalten"
    text(x + w / 2, y + 174, hint, fitFont(hint, w - 12, { SMLSIZE, TINSIZE }) + VCENTER + CENTER + C.label)
  end
end

local function drawMotors(r, tel, link, motorMode)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  panel(r, "MOTOREN", ICONS.drone)
  titleRight(r, "U/min", C.label)

  local cx, cy, d = x + w / 2, y + 118, 30
  text(cx, y + 46, "vorne", SMLSIZE + VCENTER + CENTER + C.yellow)

  for i = 1, 4 do
    thickLine(cx, cy, cx + MOTOR_POS[i][1] * d, cy + MOTOR_POS[i][2] * d, 5, C.arm)
  end
  rect(cx - 11, cy - 20, 22, 40, C.body)
  frame(cx - 11, cy - 20, 22, 40, C.white, 1)
  tri(cx, cy - 13, cx - 6, cy - 3, cx + 6, cy - 3, C.yellow)

  local armed = (tel.arm == "armed" or tel.arm == "failsafe")
  local motors = tel.connected and link.motors or nil
  local maxRpm, allZero, allInvalid = 0, true, (motors ~= nil and #motors > 0)
  if motors then
    for i = 1, #motors do
      if motors[i].rpm > maxRpm then maxRpm = motors[i].rpm end
      if motors[i].rpm > 0 then allZero = false end
      if motors[i].invalid < 10000 then allInvalid = false end
    end
  end

  for i = 1, 4 do
    local sxp, syp = MOTOR_POS[i][1], MOTOR_POS[i][2]
    local mx, my = cx + sxp * d, cy + syp * d
    local m = motors and motors[i]
    local color, disc = C.gray, nil
    local rpmText, tempText = "--", nil
    if m and m.invalid < 10000 then
      rpmText = thousands(m.rpm)
      if m.rpm > 0 then
        color, disc = C.green, C.greenDisc
      end
      if armed and m.rpm == 0 and maxRpm > 3000 then
        color, disc = C.red, C.redDisc
      end
      if m.temp and m.temp > 0 then
        tempText = m.temp .. " °C"
        if m.temp >= 90 then
          color, disc = C.red, disc and C.redDisc
        elseif m.temp >= 70 and color ~= C.red then
          color, disc = C.yellow, disc and C.yellowDisc
        end
      end
    end
    if disc then circle(mx, my, 23, disc) end
    circle(mx, my, 17, color)
    circle(mx, my, 13, C.motorInner)
    text(mx, my, tostring(i), BOLD + VCENTER + CENTER + C.white)

    local tx = mx + sxp * 28
    local align = (sxp < 0) and RIGHT or 0
    text(tx, my - 10, rpmText, BOLD + VCENTER + align + C.white)
    if tempText then
      text(tx, my + 13, tempText, SMLSIZE + VCENTER + align + C.label)
    end
  end

  -- invalid = 10000: bidirektionales DShot ist an, aber die ESC antwortet
  -- nicht (z. B. originales BLHeli_S ohne Bluejay).
  local hint
  if motorMode == "off" then
    hint = "Abfrage ausgeschaltet"
  elseif allInvalid then
    hint = "ESC sendet keine Drehzahl"
  elseif motors and armed and allZero then
    hint = "Keine Drehzahl: bidir. DShot an?"
  elseif tel.connected and not motors then
    hint = "warte auf Daten..."
  end
  if hint then
    text(cx, y + 177, hint, fitFont(hint, w - 12, { SMLSIZE, TINSIZE }) + VCENTER + CENTER + C.label)
  end
end

local function drawLink(r, tel)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  panel(r, "FUNK", ICONS.signal)
  local live = tel.connected
  local lq = live and tel.lq or nil

  local level, color = 0, C.gray
  if lq then
    level = (lq >= 95 and 5) or (lq >= 80 and 4) or (lq >= 60 and 3) or (lq >= 40 and 2) or (lq > 0 and 1) or 0
    color = (lq >= 80 and C.green) or (lq >= 50 and C.yellow) or C.red
  end
  for i = 0, 4 do
    local bh = 10 + i * 7
    rect(x + 12 + i * 13, y + 76 - bh, 9, bh, (i < level) and color or C.segOff)
  end
  text(x + w - 10, y + 58, lq and (int(lq) .. "%") or "--", MIDSIZE + VCENTER + RIGHT + (lq and C.white or C.label))

  local function val(v, unit)
    if not live or v == nil then return "--" end
    return int(v) .. unit
  end
  row(r, 92, "Signal", (live and tel.rssi) and (int(tel.rssi) .. " dBm") or "--")
  row(r, 112, "SNR", val(tel.snr, " dB"))
  row(r, 132, "Rate", (live and tel.rate) and (tel.rate .. " Hz") or "--")
  row(r, 152, "Leistung", val(tel.power, " mW"))
  row(r, 172, "Rückkanal", val(tel.tlq, " %"))
end

local function drawHorizon(cx, cy, r, pitchDeg, rollDeg)
  circle(cx, cy, r, C.sky)
  -- Betaflight: positiver Nickwinkel = Nase nach unten
  local noseUp = -(pitchDeg or 0)
  local ang = math.rad(-(rollDeg or 0))
  local dx, dy = math.cos(ang), math.sin(ang)
  local nx, ny = -dy, dx
  local off = math.max(-r * 1.5, math.min(r * 1.5, noseUp * r / 40))

  -- Erd-Flaeche: Kreis an der Horizontlinie abschneiden, als Faecher fuellen
  local pts = {}
  local n = #CIRCLE
  local px, py = CIRCLE[n][1] * r, CIRCLE[n][2] * r
  local pd = px * nx + py * ny - off
  for i = 1, n do
    local qx, qy = CIRCLE[i][1] * r, CIRCLE[i][2] * r
    local qd = qx * nx + qy * ny - off
    if qd >= 0 then
      if pd < 0 then
        local k = pd / (pd - qd)
        pts[#pts + 1] = { px + (qx - px) * k, py + (qy - py) * k }
      end
      pts[#pts + 1] = { qx, qy }
    elseif pd >= 0 then
      local k = pd / (pd - qd)
      pts[#pts + 1] = { px + (qx - px) * k, py + (qy - py) * k }
    end
    px, py, pd = qx, qy, qd
  end
  for i = 2, #pts - 1 do
    tri(cx + pts[1][1], cy + pts[1][2], cx + pts[i][1], cy + pts[i][2],
      cx + pts[i + 1][1], cy + pts[i + 1][2], C.earth)
  end
  if math.abs(off) < r then
    local half = math.sqrt(r * r - off * off)
    local mx, my = cx + nx * off, cy + ny * off
    lcd.drawLine(floor(mx - dx * half + 0.5), floor(my - dy * half + 0.5),
      floor(mx + dx * half + 0.5), floor(my + dy * half + 0.5), SOLID, C.white)
  end
  -- feste Drohnen-Markierung
  rect(cx - 22, cy - 1, 15, 3, C.yellow)
  rect(cx + 8, cy - 1, 15, 3, C.yellow)
  circle(cx, cy, 3, C.yellow)
end

local function drawAttitude(r, tel)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  panel(r, "LAGE & HÖHE")
  local live = tel.connected

  drawHorizon(x + 46, y + 76, 34, live and tel.pitch or 0, live and tel.roll or 0)

  text(x + w - 10, y + 46, "Höhe", SMLSIZE + VCENTER + RIGHT + C.label)
  text(x + w - 10, y + 70, (live and tel.alt) and (dec(tel.alt, 1) .. " m") or "--",
    BOLD + VCENTER + RIGHT + C.white)
  if live and tel.vspd then
    local v = tel.vspd
    local s = dec(math.abs(v), 1) .. " m/s"
    local col = C.label
    local ax = x + w - 18 - textW(s, SMLSIZE)
    if v > 0.2 then
      col = C.green
      tri(ax - 6, y + 87, ax - 12, y + 99, ax, y + 99, col)
    elseif v < -0.2 then
      col = C.orange
      tri(ax - 12, y + 89, ax, y + 89, ax - 6, y + 101, col)
    end
    text(x + w - 10, y + 94, s, SMLSIZE + VCENTER + RIGHT + col)
  end

  local pitch, roll, yaw = tel.pitch, tel.roll, tel.yaw
  local ptxt, rtxt, ytxt = "--", "--", "--"
  if live and pitch then
    ptxt = int(math.abs(pitch)) .. "° " .. ((pitch >= 0) and "vorn" or "hinten")
  end
  if live and roll then
    rtxt = int(math.abs(roll)) .. "° " .. ((roll >= 0) and "rechts" or "links")
  end
  if live and yaw then
    ytxt = int(yaw) .. "° " .. COMPASS[floor((yaw + 22.5) / 45) % 8 + 1]
  end
  row(r, 128, "Neigung", ptxt)
  row(r, 149, "Rollen", rtxt)
  row(r, 170, "Kurs", ytxt)
end

local function drawGps(r, tel)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  panel(r, "GPS", ICONS.sat)
  local live = tel.connected
  local sats = tel.sats
  -- Betaflight schickt GPS-Rahmen erst, wenn das GPS-Modul Daten liefert;
  -- ohne sie legt EdgeTX die Sensoren "GPS"/"Sats" gar nicht an.
  local noGpsData = tel.everConnected and not tel.has.sats and not tel.has.gps

  if live then
    if noGpsData then
      titleRight(r, "fehlt", C.red)
    elseif tel.fix and (sats or 0) >= 8 then
      titleRight(r, "gut", C.green)
    elseif tel.fix then
      titleRight(r, "schwach", C.yellow)
    else
      titleRight(r, "sucht...", C.yellow)
    end
  elseif tel.lat then
    titleRight(r, "letzte Pos.", C.yellow)
  end

  local satText = (live and sats) and int(sats) or "--"
  text(x + 12, y + 62, satText, DBLSIZE + VCENTER + (live and C.white or C.label))
  text(x + 20 + textW(satText, DBLSIZE), y + 62, "Satelliten", SMLSIZE + VCENTER + C.label)

  if live and noGpsData then
    text(x + w / 2, y + 112, "Keine GPS-Daten", BOLD + VCENTER + CENTER + C.red)
    text(x + w / 2, y + 140, "Betaflight: GPS an?", SMLSIZE + VCENTER + CENTER + C.label)
    text(x + w / 2, y + 162, "Sensoren neu suchen", SMLSIZE + VCENTER + CENTER + C.label)
    return
  end

  row(r, 101, "Tempo", (live and tel.speed) and (int(tel.speed) .. " km/h") or "--")
  row(r, 122, "Entfernung", (live and tel.dist) and fmtDistance(tel.dist) or "--")
  row(r, 143, "GPS-Höhe", (live and tel.galt) and (int(tel.galt) .. " m") or "--")
  if tel.lat and tel.lon then
    local pos = string.format("%.5f  %.5f", tel.lat, tel.lon)
    text(x + w / 2, y + 171, pos, fitFont(pos, w - 10, { SMLSIZE, TINSIZE }) + VCENTER + CENTER
      + (live and C.label or C.yellow))
  end
end

local function drawFooter(r, link)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  panel(r)
  local cy = y + h / 2

  local left = ""
  local dt = getDateTime and getDateTime()
  if dt and dt.year then
    left = string.format("%s %02d.%02d.%04d  %02d:%02d", WEEKDAYS[weekday(dt.year, dt.mon, dt.day) + 1],
      dt.day, dt.mon, dt.year, dt.hour, dt.min)
  end
  text(x + 10, cy, left, SMLSIZE + VCENTER + C.label)

  local etx = getVersion and getVersion() or "?"
  local tx = link.tx and link.tx.text or "?"
  local rx = link.rx and link.rx.text or "?"
  local fc = link.fcVersion or "?"
  local maxW = w - 30 - textW(left, SMLSIZE)
  local right = "EdgeTX " .. etx .. "   |   ELRS Funke " .. tx .. "  Drohne " .. rx .. "   |   Betaflight " .. fc
  if textW(right, SMLSIZE) > maxW then
    right = "EdgeTX " .. etx .. " | ELRS " .. tx .. " / " .. rx .. " | BF " .. fc
  end
  text(x + w - 10, cy, right, fitFont(right, maxW, { SMLSIZE, TINSIZE }) + VCENTER + RIGHT + C.label)
end

-- Fenster mit QR-Code der (letzten) GPS-Position.
-- p: Momentaufnahme aus main.lua (lat, lon, alt, sats, time, dist, live, job)
local function drawPopup(r, p)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  rect(x, y, w, h, C.popup)
  frame(x, y, w, h, C.white, 2)
  local closeHint = "Antippen zum Schließen"

  if not p.lat then
    text(x + w / 2, y + h / 2 - 24, "Noch keine GPS-Position bekannt", MIDSIZE + VCENTER + CENTER + C.white)
    text(x + w / 2, y + h / 2 + 16, "Die Drohne braucht zuerst einen GPS-Fix.", SMLSIZE + VCENTER + CENTER + C.label)
    text(x + w / 2, y + h - 22, closeHint, SMLSIZE + VCENTER + CENTER + C.label)
    return
  end

  -- QR-Code auf weissem Grund (mit Ruhezone von 4 Modulen)
  local qs = h - 32
  local qx, qy = x + 16, y + 16
  rect(qx, qy, qs, qs, C.white)
  local job = p.job
  if job and job.result then
    local q = job.result
    local m = floor(qs / (q.size + 8))
    local ox = qx + floor((qs - m * q.size) / 2)
    local oy = qy + floor((qs - m * q.size) / 2)
    local runs = q.runs
    for i = 1, #runs, 3 do
      lcd.drawFilledRectangle(ox + runs[i] * m, oy + runs[i + 1] * m, runs[i + 2] * m, m, C.black)
    end
  elseif job and job.err then
    text(qx + qs / 2, qy + qs / 2, "QR-Fehler", BOLD + VCENTER + CENTER + C.red)
  else
    text(qx + qs / 2, qy + qs / 2, "QR wird erstellt...", BOLD + VCENTER + CENTER + C.black)
  end

  -- rechts: Klartext
  local tx = qx + qs + 24
  local tw = x + w - 16 - tx
  local title = p.live and "AKTUELLE POSITION" or "LETZTE POSITION"
  text(tx, y + 34, title, fitFont(title, tw, { MIDSIZE, BOLD }) + VCENTER + (p.live and C.green or C.yellow))
  text(tx, y + 84, string.format("%.6f", p.lat), DBLSIZE + VCENTER + C.white)
  text(tx, y + 134, string.format("%.6f", p.lon), DBLSIZE + VCENTER + C.white)

  local rr = { tx - 10, y, tw + 20, h }
  row(rr, 182, "Stand", p.time or "--")
  row(rr, 206, "Höhe (GPS)", p.alt and (int(p.alt) .. " m") or "--")
  row(rr, 230, "Satelliten", p.sats and int(p.sats) or "--")
  row(rr, 254, "Entfernung zum Start", p.dist and fmtDistance(p.dist) or "--")

  text(tx, y + 298, "Mit der Handy-Kamera scannen", BOLD + VCENTER + C.white)
  text(tx, y + 324, "öffnet die Karten-App (Android)", SMLSIZE + VCENTER + C.label)
  text(x + w - 16, y + h - 20, closeHint, SMLSIZE + VCENTER + RIGHT + C.label)
end

-------------------------------------------------------------------------------

-- Feld-Rechtecke in Bildschirmkoordinaten, nur bei geaenderter Zone neu.
local rectCache, cacheX, cacheY, cacheW, cacheH

local function rectsFor(zone)
  if zone.x ~= cacheX or zone.y ~= cacheY or zone.w ~= cacheW or zone.h ~= cacheH then
    local ox = zone.x + floor((zone.w - DESIGN_W) / 2)
    local oy = zone.y + floor((zone.h - DESIGN_H) / 2)
    rectCache = {}
    for name, r in pairs(L) do
      rectCache[name] = { ox + r[1], oy + r[2], r[3], r[4] }
    end
    cacheX, cacheY, cacheW, cacheH = zone.x, zone.y, zone.w, zone.h
  end
  return rectCache
end

-- Liegt der Punkt (x, y) auf der GPS-Kachel?
function M.gpsHit(zone, x, y)
  local r = rectsFor(zone).gps
  return x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4]
end

-- popup: nil oder Momentaufnahme fuer das QR-Fenster
function M.draw(zone, tel, link, motorMode, now, popup, interactive)
  if not C then initColors() end
  if not ICONS then loadIcons() end

  if zone.w < DESIGN_W - 20 or zone.h < DESIGN_H - 20 then
    rect(zone.x, zone.y, zone.w, zone.h, C.black)
    text(zone.x + 6, zone.y + 6, "Vapor Dashboard: bitte im App-Modus", SMLSIZE + C.white)
    text(zone.x + 6, zone.y + 28, "(Vollbild 800x480) verwenden", SMLSIZE + C.white)
    return
  end

  local R = rectsFor(zone)
  drawBackground(zone.x, zone.y, zone.w, zone.h)
  drawHeader(R.header, tel, interactive)
  if popup then
    -- Kacheln unter dem Fenster nicht zeichnen: spart Rechenzeit fuer den QR-Code
    drawPopup(R.popup, popup)
  else
    drawBattery(R.batt, tel, now)
    drawArm(R.arm, tel, link, now)
    drawTime(R.time, tel)
    drawMotors(R.motors, tel, link, motorMode)
    drawLink(R.link, tel)
    drawAttitude(R.att, tel)
    drawGps(R.gps, tel)
  end
  drawFooter(R.footer, link)
end

return M
