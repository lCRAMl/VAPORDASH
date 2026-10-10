-- Reads the drone's telemetry (ELRS/CRSF + Betaflight) and derives the
-- display states from it: link, armed/disarmed, flight time, battery,
-- attitude, GPS home point and link values.

local M = {}

-- EdgeTX sensor names of the CRSF telemetry (EdgeTX 2.12, telemetry/crossfire.cpp).
local SENSORS = {
  volt = "RxBt", curr = "Curr", capa = "Capa", pct = "Bat%",
  fm = "FM",
  pitch = "Ptch", roll = "Roll", yaw = "Yaw",
  alt = "Alt", vspd = "VSpd",
  gps = "GPS", speed = "GSpd", galt = "GAlt", sats = "Sats",
  rss1 = "1RSS", rss2 = "2RSS", rqly = "RQly", rsnr = "RSNR", ant = "ANT",
  rfmd = "RFMD", tpwr = "TPWR", trss = "TRSS", tqly = "TQly", tsnr = "TSNR",
}

local RESCAN_TICKS = 200     -- look for missing sensors again every 2 s
local NEW_PACK_GAP = 300     -- at least 3 s without link (disarmed) = battery swap
local CAPA_DROP = 20         -- mAh counter drops => FC restarted = new battery
local RAD_TO_DEG = 180 / math.pi

local LASTPOS_FILE = "/WIDGETS/VAPORDASH/lastpos.txt"
local SAVE_INTERVAL = 500    -- save the position at most every 5 s ...
local SAVE_MIN_MOVE = 3      -- ... and only if it moved by 3 m

-- RFMD is the raw ELRS enum value (expresslrs_RFrates_e). It changed
-- between ELRS 3.x and 4.x; both tables come from src/include/common.h
-- of the tags 3.6.3 and 4.1.0.
local RATE_3X = {
  [0] = 4, [1] = 25, [2] = 50, [3] = 100, [4] = 100, [5] = 150, [6] = 200,
  [7] = 250, [8] = 333, [9] = 500, [10] = 250, [11] = 500, [12] = 500,
  [13] = 1000, [14] = 50, [15] = 200, [16] = 500, [17] = 1000, [18] = 1000,
  [19] = 1000,
}
local RATE_4X = {
  [0] = 25, [1] = 50, [2] = 100, [3] = 100, [4] = 150, [5] = 200, [6] = 200,
  [7] = 250, [8] = 333, [9] = 500, [10] = 50, [11] = 1000,
  [20] = 25, [21] = 50, [22] = 100, [23] = 100, [24] = 150, [25] = 200,
  [26] = 200, [27] = 250, [28] = 333, [29] = 500, [30] = 250, [31] = 500,
  [32] = 500, [33] = 1000, [34] = 250, [35] = 500, [36] = 1000,
  [100] = 100, [101] = 150,
}

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Resting voltage per cell -> rough remaining charge, only if "Bat%" is missing.
local function cellVoltToPct(v)
  return clamp(math.floor((v - 3.5) / 0.7 * 100 + 0.5), 0, 100)
end

local function distance(lat1, lon1, lat2, lon2)
  local rad = math.pi / 180
  local dLat = (lat2 - lat1) * rad
  local dLon = (lon2 - lon1) * rad
  local a = math.sin(dLat / 2) ^ 2
    + math.cos(lat1 * rad) * math.cos(lat2 * rad) * math.sin(dLon / 2) ^ 2
  return 2 * 6371000 * math.atan(math.sqrt(a), math.sqrt(1 - a))
end

-- Betaflight sends angles in radians; if a sensor was switched to degrees,
-- the value is already larger than 2*pi.
local function toDegrees(v)
  if v == nil then return nil end
  if math.abs(v) <= 6.3 then return v * RAD_TO_DEG end
  return v
end

function M.new()
  return {
    ids = {}, has = {}, v = {}, rescanAt = 0,
    connected = false, everConnected = false,
    lostAt = 0, lostWhileArmed = false,
    arm = "offline", mode = nil, gpsWait = false,
    flightTicks = 0, lastTick = nil, timerRunning = false,
    cells = nil, home = nil, lastCapa = nil,
    pack = 1,   -- incremented with every new battery
  }
end

local function resolveSensors(t, now)
  if now < t.rescanAt or not getFieldInfo then return end
  t.rescanAt = now + RESCAN_TICKS
  for key, name in pairs(SENSORS) do
    if not t.ids[key] then
      local info = getFieldInfo(name)
      if info and info.id then
        t.ids[key] = info.id
        t.has[key] = true
      end
    end
  end
end

