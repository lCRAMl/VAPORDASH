-- Draws the Vapor-D5 dashboard.
-- Designed for 800x480 (RadioMaster TX16S MK3) in App mode (full screen).
-- Font sizes at 800x480: TINSIZE 12, SMLSIZE 18, STD/BOLD 22,
-- MIDSIZE 33, DBLSIZE 44 bold, XLSIZE 66 bold, XXLSIZE 88 bold.

local M = {}

local ICON_DIR = "/WIDGETS/VAPORDASH/icons/"
-- Background image at display size (800x480); if it is missing, a gradient is drawn.
local BACKGROUND_IMAGE = "/WIDGETS/VAPORDASH/images/background.png"
local floor = math.floor

-- Areas {x, y, w, h} relative to the zone. The top left is kept free for
-- the EdgeTX button that the system draws itself in App mode.
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
  popup  = { 4, 64, 792, 384 },   -- QR popup above all tiles
}
local DESIGN_W, DESIGN_H = 800, 480

-- Betaflight Quad-X: motor 1 rear right, 2 front right,
-- 3 rear left, 4 front left. {right(+1)/left(-1), rear(+1)/front(-1)}
local MOTOR_POS = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

-- Reasons for blocked arming (Betaflight 2026.6, fc/runtime_config.h),
-- bit number -> short text. Order = importance.
local ARM_REASONS = {
  [0] = "No gyro sensor",
  [1] = "Failsafe active",
  [2] = "No RX signal",
  [3] = "Arm switch off first",
  [4] = "Failsafe switch on",
  [5] = "Runaway takeoff",
  [6] = "Crash detected",
  [7] = "Throttle not low",
  [8] = "Drone tilted too far",
  [9] = "Still booting - wait",
  [10] = "Prearm switch missing",
  [11] = "CPU overloaded",
  [12] = "Calibrating - hold still",
  [13] = "CLI open on PC",
  [14] = "OSD menu open",
  [15] = "BST active",
  [16] = "Connected to PC",
  [17] = "Paralyze active",
  [18] = "Waiting for GPS",
  [19] = "Rescue switch on",
  [20] = "Motor telemetry missing",
  [21] = "Reboot required",
  [22] = "DShot error",
  [23] = "Calibrate accelerometer",
  [24] = "Motor protocol missing",
  [25] = "Turtle switch on",
  [26] = "Alt hold switch on",
  [27] = "Pos hold switch on",
  [28] = "Autopilot switch on",
  [29] = "Arm switch off first",
}
local ARM_SWITCH_BIT = 29

local MODE_NAMES = {
  ACRO = "Acro", AIR = "Acro (Airmode)", ANGL = "Angle (self-level)",
  STAB = "Stabilized", HOR = "Horizon", RTH = "GPS Rescue",
  ALTH = "Altitude hold", POSH = "Position hold", PHFL = "Pos hold failed",
  PASS = "Passthrough", MANU = "Manual", CHIR = "Chirp test",
  WAIT = "Waiting for GPS", ["!FS!"] = "Failsafe", ["!ERR"] = "Error",
}

local COMPASS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

-- Unit circle for the artificial horizon
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
  -- Background: vertical gradient dark blue -> almost black
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
  -- Bitmap.open returns an (empty) object even if the file is missing or
  -- memory is short; only getSize shows whether the image really loaded.
  local bmp = Bitmap.open(BACKGROUND_IMAGE)
  local w = (bmp and Bitmap.getSize) and Bitmap.getSize(bmp) or 0
  BG_IMAGE = (w and w > 0) and bmp or nil
end

-------------------------------------------------------------------------------
-- Drawing primitives (EdgeTX requires integer coordinates)
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

