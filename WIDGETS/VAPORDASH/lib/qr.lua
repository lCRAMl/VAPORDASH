-- QR-Code-Erzeuger: Byte-Modus, Fehlerkorrektur-Stufe M, Version 1-6
-- (bis 106 Zeichen), feste Maske 2. Ablauf wie in der Referenz-
-- Implementierung von Project Nayuki (QR Code generator library, MIT-Lizenz).
--
-- EdgeTX erlaubt einem Widget pro refresh() nur ~20.000 Lua-Befehle und
-- stellt in der Widget-Umgebung keine Coroutinen bereit. Die Arbeit ist
-- deshalb in kleine Aufgaben zerlegt; M.step() erledigt pro Aufruf nur ein
-- Stueck davon.

local M = {}

-- Version -> { Datenwoerter je Block, Bloecke, Korrekturwoerter je Block,
--              Position des Ausrichtungsmusters (nil bei Version 1) }
local VERSIONS = {
  { 16, 1, 10, nil },
  { 28, 1, 16, 18 },
  { 44, 1, 26, 22 },
  { 32, 2, 18, 26 },
  { 43, 2, 24, 30 },
  { 27, 4, 16, 34 },
}

local WORK_PER_STEP = 200   -- Aufwand (etwa bearbeitete Module) je Aufruf

-- Feste Maske 2 (Spalte durch 3 teilbar): Bei geo:-Links schnitt sie in
-- einem Test mit 60 Zufallskoordinaten am besten ab (wenigste Strafpunkte
-- nach QR-Standard, in 32 von 60 Faellen die beste). Alle 8 Masken
-- durchzurechnen kostete auf dem Sender rund 1,4 Mio. Lua-Befehle
-- (~10 s Wartezeit), bei kaum besserer Lesbarkeit.
local MASK = 2

-- Galois-Feld GF(256) mit Polynom 0x11D
local EXP, LOG = {}, {}
do
  local x = 1
  for i = 0, 254 do
    EXP[i] = x
    LOG[x] = i
    x = x << 1
    if x >= 256 then x = x ~ 0x11D end
  end
  for i = 255, 509 do EXP[i] = EXP[i - 255] end
end

local function gfMul(a, b)
  if a == 0 or b == 0 then return 0 end
  return EXP[LOG[a] + LOG[b]]
end

local function setFn(job, x, y, dark)
  local i = y * job.n + x + 1
  job.mods[i] = dark and 1 or 0
  job.fn[i] = true
end

local function finder(job, cx, cy)
  local n = job.n
  for dy = -4, 4 do
    for dx = -4, 4 do
      local x, y = cx + dx, cy + dy
      if x >= 0 and x < n and y >= 0 and y < n then
        local d = math.max(math.abs(dx), math.abs(dy))
        setFn(job, x, y, d ~= 2 and d ~= 4)
      end
    end
  end
end

local function formatBits(job, mask)
  local n = job.n
  local rem = mask                    -- Stufe M = 0
  for _ = 1, 10 do rem = (rem << 1) ~ ((rem >> 9) * 0x537) end
  local b = ((mask << 10) | rem) ~ 0x5412
  local function bit(i) return (b >> i) & 1 == 1 end
  for i = 0, 5 do setFn(job, 8, i, bit(i)) end
  setFn(job, 8, 7, bit(6))
  setFn(job, 8, 8, bit(7))
  setFn(job, 7, 8, bit(8))
  for i = 9, 14 do setFn(job, 14 - i, 8, bit(i)) end
  for i = 0, 7 do setFn(job, n - 1 - i, 8, bit(i)) end
  for i = 8, 14 do setFn(job, 8, n - 15 + i, bit(i)) end
  setFn(job, 8, n - 8, true)
end

