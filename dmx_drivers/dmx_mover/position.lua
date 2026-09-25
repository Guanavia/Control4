-- position.lua -- pan/tilt for moving heads. Pure Lua.
--
-- Position is held as an ABSOLUTE fraction of full travel (0..1) per axis, so changing the soft
-- limits later never silently moves a stored preset. Soft limits (percent of travel) clamp in
-- exactly one place, set(), which every path goes through: Extras sliders, nudges, Home, presets
-- and programming.

local U = require "util"

local Pos = {}
Pos.__index = Pos

Pos.NUDGE_SIZES = {
  { label = "Fine (0.5%)",  pct = 0.5 },
  { label = "Medium (2%)",  pct = 2 },
  { label = "Coarse (5%)",  pct = 5 },
}

function Pos.new()
  return setmetatable({ pan = 0.5, tilt = 0.5,
    limits = { pan_min = 0, pan_max = 100, tilt_min = 0, tilt_max = 100 },
    invert = { pan = false, tilt = false }, nudge_pct = 2 }, Pos)
end

function Pos:set_limits(l)
  local function num(v, d) return U.clamp(tonumber(v) or d, 0, 100) end
  local pan_min, pan_max = num(l.pan_min, 0), num(l.pan_max, 100)
  local tilt_min, tilt_max = num(l.tilt_min, 0), num(l.tilt_max, 100)
  if pan_min > pan_max then pan_min, pan_max = pan_max, pan_min end
  if tilt_min > tilt_max then tilt_min, tilt_max = tilt_max, tilt_min end
  self.limits = { pan_min = pan_min, pan_max = pan_max, tilt_min = tilt_min, tilt_max = tilt_max }
  -- Re-clamp where we are now.
  self:set(self.pan * 100, self.tilt * 100)
end

-- pan/tilt in percent of FULL travel (0..100). nil leaves that axis alone.
function Pos:set(pan_pct, tilt_pct)
  local l = self.limits
  if pan_pct ~= nil then self.pan = U.clamp(tonumber(pan_pct) or 50, l.pan_min, l.pan_max) / 100 end
  if tilt_pct ~= nil then self.tilt = U.clamp(tonumber(tilt_pct) or 50, l.tilt_min, l.tilt_max) / 100 end
end

function Pos:percent()
  return self.pan * 100, self.tilt * 100
end

-- Home = the centre of the soft-limit window (brief 8.2).
function Pos:home()
  local l = self.limits
  self:set((l.pan_min + l.pan_max) / 2, (l.tilt_min + l.tilt_max) / 2)
end

-- dir: "Left" | "Right" | "Up" | "Down". amount in percent of full travel.
function Pos:nudge(dir, amount)
  amount = tonumber(amount) or self.nudge_pct
  local pan, tilt = self:percent()
  if dir == "Left" then pan = pan - amount
  elseif dir == "Right" then pan = pan + amount
  elseif dir == "Up" then tilt = tilt + amount
  elseif dir == "Down" then tilt = tilt - amount
  else return false end
  self:set(pan, tilt)
  return true
end

-- Write channel values for this position into `out` (offset -> value) for a compiled layout.
function Pos:write(out, layout)
  local function axis(role, fraction, inverted)
    local coarse = layout.roles[role]
    if coarse == nil then return end
    if inverted then fraction = 1 - fraction end
    local v16 = U.round(U.clamp(fraction, 0, 1) * 65535)
    local fine = layout.roles[role .. "_fine"]
    if fine ~= nil then
      out[coarse] = math.floor(v16 / 256)
      out[fine] = v16 % 256
    else
      out[coarse] = U.round(v16 / 257)   -- 65535/257 = 255 exactly
    end
  end
  axis("pan", self.pan, self.invert.pan)
  axis("tilt", self.tilt, self.invert.tilt)
end

function Pos:snapshot()
  return { pan = self.pan, tilt = self.tilt, nudge_pct = self.nudge_pct }
end

function Pos:restore(t)
  if type(t) ~= "table" then return end
  self.pan = tonumber(t.pan) or self.pan
  self.tilt = tonumber(t.tilt) or self.tilt
  self.nudge_pct = tonumber(t.nudge_pct) or self.nudge_pct
end

return Pos
