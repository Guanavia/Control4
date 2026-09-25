-- universe.lua -- the node's model of one DMX universe: per-fixture slices, fades, the overlap
-- policy, and composition of the 512-slot frame.
--
-- Pure Lua; time is passed in (milliseconds) so the harness can drive it with a fake clock.
--
-- OVERLAP POLICY (Dave, 2026-09-24):
--   * light <-> light: ALLOWED. Shared slots merge highest-takes-precedence. Reported as
--     "shared", not as a conflict.
--   * anything involving a mover: REFUSED. The fixture that registered LATER is refused and
--     outputs nothing; both fixtures are told why. "Later" is registration order held by the
--     node for as long as it runs (a re-register keeps its place in line).

local A = require "artnet"
local U = require "util"

local Universe = {}
Universe.__index = Universe

function Universe.new()
  local self = setmetatable({}, Universe)
  self.fixtures = {}        -- id -> record
  self.next_seq = 1
  self.frame = string.rep("\0", 512)
  self.blackout = false
  self.test = nil           -- { slot, value, until_ms }
  return self
end

local function overlaps(a, b)
  return a.start <= b.start + b.count - 1 and b.start <= a.start + a.count - 1
end

local function range_text(f)
  if f.count == 1 then return string.format("DMX %d", f.start) end
  return string.format("DMX %d-%d", f.start, f.start + f.count - 1)
end
Universe.range_text = range_text