local function putBits(bits, value, count)
  for i = count - 1, 0, -1 do bits[#bits + 1] = (value >> i) & 1 end
end

-- Aufgaben in fester Reihenfolge. Jede erledigt bei einem Aufruf ein Stueck
-- und meldet zurueck: fertig?, Aufwand. job.k zaehlt innerhalb einer Aufgabe.
local TASKS = {
  -- Version waehlen, Speicher anlegen
  function(job)
    for v = 1, #VERSIONS do
      local s = VERSIONS[v]
      if (s[1] * s[2] * 8 - 12) // 8 >= #job.text then
        job.ver = v
        break
      end
    end
    if not job.ver then error("Text zu lang fuer QR-Code") end
    job.n = 17 + 4 * job.ver
    job.mods, job.fn = {}, {}
    return true, 10
  end,

  -- Matrix leeren, eine Zeile je Aufruf
  function(job)
    local n = job.n
    local base = job.k * n
    for i = base + 1, base + n do
      job.mods[i] = 0
      job.fn[i] = false
    end
    job.k = job.k + 1
    return job.k >= n, n
  end,

  -- Taktlinien
  function(job)
    for i = 0, job.n - 1 do
      setFn(job, 6, i, i % 2 == 0)
      setFn(job, i, 6, i % 2 == 0)
    end
    return true, 2 * job.n
  end,

  -- Suchmuster in drei Ecken, eines je Aufruf
  function(job)
    local n = job.n
    if job.k == 0 then
      finder(job, 3, 3)
    elseif job.k == 1 then
      finder(job, n - 4, 3)
    else
      finder(job, 3, n - 4)
    end
    job.k = job.k + 1
    return job.k >= 3, 160
  end,

  -- Ausrichtungsmuster, Formatbereich reservieren
  function(job)
    local ap = VERSIONS[job.ver][4]
    if ap then
      for dy = -2, 2 do
        for dx = -2, 2 do
          setFn(job, ap + dx, ap + dy, math.max(math.abs(dx), math.abs(dy)) ~= 1)
        end
      end
    end
    formatBits(job, 0)
    return true, 60
  end,

  -- Modus (Byte), Laenge und Zeichen als Bits, 8 Zeichen je Aufruf
  function(job)
    local bits = job.bits
    if not bits then
      bits = {}
      job.bits = bits
      putBits(bits, 4, 4)
      putBits(bits, #job.text, 8)     -- Version 1-9: 8 Bit Zeichenzahl
    end
    local last = math.min(#job.text, job.k + 8)
    for i = job.k + 1, last do putBits(bits, string.byte(job.text, i), 8) end
    job.k = last
    return job.k >= #job.text, 64
  end,

  -- Abschluss, Bits zu Bytes (8 Bytes je Aufruf), Fuellbytes
  function(job)
    local spec = VERSIONS[job.ver]
    local dataLen = spec[1] * spec[2]
    local bits = job.bits
    if not job.data then
      putBits(bits, 0, math.min(4, dataLen * 8 - #bits))
      while #bits % 8 ~= 0 do bits[#bits + 1] = 0 end
      job.data = {}
    end
    local data = job.data
    local stop = math.min(#bits, job.k + 64)
    for i = job.k + 1, stop, 8 do
      local v = 0
      for j = 0, 7 do v = (v << 1) | bits[i + j] end
      data[#data + 1] = v
    end
    job.k = stop
    if job.k < #bits then return false, 64 end
    local pad = 0xEC
    while #data < dataLen do
      data[#data + 1] = pad
      pad = (pad == 0xEC) and 0x11 or 0xEC
    end
    return true, 64
  end,

  -- Generatorpolynom der Fehlerkorrektur, ein Faktor je Aufruf
  function(job)
    local degree = VERSIONS[job.ver][3]
    local res = job.divisor
    if not res then
      res = {}
      for i = 1, degree do res[i] = 0 end
      res[degree] = 1
      job.divisor = res
      job.root = 1
    end
    local root = job.root
    for j = 1, degree do
      res[j] = gfMul(res[j], root)
      if j < degree then res[j] = res[j] ~ res[j + 1] end
    end
    job.root = gfMul(root, 2)
    job.k = job.k + 1
    return job.k >= degree, degree
  end,

  -- Korrekturwoerter je Block (Polynomdivision), ein Datenwort je Aufruf
  function(job)
    local spec = VERSIONS[job.ver]
    local perBlock, blocks, deg = spec[1], spec[2], spec[3]
    local div = job.divisor
    if not job.ecc then
      job.ecc = {}
      job.block = 0
    end
    local res = job.rem
    if not res then
      res = {}
      for i = 1, deg do res[i] = 0 end
      job.rem = res
    end
    local factor = job.data[job.block * perBlock + job.k + 1] ~ res[1]
    for i = 1, deg - 1 do res[i] = res[i + 1] end
    res[deg] = 0
    for i = 1, deg do res[i] = res[i] ~ gfMul(div[i], factor) end
    job.k = job.k + 1
    if job.k >= perBlock then
      job.ecc[job.block + 1] = res
      job.rem = nil
      job.block = job.block + 1
      job.k = 0
    end
    return job.block >= blocks, deg
  end,

  -- Daten- und Korrekturwoerter blockweise verschraenken
  function(job)
    local spec = VERSIONS[job.ver]
    local perBlock, blocks, deg = spec[1], spec[2], spec[3]
    local out = {}
    for i = 0, perBlock - 1 do
      for b = 0, blocks - 1 do out[#out + 1] = job.data[b * perBlock + i + 1] end
    end
    for i = 1, deg do
      for b = 1, blocks do out[#out + 1] = job.ecc[b][i] end
    end
    job.words = out
    job.bits, job.data, job.ecc, job.divisor = nil, nil, nil, nil
    return true, #out
  end,

  -- Datenbits im Zickzack von unten rechts einsetzen, ein Spaltenpaar je Aufruf
  function(job)
    local n = job.n
    if not job.right then
      job.right = n - 1
      job.bit = 0
    end
    local right = job.right
    if right == 6 then right = 5 end
    local mods, fn, words = job.mods, job.fn, job.words
    local total = #words * 8
    local k = job.bit
    local upward = ((right + 1) & 2) == 0
    for vert = 0, n - 1 do
      local y = upward and (n - 1 - vert) or vert
      for j = 0, 1 do
        local i = y * n + (right - j) + 1
        if not fn[i] and k < total then
          mods[i] = (words[(k >> 3) + 1] >> (7 - (k & 7))) & 1
          k = k + 1
        end
      end
    end
    job.bit = k
    job.right = right - 2
    return job.right < 1, 2 * n
  end,

  -- Maske 2 anwenden (jede dritte Spalte), eine Zeile je Aufruf
  function(job)
    local n, mods, fn = job.n, job.mods, job.fn
    local base = job.k * n + 1
    for x = 0, n - 1, 3 do
      local i = base + x
      if not fn[i] then mods[i] = 1 - mods[i] end
    end
    job.k = job.k + 1
    if job.k < n then return false, n // 3 end
    formatBits(job, MASK)
    return true, n // 3 + 40
  end,

  -- Dunkle Module zeilenweise zu Strecken zusammenfassen (schnelleres Zeichnen)
  function(job)
    local n, mods = job.n, job.mods
    local runs = job.runs or {}
    job.runs = runs
    local y = job.k
    local x = 0
    while x < n do
      if mods[y * n + x + 1] == 1 then
        local start = x
        while x < n and mods[y * n + x + 1] == 1 do x = x + 1 end
        runs[#runs + 1] = start
        runs[#runs + 1] = y
        runs[#runs + 1] = x - start
      else
        x = x + 1
      end
    end
    job.k = y + 1
    return job.k >= n, n
  end,
}

local function work(job)
  local used = 0
  while used < WORK_PER_STEP do
    local task = TASKS[job.task]
    if not task then
      job.result = { size = job.n, version = job.ver, mask = MASK, modules = job.mods, runs = job.runs }
      job.words, job.fn = nil, nil
      job.done = true
      return
    end
    local finished, cost = task(job)
    used = used + cost
    if finished then
      job.task = job.task + 1
      job.k = 0
    end
  end
end

-- Neuen Auftrag anlegen; danach M.step() je refresh() aufrufen.
function M.new(text)
  return { text = text, task = 1, k = 0, done = false }
end

-- Ein Stueck weiterrechnen. Gibt true zurueck, sobald der Code fertig ist
-- (Ergebnis in job.result) oder ein Fehler auftrat (job.err).
function M.step(job)
  if job.done then return true end
  local ok, err = pcall(work, job)
  if not ok then
    job.err = tostring(err)
    job.done = true
  end
  return job.done
end

return M
