-- Direct CRSF communication through the ELRS module:
--  * device info (0x28/0x29): ELRS version of TX module and receiver
--  * MSP over CRSF (0x7A/0x7B) to Betaflight: motor RPM,
--    reasons for blocked arming, Betaflight version
-- Frame layout as in Betaflight's telemetry/msp_shared.c (MSP v1).

local M = {}

local ADDR_BROADCAST = 0x00
local ADDR_FC = 0xC8
local ADDR_RADIO = 0xEA
local ADDR_RX = 0xEC
local ADDR_TX = 0xEE

local FRAME_PING = 0x28
local FRAME_DEVICE_INFO = 0x29
local FRAME_MSP_REQ = 0x7A
local FRAME_MSP_RESP = 0x7B

local MSP_FC_VERSION = 3
local MSP_MOTOR_TELEMETRY = 139
local MSP_STATUS_EX = 150

-- Over ELRS, MSP replies come back with only a few bytes per telemetry
-- packet; the motor data (53 bytes) often takes over 1.5 s. A new request
-- before the old one is answered makes Betaflight abort the running reply.
-- Hence only one request at a time and a long timeout.
local MSP_TIMEOUT = 500       -- 5 s without reply: drop the request
local PING_INTERVAL = 300     -- ask for device info every 3 s until everything is known
local VERSION_INTERVAL = 500
local STATUS_INTERVAL = 300   -- the blocking reason rarely changes
local MOTOR_DATA_MAX_AGE = 800

-- Motor polling: interval in ticks {armed, disarmed, blocked} per setting.
local MOTOR_INTERVALS = {
  normal = { 50, 200, 500 },
  fast = { 20, 100, 500 },
}

function M.new()
  return {
    seq = 0,
    pendingCmd = nil, pendingAt = 0,
    rxStarted = false, rxSeq = 0, rxCmd = 0, rxSize = 0, rxBuf = {}, rxErr = false,
    lastPing = -PING_INTERVAL,
    lastVersionReq = -VERSION_INTERVAL,
    lastStatusReq = -STATUS_INTERVAL,
    lastMotorReq = 0,
    pack = nil,
    tx = nil, rx = nil, fcVersion = nil,
    motors = nil, motorsAt = nil, motorReplies = 0,
    armingFlags = nil, armingAt = nil, cpuTemp = nil,
  }
end

local function available()
  return type(crossfireTelemetryPush) == "function" and type(crossfireTelemetryPop) == "function"
end

local function u16(b, i)
  return (b[i] or 0) + (b[i + 1] or 0) * 256
end

local function u32(b, i)
  return u16(b, i) + u16(b, i + 2) * 65536
end