function Universe:sorted()
  local list = {}
  for _, f in pairs(self.fixtures) do list[#list + 1] = f end
  table.sort(list, function(a, b) return a.seq < b.seq end)
  return list
end

-- Register or re-register. info = { name, start, count, kind, layout }.
-- Returns the list of fixture ids whose status changed (they must be told).
function Universe:register(id, info)
  local f = self.fixtures[id]
  if f and (f.start ~= info.start or f.count ~= info.count) then
    -- Moved or resized: the old values mean nothing at the new address.
    f.cur, f.fade, f.pairfade = {}, {}, {}
  end
  if not f then
    f = { id = id, seq = self.next_seq, cur = {}, fade = {}, pairfade = {} }
    self.next_seq = self.next_seq + 1
    self.fixtures[id] = f
  end
  f.name = info.name or ("Device " .. tostring(id))
  f.start = info.start
  f.count = info.count
  f.kind = info.kind == "mover" and "mover" or "light"
  f.layout = info.layout or ""
  return self:evaluate()
end

function Universe:unregister(id)
  if not self.fixtures[id] then return {} end
  self.fixtures[id] = nil
  local changed = self:evaluate()
  return changed
end

-- Recompute accepted/refused/shared for every fixture. Returns ids whose status text changed.
function Universe:evaluate()
  local list = self:sorted()
  local before = {}
  for _, f in ipairs(list) do
    before[f.id] = (f.state or "") .. "|" .. (f.reason or "") .. "|" .. (f.note or "")
  end

  -- Pass 1: acceptance, in registration order, so an incumbent is never displaced.
  local accepted = {}
  for _, f in ipairs(list) do
    f.state, f.reason, f.note = "accepted", nil, nil
    for _, g in ipairs(accepted) do
      if overlaps(f, g) and (f.kind == "mover" or g.kind == "mover") then
        f.state = "refused"
        f.reason = string.format("overlaps %s '%s' (%s). Moving fixtures cannot share channels.",
          g.kind == "mover" and "moving fixture" or "fixture", g.name, range_text(g))
        break
      end
    end
    if f.state == "accepted" then accepted[#accepted + 1] = f end
  end

  -- Pass 2: sharing notes between accepted lights (both sides get told).
  for _, f in ipairs(accepted) do
    local names, mismatch = {}, false
    for _, g in ipairs(accepted) do
      if g ~= f and overlaps(f, g) then
        names[#names + 1] = "'" .. g.name .. "'"
        if g.start ~= f.start or g.count ~= f.count or g.layout ~= f.layout then mismatch = true end
      end
    end
    if #names > 0 then
      f.note = "shares channels with " .. table.concat(names, ", ")
      if mismatch then
        f.note = f.note .. " -- WARNING: different address or layout, almost certainly a patching mistake"
      end
    end
  end

  local changed = {}
  for _, f in ipairs(list) do
    local after = f.state .. "|" .. (f.reason or "") .. "|" .. (f.note or "")
    if after ~= before[f.id] then changed[#changed + 1] = f.id end
  end
  return changed
end

-- Status for one fixture, sent back to it as NODE_STATE.CONFLICT.
function Universe:conflict_text(id)
  local f = self.fixtures[id]
  if not f then return "not registered" end
  if f.state == "refused" then return "REFUSED: " .. f.reason end
  return f.note or ""
end

function Universe:is_accepted(id)
  local f = self.fixtures[id]
  return f ~= nil and f.state == "accepted"
end

local function value16(f, pair)
  return (f.cur[pair.coarse] or 0) * 256 + (f.cur[pair.fine] or 0)
end

-- Apply an update. offsets/values: parallel arrays (0-based offsets). pairs: list of
-- { coarse = off, fine = off } (pair_list). fade_ms: 0 snaps.
function Universe:update(id, offsets, values, fade_ms, pair_list, now)
  local f = self.fixtures[id]
  if not f then return false, "not registered" end
  fade_ms = tonumber(fade_ms) or 0
  local paired = {}
  local incoming = {}
  for i, off in ipairs(offsets) do
    if off >= 0 and off < f.count then incoming[off] = U.clamp(values[i] or 0, 0, 255) end
  end
  for _, p in ipairs(pair_list or {}) do
    if incoming[p.coarse] ~= nil or incoming[p.fine] ~= nil then
      paired[p.coarse], paired[p.fine] = true, true
      local to16 = (incoming[p.coarse] or f.cur[p.coarse] or 0) * 256 + (incoming[p.fine] or f.cur[p.fine] or 0)
      if fade_ms > 0 then
        f.pairfade[p.coarse] = { fine = p.fine, from = value16(f, p), to = to16, t0 = now, dur = fade_ms }
      else
        f.pairfade[p.coarse] = nil
        f.cur[p.coarse], f.cur[p.fine] = math.floor(to16 / 256), to16 % 256
      end
      f.fade[p.coarse], f.fade[p.fine] = nil, nil
    end
  end
  for off, v in pairs(incoming) do
    if not paired[off] then
      if fade_ms > 0 then
        f.fade[off] = { from = f.cur[off] or 0, to = v, t0 = now, dur = fade_ms }
      else
        f.fade[off] = nil
        f.cur[off] = v
      end
    end
  end
  -- Any fixture update ends a Blackout (brief: "temporary, until any fixture changes").
  self.blackout = false
  return true
end

-- Advance every running fade to `now`. Returns true while any fade is still running.
function Universe:tick(now)
  local active = false
  for _, f in pairs(self.fixtures) do
    for off, fd in pairs(f.fade) do
      local p = fd.dur > 0 and (now - fd.t0) / fd.dur or 1
      if p >= 1 then
        f.cur[off] = fd.to
        f.fade[off] = nil
      else
        f.cur[off] = fd.from + (fd.to - fd.from) * math.max(p, 0)
        active = true
      end
    end
    for coarse, pf in pairs(f.pairfade) do
      local p = pf.dur > 0 and (now - pf.t0) / pf.dur or 1
      local v
      if p >= 1 then
        v = pf.to
        f.pairfade[coarse] = nil
      else
        v = pf.from + (pf.to - pf.from) * math.max(p, 0)
        active = true
      end
      v = U.round(v)
      f.cur[coarse], f.cur[pf.fine] = math.floor(v / 256), v % 256
    end
  end
  if self.test and now >= self.test.until_ms then self.test = nil end
  return active or self.test ~= nil
end

-- Compose the 512-slot frame. Returns the data string and whether it differs from the last one.
function Universe:compose()
  local out = {}
  for i = 1, 512 do out[i] = 0 end
  if not self.blackout then
    for _, f in pairs(self.fixtures) do
      if f.state == "accepted" then
        for off = 0, f.count - 1 do
          local slot = f.start + off
          local v = U.round(f.cur[off] or 0)
          if v > out[slot] then out[slot] = v end
        end
      end
    end
  end
  if self.test then out[self.test.slot] = self.test.value end
  local data = A.slots_to_string(out)
  local changed = data ~= self.frame
  self.frame = data
  return data, changed
end

-- Human-readable patch for the node's Patch property.
function Universe:patch_text()
  local list = self:sorted()
  if #list == 0 then return "No fixtures registered." end
  table.sort(list, function(a, b)
    if a.start ~= b.start then return a.start < b.start end
    return a.seq < b.seq
  end)
  local lines = {}
  for _, f in ipairs(list) do
    local status = "OK"
    if f.state == "refused" then status = "REFUSED - " .. f.reason
    elseif f.note then status = "OK, " .. f.note end
    lines[#lines + 1] = string.format("%s  %s (%s%s): %s", range_text(f), f.name,
      f.kind == "mover" and "mover" or "light", f.layout ~= "" and (", " .. f.layout) or "", status)
  end
  return table.concat(lines, "\n")
end

function Universe:counts()
  local ok, refused = 0, 0
  for _, f in pairs(self.fixtures) do
    if f.state == "accepted" then ok = ok + 1 else refused = refused + 1 end
  end
  return ok, refused
end

return Universe