local function readSensors(t)
  local v = t.v
  for key, id in pairs(t.ids) do
    local value = getValue(id)
    if key == "fm" then
      v.fm = (type(value) == "string") and value or nil
    elseif key == "gps" then
      v.gps = value
    else
      v[key] = (type(value) == "number") and value or nil
    end
  end
end

local function newPack(t)
  t.flightTicks = 0
  t.cells = nil
  t.home = nil
  t.pack = t.pack + 1
end

local function updateArmState(t)
  if not t.connected then
    t.arm = t.lostWhileArmed and "lost" or "offline"
    return
  end

  local fm = t.v.fm
  if not fm or fm == "" then
    t.arm = "unknown"
    t.mode = nil
    t.gpsWait = false
    return
  end

  -- Strings have no methods in the widget environment: use string.sub(fm, ...).
  if string.sub(fm, 1, 4) == "!FS!" then
    t.arm = "failsafe"
    t.mode = "!FS!"
    return
  end

  -- Betaflight appends to the flight mode: "*" = disarmed (ready to arm),
  -- "!" = arming blocked, "?" = disarmed, but GPS Rescue not ready.
  -- No character = armed (telemetry/crsf.c, crsfFrameFlightMode).
  local last = string.sub(fm, -1)
  local base = fm
  if last == "*" or last == "!" or last == "?" then
    base = string.sub(fm, 1, -2)
  end
  t.mode = base
  t.gpsWait = (last == "?") or base == "WAIT"

  if last == "!" or base == "!ERR" then
    t.arm = "locked"
  elseif last == "*" or last == "?" then
    t.arm = "safe"
  else
    t.arm = "armed"
  end
end

local function updateBattery(t, cellsOption)
  local v = t.v
  t.volt = v.volt
  t.curr = v.curr
  t.capa = v.capa

  local cells = (cellsOption and cellsOption > 0) and cellsOption or nil
  if not cells and t.volt and t.volt > 2 then
    -- Estimate the cell count from the voltage, never lower it during one battery.
    local n = math.ceil(t.volt / 4.35)
    if not t.cells or n > t.cells then t.cells = n end
    cells = t.cells
  end
  t.cellCount = cells
  t.cellVolt = (cells and t.volt and t.volt > 0) and (t.volt / cells) or nil

  if t.has.pct and v.pct then
    t.pct = clamp(math.floor(v.pct + 0.5), 0, 100)
  elseif t.cellVolt then
    t.pct = cellVoltToPct(t.cellVolt)
  else
    t.pct = nil
  end
end

-------------------------------------------------------------------------------
-- Last position on the SD card, so it survives a restart of the radio
-- (e.g. after a crash). Format: lat;lon;alt;time;sats
-------------------------------------------------------------------------------

local function dateTimeText()
  local dt = getDateTime and getDateTime()
  if not dt or not dt.year then return nil end
  return string.format("%04d-%02d-%02d %02d:%02d:%02d", dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec)
end

local function savePosition(t, now)
  if not (io and io.open) or not t.lat then return end
  local f = io.open(LASTPOS_FILE, "w")
  if not f then return end
  io.write(f, string.format("%.6f;%.6f;%s;%s;%s\n", t.lat, t.lon,
    t.posAlt and tostring(math.floor(t.posAlt + 0.5)) or "",
    t.posTime or "", t.posSats and tostring(math.floor(t.posSats)) or ""))
  io.close(f)
  t.savedLat, t.savedLon, t.savedAt = t.lat, t.lon, now
end

-- Call at startup: read the saved position back in.
function M.loadPosition(t)
  if not (io and io.open) then return end
  local f = io.open(LASTPOS_FILE, "r")
  if not f then return end
  local s = io.read(f, 200)
  io.close(f)
  if type(s) ~= "string" then return end
  local lat, lon, alt, when, sats = string.match(s, "^([%-%d%.]+);([%-%d%.]+);([%-%d]*);([^;]*);(%d*)")
  lat, lon = tonumber(lat), tonumber(lon)
  if not (lat and lon) then return end
  t.lat, t.lon = lat, lon
  t.posAlt = tonumber(alt)
  t.posTime = (when ~= "") and when or nil
  t.posSats = tonumber(sats)
  t.savedLat, t.savedLon, t.savedAt = lat, lon, 0
end

