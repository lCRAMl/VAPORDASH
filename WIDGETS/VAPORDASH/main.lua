-- Vapor Dashboard: telemetry widget for the GEPRC Vapor-D5 (Betaflight, ELRS)
-- on the RadioMaster TX16S MK3 (EdgeTX 2.12, 800x480, App mode).

local ROOT = "/WIDGETS/VAPORDASH/"

local OPTION_LABELS = {
  Cells = "Battery cells (0 = auto)",
  MotorPoll = "Poll motor RPM",
}

local options = {
  { "Cells", VALUE, 6, 0, 8 },
  { "MotorPoll", CHOICE, 2, { "Off", "Normal", "Fast" } },
}

local MOTOR_MODES = { "off", "normal", "fast" }

-- Load modules only when needed: EdgeTX loads every widget on a model
-- change, including unused ones.
local mods

local function loadModule(name)
  local chunk = loadScript(ROOT .. "lib/" .. name .. ".lua")
  return chunk and chunk() or nil
end

local function modules()
  if not mods then
    mods = {
      telemetry = loadModule("telemetry"),
      crsf = loadModule("crsf"),
      ui = loadModule("ui"),
    }
  end
  return mods
end

local function motorMode(opts)
  -- Choice options are 1-based; 0 = never saved -> default.
  local v = opts and tonumber(opts.MotorPoll) or 0
  return MOTOR_MODES[v] or "normal"
end

local function cellsOption(opts)
  local v = opts and tonumber(opts.Cells) or 0
  if v < 0 or v > 8 then return 0 end
  return math.floor(v)
end

local function create(zone, opts)
  local m = modules()
  local tel = m.telemetry.new()
  m.telemetry.loadPosition(tel)
  return {
    zone = zone,
    options = opts,
    tel = tel,
    link = m.crsf.new(),
    popup = nil,
  }
end

-- Open the QR popup: freeze the position now and start the QR code.
-- Content: geo: link (RFC 5870) with a pin and a name, e.g.
-- geo:52.521080,13.405000?q=52.521080,13.405000(VAPOR-D5)
local function openPopup(widget)
  local m = modules()
  local tel = widget.tel
  local p = { live = tel.connected and tel.fix }
  if tel.lat and tel.lon then
    p.lat, p.lon = tel.lat, tel.lon
    p.alt, p.sats, p.time = tel.posAlt, tel.posSats, tel.posTime
    p.dist = tel.dist
    local label = "Drone"
    if model and model.getInfo then
      local info = model.getInfo()
      if info and info.name and info.name ~= "" then label = info.name end
    end
    label = (string.gsub(label, "[^%w%-]", "-"))
    p.payload = string.format("geo:%.6f,%.6f?q=%.6f,%.6f(%s)", p.lat, p.lon, p.lat, p.lon, label)
    if not m.qr then m.qr = loadModule("qr") end
    p.job = m.qr and m.qr.new(p.payload) or nil
  end
  widget.popup = p
end

-- EdgeTX only sends touch events while the widget is in full-screen mode
-- (in App mode: long-press the screen). Otherwise "event" is nil.
-- A tap = EVT_TOUCH_FIRST (with position) + EVT_TOUCH_BREAK on release.
-- EVT_TOUCH_TAP only comes for touches shorter than 250 ms and is therefore
-- only used if the other events don't exist.
local function handleEvent(widget, event, touchState)
  widget.interactive = (event ~= nil)
  if not event or event == 0 then return end

  local pos
  if EVT_TOUCH_FIRST ~= nil and event == EVT_TOUCH_FIRST then
    widget.touchStart = touchState and { x = touchState.x, y = touchState.y } or nil
    return
  elseif EVT_TOUCH_SLIDE ~= nil and event == EVT_TOUCH_SLIDE then
    widget.touchStart = nil             -- a swipe is not a tap
    return
  elseif EVT_TOUCH_BREAK ~= nil and event == EVT_TOUCH_BREAK then
    pos = widget.touchStart
    widget.touchStart = nil
    if not pos then return end
  elseif EVT_TOUCH_FIRST == nil and EVT_TOUCH_TAP ~= nil and event == EVT_TOUCH_TAP then
    pos = touchState
  elseif widget.popup and EVT_VIRTUAL_EXIT ~= nil and event == EVT_VIRTUAL_EXIT then
    widget.popup = nil
    return
  else
    return
  end

  if widget.popup then
    widget.popup = nil
  elseif pos and modules().ui.gpsHit(widget.zone, pos.x, pos.y) then
    openPopup(widget)
  end
end

local function update(widget, opts)
  widget.options = opts
end

local function tick(widget, now, visible)
  local m = modules()
  if visible then m.crsf.poll(widget.link, now) end
  m.telemetry.update(widget.tel, now, cellsOption(widget.options), m.crsf.elrsMajor(widget.link))
  if visible then
    m.crsf.schedule(widget.link, now, widget.tel, motorMode(widget.options))
  end
end

-- Runs while the widget is not visible: keep counting the flight time.
local function background(widget)
  tick(widget, getTime(), false)
end

local function refresh(widget, event, touchState)
  local now = getTime()
  tick(widget, now, true)
  handleEvent(widget, event, touchState)

  local popup = widget.popup
  if popup and popup.job and not popup.job.done then
    modules().qr.step(popup.job)
  end
  modules().ui.draw(widget.zone, widget.tel, widget.link, motorMode(widget.options), now, popup,
    widget.interactive)
end

local function translate(name)
  return OPTION_LABELS[name] or name
end

return {
  name = "Vapor Dashboard",
  options = options,
  create = create,
  update = update,
  refresh = refresh,
  background = background,
  translate = translate,
}