local function readString(data, off)
  local chars = {}
  while off <= #data and data[off] ~= 0 do
    chars[#chars + 1] = string.char(data[off])
    off = off + 1
  end
  return table.concat(chars), off + 1
end

-- data[1] = destination, data[2] = origin, then name, serial number ("ELRS"),
-- hardware and software version (4 bytes each).
local function parseDeviceInfo(s, data)
  local origin = data[2]
  if origin ~= ADDR_TX and origin ~= ADDR_RX then return end
  local name, off = readString(data, 3)
  local isElrs = data[off] == 0x45 and data[off + 1] == 0x4C
    and data[off + 2] == 0x52 and data[off + 3] == 0x53
  local major, minor, rev = data[off + 9], data[off + 10], data[off + 11]
  if not (isElrs and major and minor and rev) then return end
  local info = {
    name = name, major = major,
    text = string.format("%d.%d.%d", major, minor, rev),
  }
  if origin == ADDR_TX then s.tx = info else s.rx = info end
end

local function handleMsp(s, cmd, buf, now)
  if cmd == MSP_MOTOR_TELEMETRY then
    local count = math.min(buf[1] or 0, 8)
    local motors = {}
    for m = 1, count do
      local base = 2 + (m - 1) * 13
      if base + 12 > #buf then break end
      local rpm = u32(buf, base)
      if rpm >= 2147483648 then rpm = 0 end
      motors[m] = {
        rpm = rpm,
        invalid = u16(buf, base + 4),   -- DShot error rate in 1/100 %, 10000 = no data
        temp = buf[base + 6],           -- 0 = no temperature (e.g. without Bluejay EDT)
      }
    end
    s.motors = motors
    s.motorsAt = now
    s.motorReplies = s.motorReplies + 1
  elseif cmd == MSP_STATUS_EX then
    local i = 17 + (buf[16] or 0)       -- after the extended flight mode flags
    if #buf >= i + 4 then
      s.armingFlags = u32(buf, i + 1)
      s.armingAt = now
      if #buf >= i + 7 then s.cpuTemp = u16(buf, i + 6) end
    end
  elseif cmd == MSP_FC_VERSION then
    if #buf >= 3 then
      if (buf[4] or 0) > 0 and #buf >= 4 + buf[4] then
        local chars = {}
        for k = 5, 4 + buf[4] do chars[#chars + 1] = string.char(buf[k]) end
        s.fcVersion = table.concat(chars)
      elseif buf[1] >= 20 then
        s.fcVersion = string.format("%d.%d.%d", 2000 + buf[1], buf[2], buf[3])
      else
        s.fcVersion = string.format("%d.%d.%d", buf[1], buf[2], buf[3])
      end
    end
  end
end

local function onMspChunk(s, data, now)
  local status = data[3]
  if not status then return end
  local seq = status % 16
  local start = math.floor(status / 16) % 2 == 1
  local idx = 4

  if start then
    s.rxBuf = {}
    s.rxErr = status >= 128
    s.rxSize = data[idx] or 0
    s.rxCmd = data[idx + 1] or 0
    idx = idx + 2
    if s.rxSize == 255 then
      s.rxSize = u16(data, idx)
      idx = idx + 2
    end
    s.rxStarted = true
  elseif not s.rxStarted or (s.rxSeq + 1) % 16 ~= seq then
    s.rxStarted = false
    return
  end
  s.rxSeq = seq

  local buf = s.rxBuf
  while idx <= #data and #buf < s.rxSize do
    buf[#buf + 1] = data[idx]
    idx = idx + 1
  end

  if #buf >= s.rxSize then
    s.rxStarted = false
    if s.rxCmd == s.pendingCmd then s.pendingCmd = nil end
    if not s.rxErr then handleMsp(s, s.rxCmd, buf, now) end
  end
end

local function mspRequest(s, cmd, now)
  if s.pendingCmd then
    if now - s.pendingAt < MSP_TIMEOUT then return false end
    s.pendingCmd = nil
  end
  if not crossfireTelemetryPush() then return false end
  local status = 0x30 + s.seq           -- MSP v1 + start bit + sequence number
  s.seq = (s.seq + 1) % 16
  -- Payload: status, length 0, command, checksum, padded to 8 bytes
  local ok = crossfireTelemetryPush(FRAME_MSP_REQ,
    { ADDR_FC, ADDR_RADIO, status, 0, cmd, cmd, 0, 0, 0, 0 })
  if ok then
    s.pendingCmd = cmd
    s.pendingAt = now
  end
  return ok
end

-- Fetch incoming CRSF frames (only call in the foreground).
function M.poll(s, now)
  if not available() then return end
  for _ = 1, 8 do
    local cmd, data = crossfireTelemetryPop()
    if not cmd then break end
    if cmd == FRAME_MSP_RESP then
      if data[1] == ADDR_RADIO and data[2] == ADDR_FC then onMspChunk(s, data, now) end
    elseif cmd == FRAME_DEVICE_INFO then
      parseDeviceInfo(s, data)
    end
  end
end

-- Schedule requests. tel: state from telemetry.lua, motorMode: "off"/"normal"/"fast".
function M.schedule(s, now, tel, motorMode)
  if s.pack ~= tel.pack then
    s.pack = tel.pack
    s.motors, s.motorsAt, s.motorReplies = nil, nil, 0
    s.armingFlags, s.armingAt = nil, nil
  end
  if not tel.connected then
    s.armingFlags = nil
  end
  if s.motorsAt and now - s.motorsAt > MOTOR_DATA_MAX_AGE then
    s.motors = nil
  end
  if not available() then return end

  -- Device info until the TX module (and, when connected, the receiver) are known.
  if (not s.tx or (tel.connected and not s.rx)) and now - s.lastPing >= PING_INTERVAL then
    if crossfireTelemetryPush() then
      crossfireTelemetryPush(FRAME_PING, { ADDR_BROADCAST, ADDR_RADIO })
      s.lastPing = now
    end
    return
  end

  if not tel.connected then return end

  if tel.arm == "locked" and now - s.lastStatusReq >= STATUS_INTERVAL then
    if mspRequest(s, MSP_STATUS_EX, now) then s.lastStatusReq = now end
    return
  end

  if not s.fcVersion and now - s.lastVersionReq >= VERSION_INTERVAL then
    if mspRequest(s, MSP_FC_VERSION, now) then s.lastVersionReq = now end
    return
  end

  local iv = MOTOR_INTERVALS[motorMode]
  if iv then
    local interval = iv[2]
    if tel.arm == "armed" or tel.arm == "failsafe" then
      interval = iv[1]
    elseif tel.arm == "locked" then
      interval = iv[3]
    end
    if now - s.lastMotorReq >= interval then
      if mspRequest(s, MSP_MOTOR_TELEMETRY, now) then s.lastMotorReq = now end
    end
  end
end

-- Running ELRS major version of the TX module (for the RFMD table) or nil.
function M.elrsMajor(s)
  return s.tx and s.tx.major or nil
end

return M