local function updateGps(t, justArmed, now)
  local v = t.v
  local g = v.gps
  if type(g) == "table" and type(g.lat) == "number" and type(g.lon) == "number"
      and (g.lat ~= 0 or g.lon ~= 0) then
    if g.lat ~= t.lat or g.lon ~= t.lon then
      t.lat, t.lon = g.lat, g.lon
      t.posAlt = v.galt
      t.posSats = v.sats
      t.posTime = dateTimeText()
    end
    if not t.savedLat
        or ((t.lat ~= t.savedLat or t.lon ~= t.savedLon)
          and now - t.savedAt >= SAVE_INTERVAL
          and distance(t.savedLat, t.savedLon, t.lat, t.lon) >= SAVE_MIN_MOVE) then
      savePosition(t, now)
    end
    t.fix = true
  else
    t.fix = false
  end
  t.sats = v.sats
  t.speed = v.speed
  t.galt = v.galt

  -- Home point: set when arming, before that use the first good fix.
  if t.fix and (justArmed or (not t.home and (t.sats or 0) >= 6)) then
    t.home = { lat = t.lat, lon = t.lon }
  end
  if t.home and t.lat then
    t.dist = distance(t.home.lat, t.home.lon, t.lat, t.lon)
  else
    t.dist = nil
  end
end

local function updateLink(t, elrsMajor)
  local v = t.v
  t.lq = v.rqly
  local r1, r2 = v.rss1, v.rss2
  if r1 and r1 ~= 0 and r2 and r2 ~= 0 then
    t.rssi = math.max(r1, r2)
  elseif r1 and r1 ~= 0 then
    t.rssi = r1
  elseif r2 and r2 ~= 0 then
    t.rssi = r2
  else
    t.rssi = nil
  end
  t.snr = v.rsnr
  t.power = v.tpwr
  t.tlq = v.tqly
  t.trss = v.trss
  t.tsnr = v.tsnr
  t.ant = v.ant

  t.rate = nil
  if v.rfmd and elrsMajor then
    local tbl = (elrsMajor >= 4) and RATE_4X or ((elrsMajor == 3) and RATE_3X or nil)
    t.rate = tbl and tbl[math.floor(v.rfmd)] or nil
  end
end

local function updateRadio(t)
  local tx = getValue and getValue("tx-voltage")
  t.txVolt = (type(tx) == "number" and tx > 0) and tx or nil
  if t.txVolt and not t.txRange and getGeneralSettings then
    local gs = getGeneralSettings()
    if gs and gs.battMin and gs.battMax and gs.battMax > gs.battMin then
      t.txRange = { min = gs.battMin, max = gs.battMax, warn = gs.battWarn or gs.battMin }
    end
  end
  if t.txVolt and t.txRange then
    local r = t.txRange
    t.txPct = clamp(math.floor((t.txVolt - r.min) / (r.max - r.min) * 100 + 0.5), 0, 100)
    t.txLow = t.txVolt <= r.warn
  else
    t.txPct = nil
    t.txLow = false
  end
end

-- Call once per refresh()/background().
-- now: getTime() (10 ms ticks); cellsOption: 0 = auto;
-- elrsMajor: ELRS major version of the TX module (for RFMD -> Hz) or nil.
function M.update(t, now, cellsOption, elrsMajor)
  resolveSensors(t, now)

  local rssi = getRSSI and getRSSI() or 0
  local connected = (rssi or 0) > 0

  if connected and not t.connected then
    if t.everConnected and not t.lostWhileArmed and (now - t.lostAt) > NEW_PACK_GAP then
      newPack(t)
    end
    t.everConnected = true
    t.lostWhileArmed = false
  elseif t.connected and not connected then
    t.lostAt = now
    t.lostWhileArmed = (t.arm == "armed" or t.arm == "failsafe")
    -- Link lost: save the last known position right away
    if t.lat and (t.lat ~= t.savedLat or t.lon ~= t.savedLon) then
      savePosition(t, now)
    end
  end
  t.connected = connected

  -- Without a link the last values stay (e.g. the last GPS position).
  if connected then
    readSensors(t)
    local capa = t.v.capa
    if capa and t.lastCapa and capa + CAPA_DROP < t.lastCapa then
      newPack(t)
    end
    t.lastCapa = capa
  end

  local prevArm = t.arm
  updateArmState(t)
  local flying = (t.arm == "armed" or t.arm == "failsafe")
  local wasFlying = (prevArm == "armed" or prevArm == "failsafe")

  -- Flight time only runs while the drone is armed.
  local dt = t.lastTick and (now - t.lastTick) or 0
  t.lastTick = now
  if flying and wasFlying and dt > 0 then
    t.flightTicks = t.flightTicks + dt
  end
  t.timerRunning = flying
  t.flightSec = math.floor(t.flightTicks / 100)

  local v = t.v
  updateBattery(t, cellsOption)
  t.pitch = toDegrees(v.pitch)
  t.roll = toDegrees(v.roll)
  local yaw = toDegrees(v.yaw)
  t.yaw = yaw and (yaw % 360) or nil
  t.alt = v.alt
  t.vspd = v.vspd
  updateGps(t, flying and not wasFlying, now)
  updateLink(t, elrsMajor)
  updateRadio(t)
end

return M