-- First font from the list in which the text fits into maxW.
local function fitFont(s, maxW, fonts)
  for i = 1, #fonts do
    if textW(s, fonts[i]) <= maxW then return fonts[i] end
  end
  return fonts[#fonts]
end

-- White text with a black outline (easy to read on coloured areas).
local function outlined(x, y, s, flags, color)
  text(x - 2, y - 2, s, flags + C.black)
  text(x + 2, y - 2, s, flags + C.black)
  text(x - 2, y + 2, s, flags + C.black)
  text(x + 2, y + 2, s, flags + C.black)
  text(x, y, s, flags + color)
end

-- Tile: transparent, just a thin frame over the background image.
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
-- Formatting
-- Note: in the EdgeTX widget environment strings have no methods,
-- so always write string.xxx(s, ...) instead of s:xxx(...).
-------------------------------------------------------------------------------

local function dec(v, digits)
  return string.format("%." .. digits .. "f", v)
end

local function int(v)
  return tostring(floor(v + 0.5))
end

local function thousands(n)
  local s = string.reverse(int(n))
  s = string.gsub(s, "(%d%d%d)", "%1,")
  s = string.reverse(s)
  if string.sub(s, 1, 1) == "," then s = string.sub(s, 2) end
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

-- Most important reason for blocked arming + number of further reasons.
-- EdgeTX Lua uses 32-bit integers and single-precision floats:
-- so test bits with integer operators, not by division.
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
  return ARM_REASONS[first] or ("Reason " .. first), count - 1
end

-------------------------------------------------------------------------------
-- Tiles
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

-- interactive == false: EdgeTX sends no touch events (not full screen)
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

  -- right: radio battery
  local xr = x + w - 12
  local tx = tel.txVolt and (dec(tel.txVolt, 1) .. " V") or "--"
  text(xr, cy, tx, BOLD + VCENTER + RIGHT + (tel.txLow and C.red or C.white))
  xr = xr - textW(tx, BOLD) - 10
  drawMiniBattery(xr - 31, cy - 8, 28, 16, tel.txPct, tel.txLow)
  xr = xr - 41
  text(xr, cy, "Radio", SMLSIZE + VCENTER + RIGHT + C.label)
  xr = xr - textW("Radio", SMLSIZE) - 16
  rect(xr, y + 12, 1, h - 24, C.dim)
  xr = xr - 16

  -- Link
  local label, color, bmp
  if tel.connected then
    local lq = tel.lq or 0
    if lq >= 80 then
      label, color, bmp = "Connected", C.green, ICONS["connection-ok"]
    elseif lq >= 50 then
      label, color, bmp = "Weak signal", C.yellow, ICONS["connection-warn"]
    else
      label, color, bmp = "Very weak signal", C.red, ICONS["connection-low"]
    end
  elseif tel.arm == "lost" then
    label, color, bmp = "Link lost!", C.red, ICONS["connection-dead"]
  else
    label, color, bmp = "No link", C.gray, ICONS["connection-dead"]
  end
  text(xr, cy, label, BOLD + VCENTER + RIGHT + color)
  xr = xr - textW(label, BOLD) - 8
  icon(bmp, xr - 30, cy - 15)

  -- Hint between name and link: touch only works after a long press
  if interactive == false then
    local l1, l2 = "For touch:", "long-press"
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
  panel(r, "DRONE BATTERY", ICONS.battery)

  local live = tel.connected
  local pct = tel.everConnected and tel.pct or nil
  local col = pct and batteryColor(pct) or C.gray
  if not live then col = C.gray end

  local landNow = live and pct and pct < 25
  if landNow then
    if blinkOn(now) then titleRight(r, "LAND!", C.red) end
  elseif tel.cellCount then
    titleRight(r, tel.cellCount .. "S", C.label)
  end

  -- Battery symbol with 10 segments
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

  -- Values below
  local vc = live and C.white or C.label
  local r1, r2 = y + 134, y + 166
  text(x + 10, r1, tel.volt and (dec(tel.volt, 1) .. " V") or "-- V", BOLD + VCENTER + vc)
  local cell = tel.cellVolt and (dec(tel.cellVolt, 2) .. " V per cell") or "-- V per cell"
  text(x + w - 10, r1, cell, SMLSIZE + VCENTER + RIGHT + C.label)

  local curr = tel.curr and (dec(tel.curr, 1) .. " A") or "-- A"
  text(x + 10, r2, curr, BOLD + VCENTER + vc)
  local capa = tel.capa and (int(tel.capa) .. " mAh") or "-- mAh"
  text(x + w - 10, r2, capa, BOLD + VCENTER + RIGHT + vc)
  -- Space between current (left) and mAh (right), 6 px gap each
  local free = w - 32 - textW(curr, BOLD) - textW(capa, BOLD)
  for _, word in ipairs({ "consumed", "used" }) do
    if textW(word, SMLSIZE) <= free then
      text(x + w - 16 - textW(capa, BOLD), r2, word, SMLSIZE + VCENTER + RIGHT + C.label)
      break
    end
  end
end

local STATES = {
  safe     = { "DISARMED", "Motors off", "green" },
  armed    = { "ARMED", "Motors on - keep clear!", "red" },
  locked   = { "BLOCKED", "Arming not possible", "orange" },
  failsafe = { "FAILSAFE", "Signal lost!", "red", true },
  lost     = { "LINK LOST!", "Drone was armed!", "red", true },
  offline  = { "NO SIGNAL", "Drone off or out of range", "gray" },
  unknown  = { "STATUS ?", "Flight mode missing", "gray" },
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

  -- below: flight mode or reason for blocking
  local label, value, vcolor = nil, nil, C.white
  if tel.arm == "locked" then
    label = "Reason"
    if link.armingFlags then
      local reason, more = armReason(link.armingFlags)
      value = reason or "unknown"
      if more > 0 then value = value .. " (+" .. more .. ")" end
    else
      value = "requesting..."
      vcolor = C.label
    end
    vcolor = link.armingFlags and C.orange or vcolor
  elseif tel.arm == "offline" then
    label, value, vcolor = "Tip", "Plug in drone battery", C.label
  elseif tel.arm == "lost" then
    label, value, vcolor = "Tip", "Last position: GPS tile", C.yellow
  elseif tel.arm == "unknown" then
    label, value, vcolor = "Tip", "Betaflight: telemetry on?", C.label
  elseif tel.gpsWait and tel.arm == "safe" then
    label, value, vcolor = "Note", "GPS not ready yet", C.yellow
  else
    label = "Flight mode"
    value = MODE_NAMES[tel.mode or ""] or tel.mode or "--"
  end
  text(x + w / 2, y + 144, label, SMLSIZE + VCENTER + CENTER + C.label)
  text(x + w / 2, y + 172, value, fitFont(value, w - 16, { MIDSIZE, BOLD, SMLSIZE }) + VCENTER + CENTER + vcolor)
end

local function drawTime(r, tel)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  panel(r, "FLIGHT TIME", ICONS.clock)
  local sec = tel.flightSec or 0
  if tel.timerRunning then
    titleRight(r, "running", C.green)
    circle(x + w - 20 - textW("running", SMLSIZE), y + 17, 5, C.green)
  elseif sec > 0 then
    titleRight(r, "paused", C.label)
  end

  local s = fmtTime(sec)
  local f = fitFont(s, w - 12, { XXLSIZE, XLSIZE, DBLSIZE })
  text(x + w / 2, y + 108, s, f + VCENTER + CENTER + C.white)

  if sec == 0 and not tel.timerRunning then
    local hint = "starts when armed"
    text(x + w / 2, y + 174, hint, fitFont(hint, w - 12, { SMLSIZE, TINSIZE }) + VCENTER + CENTER + C.label)
  end
end

local function drawMotors(r, tel, link, motorMode)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  panel(r, "MOTORS", ICONS.drone)
  titleRight(r, "RPM", C.label)

  local cx, cy, d = x + w / 2, y + 118, 30
  text(cx, y + 46, "front", SMLSIZE + VCENTER + CENTER + C.yellow)

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

  -- invalid = 10000: bidirectional DShot is on, but the ESC doesn't reply
  -- (e.g. stock BLHeli_S without Bluejay).
  local hint
  if motorMode == "off" then
    hint = "Polling turned off"
  elseif allInvalid then
    hint = "ESC sends no RPM"
  elseif motors and armed and allZero then
    hint = "No RPM: bidir. DShot on?"
  elseif tel.connected and not motors then
    hint = "waiting for data..."
  end
  if hint then
    text(cx, y + 177, hint, fitFont(hint, w - 12, { SMLSIZE, TINSIZE }) + VCENTER + CENTER + C.label)
  end
end

local function drawLink(r, tel)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  panel(r, "LINK", ICONS.signal)
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
  row(r, 152, "Power", val(tel.power, " mW"))
  row(r, 172, "Downlink", val(tel.tlq, " %"))
end

local function drawHorizon(cx, cy, r, pitchDeg, rollDeg)
  circle(cx, cy, r, C.sky)
  -- Betaflight: positive pitch angle = nose down
  local noseUp = -(pitchDeg or 0)
  local ang = math.rad(-(rollDeg or 0))
  local dx, dy = math.cos(ang), math.sin(ang)
  local nx, ny = -dy, dx
  local off = math.max(-r * 1.5, math.min(r * 1.5, noseUp * r / 40))

  -- Ground area: clip the circle at the horizon line, fill as a fan
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
  -- fixed drone marker
  rect(cx - 22, cy - 1, 15, 3, C.yellow)
  rect(cx + 8, cy - 1, 15, 3, C.yellow)
  circle(cx, cy, 3, C.yellow)
end

local function drawAttitude(r, tel)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  panel(r, "ATTITUDE & ALT.")
  local live = tel.connected

  drawHorizon(x + 46, y + 76, 34, live and tel.pitch or 0, live and tel.roll or 0)

  text(x + w - 10, y + 46, "Altitude", SMLSIZE + VCENTER + RIGHT + C.label)
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
    ptxt = int(math.abs(pitch)) .. "° " .. ((pitch >= 0) and "fwd" or "back")
  end
  if live and roll then
    rtxt = int(math.abs(roll)) .. "° " .. ((roll >= 0) and "right" or "left")
  end
  if live and yaw then
    ytxt = int(yaw) .. "° " .. COMPASS[floor((yaw + 22.5) / 45) % 8 + 1]
  end
  row(r, 128, "Pitch", ptxt)
  row(r, 149, "Roll", rtxt)
  row(r, 170, "Heading", ytxt)
end

local function drawGps(r, tel)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  panel(r, "GPS", ICONS.sat)
  local live = tel.connected
  local sats = tel.sats
  -- Betaflight only sends GPS frames once the GPS module delivers data;
  -- without them EdgeTX doesn't create the "GPS"/"Sats" sensors at all.
  local noGpsData = tel.everConnected and not tel.has.sats and not tel.has.gps

  if live then
    if noGpsData then
      titleRight(r, "missing", C.red)
    elseif tel.fix and (sats or 0) >= 8 then
      titleRight(r, "good", C.green)
    elseif tel.fix then
      titleRight(r, "weak", C.yellow)
    else
      titleRight(r, "no fix yet", C.yellow)
    end
  elseif tel.lat then
    titleRight(r, "last pos.", C.yellow)
  end

  local satText = (live and sats) and int(sats) or "--"
  text(x + 12, y + 62, satText, DBLSIZE + VCENTER + (live and C.white or C.label))
  text(x + 20 + textW(satText, DBLSIZE), y + 62, "satellites", SMLSIZE + VCENTER + C.label)

  if live and noGpsData then
    text(x + w / 2, y + 112, "No GPS data", BOLD + VCENTER + CENTER + C.red)
    text(x + w / 2, y + 140, "Betaflight: GPS on?", SMLSIZE + VCENTER + CENTER + C.label)
    text(x + w / 2, y + 162, "Re-discover sensors", SMLSIZE + VCENTER + CENTER + C.label)
    return
  end

  row(r, 101, "Speed", (live and tel.speed) and (int(tel.speed) .. " km/h") or "--")
  row(r, 122, "Distance", (live and tel.dist) and fmtDistance(tel.dist) or "--")
  row(r, 143, "GPS alt.", (live and tel.galt) and (int(tel.galt) .. " m") or "--")
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
    left = string.format("%s %04d-%02d-%02d  %02d:%02d", WEEKDAYS[weekday(dt.year, dt.mon, dt.day) + 1],
      dt.year, dt.mon, dt.day, dt.hour, dt.min)
  end
  text(x + 10, cy, left, SMLSIZE + VCENTER + C.label)

  local etx = getVersion and getVersion() or "?"
  local tx = link.tx and link.tx.text or "?"
  local rx = link.rx and link.rx.text or "?"
  local fc = link.fcVersion or "?"
  local maxW = w - 30 - textW(left, SMLSIZE)
  local right = "EdgeTX " .. etx .. "   |   ELRS radio " .. tx .. "  drone " .. rx .. "   |   Betaflight " .. fc
  if textW(right, SMLSIZE) > maxW then
    right = "EdgeTX " .. etx .. " | ELRS " .. tx .. " / " .. rx .. " | BF " .. fc
  end
  text(x + w - 10, cy, right, fitFont(right, maxW, { SMLSIZE, TINSIZE }) + VCENTER + RIGHT + C.label)
end

-- Popup with a QR code of the (last) GPS position.
-- p: snapshot from main.lua (lat, lon, alt, sats, time, dist, live, job)
local function drawPopup(r, p)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  rect(x, y, w, h, C.popup)
  frame(x, y, w, h, C.white, 2)
  local closeHint = "Tap to close"

  if not p.lat then
    text(x + w / 2, y + h / 2 - 24, "No GPS position known yet", MIDSIZE + VCENTER + CENTER + C.white)
    text(x + w / 2, y + h / 2 + 16, "The drone needs a GPS fix first.", SMLSIZE + VCENTER + CENTER + C.label)
    text(x + w / 2, y + h - 22, closeHint, SMLSIZE + VCENTER + CENTER + C.label)
    return
  end

  -- QR code on a white background (with a quiet zone of 4 modules)
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
    text(qx + qs / 2, qy + qs / 2, "QR error", BOLD + VCENTER + CENTER + C.red)
  else
    text(qx + qs / 2, qy + qs / 2, "Creating QR...", BOLD + VCENTER + CENTER + C.black)
  end

  -- right: plain text
  local tx = qx + qs + 24
  local tw = x + w - 16 - tx
  local title = p.live and "CURRENT POSITION" or "LAST POSITION"
  text(tx, y + 34, title, fitFont(title, tw, { MIDSIZE, BOLD }) + VCENTER + (p.live and C.green or C.yellow))
  text(tx, y + 84, string.format("%.6f", p.lat), DBLSIZE + VCENTER + C.white)
  text(tx, y + 134, string.format("%.6f", p.lon), DBLSIZE + VCENTER + C.white)

  local rr = { tx - 10, y, tw + 20, h }
  row(rr, 182, "Time", p.time or "--")
  row(rr, 206, "Altitude (GPS)", p.alt and (int(p.alt) .. " m") or "--")
  row(rr, 230, "Satellites", p.sats and int(p.sats) or "--")
  row(rr, 254, "Distance from home", p.dist and fmtDistance(p.dist) or "--")

  text(tx, y + 298, "Scan with your phone camera", BOLD + VCENTER + C.white)
  text(tx, y + 324, "opens the maps app (Android)", SMLSIZE + VCENTER + C.label)
  text(x + w - 16, y + h - 20, closeHint, SMLSIZE + VCENTER + RIGHT + C.label)
end

-------------------------------------------------------------------------------

-- Tile rectangles in screen coordinates, only recomputed when the zone changes.
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

-- Is the point (x, y) on the GPS tile?
function M.gpsHit(zone, x, y)
  local r = rectsFor(zone).gps
  return x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4]
end

-- popup: nil or snapshot for the QR popup
function M.draw(zone, tel, link, motorMode, now, popup, interactive)
  if not C then initColors() end
  if not ICONS then loadIcons() end

  if zone.w < DESIGN_W - 20 or zone.h < DESIGN_H - 20 then
    rect(zone.x, zone.y, zone.w, zone.h, C.black)
    text(zone.x + 6, zone.y + 6, "Vapor Dashboard: please use", SMLSIZE + C.white)
    text(zone.x + 6, zone.y + 28, "App mode (full screen 800x480)", SMLSIZE + C.white)
    return
  end

  local R = rectsFor(zone)
  drawBackground(zone.x, zone.y, zone.w, zone.h)
  drawHeader(R.header, tel, interactive)
  if popup then
    -- Don't draw the tiles under the popup: saves CPU time for the QR code
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
