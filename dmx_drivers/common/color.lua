-- color.lua -- light_v2 intent (brightness %, CIE 1931 xy, color mode) -> emitter drive levels.
--
-- Pure Lua so every step is unit-testable off the controller. C4:ColorXYtoRGB exists (OS 3.3.0+)
-- but doing the math here means the harness exercises exactly the code the controller runs.
--
-- All outputs are 0..1 fractions keyed by role; fixture.lua scales them to DMX.

local U = require "util"

local C = {}

C.MODE_FULL = 0
C.MODE_CCT = 1

-- xy -> LINEAR sRGB (D65), normalised so the largest component is 1. LED emitters are driven
-- linearly, so no sRGB transfer curve is applied: the ratio between channels is what sets hue.
function C.xy_to_rgb(x, y)
  if not x or not y or y <= 0 then return 1, 1, 1 end
  local Y = 1
  local X = x * Y / y
  local Z = (1 - x - y) * Y / y
  local r =  3.2406 * X - 1.5372 * Y - 0.4986 * Z
  local g = -0.9689 * X + 1.8758 * Y + 0.0415 * Z
  local b =  0.0557 * X - 0.2040 * Y + 1.0570 * Z
  r, g, b = math.max(r, 0), math.max(g, 0), math.max(b, 0)
  local m = math.max(r, g, b)
  if m <= 0 then return 0, 0, 0 end
  return r / m, g / m, b / m
end

-- Kelvin -> xy on the Planckian locus (Kim et al. cubic approximation, 1667-25000 K).
function C.kelvin_to_xy(k)
  k = U.clamp(k, 1667, 25000)
  local x
  if k <= 4000 then
    x = -0.2661239e9 / (k ^ 3) - 0.2343589e6 / (k ^ 2) + 0.8776956e3 / k + 0.179910
  else
    x = -3.0258469e9 / (k ^ 3) + 2.1070379e6 / (k ^ 2) + 0.2226347e3 / k + 0.240390
  end
  local y
  if k <= 2222 then
    y = -1.1063814 * x ^ 3 - 1.34811020 * x ^ 2 + 2.18555832 * x - 0.20219683
  elseif k <= 4000 then
    y = -0.9549476 * x ^ 3 - 1.37418593 * x ^ 2 + 2.09137015 * x - 0.16748867
  else
    y = 3.0817580 * x ^ 3 - 5.87338670 * x ^ 2 + 3.75112997 * x - 0.37001483
  end
  return x, y
end

-- xy -> Kelvin (McCamy). Good to a few tens of K near the locus, which is all CCT mode sends.
function C.xy_to_kelvin(x, y)
  local n = (x - 0.3320) / (0.1858 - y)
  return 449 * n ^ 3 + 3525 * n ^ 2 + 6823.3 * n + 5520.33
end

-- Gamma used for the intensity path. "Auto" = 2.2 when dimming is virtual (emitters scaled), 1.0
-- when the fixture has its own dimmer channel (the fixture applies its own curve).
function C.resolve_gamma(setting, has_dimmer)
  local g = tonumber(setting)
  if g and g > 0 then return g end
  return has_dimmer and 1.0 or 2.2
end

-- The core mix. layout: a compiled layout (layouts.lua). state: { level = 0..100, x, y, mode }.
-- opts: { white_mix = 0..1, gamma = number, max_brightness = bool (default true) }.
--
-- MAX BRIGHTNESS (Dave, 2026-10-11: "the light wasn't as bright as it should be"). With it OFF the
-- mix is exactly the original: white extraction moves the common part of R/G/B to the White
-- emitter and normalises, so pure white ran the W LED alone with R/G/B idle (about a quarter of the
-- fixture's emitters), and a WW/CW pair ran constant-sum (each at 50% mid-range). With it ON, once
-- W is full the remaining white is ALSO made by R=G=B together, and a WW/CW pair is normalised to
-- its peak. Under the engine's own model (W == R+G+B white) the chromaticity is unchanged; only
-- whites and pale colours get brighter (up to 2x), saturated colours are byte-identical. Real W
-- LEDs are rarely exactly D65, so very pale colours may tint slightly: hence the property.
-- Returns { role = fraction } for every intensity/color role the layout has.
function C.mix(layout, state, opts)
  opts = opts or {}
  local white_mix = U.clamp(tonumber(opts.white_mix) or 1.0, 0, 1)
  local max_bright = opts.max_brightness ~= false
  local gamma = tonumber(opts.gamma) or C.resolve_gamma(nil, layout.has_dimmer)
  local level = U.clamp((state.level or 0) / 100, 0, 1)
  local out = {}

  -- 1. Chromaticity -> emitter ratios at full brightness.
  local e = { red = 0, green = 0, blue = 0, white = 0, warm_white = 0, cool_white = 0 }
  local cct_fraction
  local mode = state.mode or C.MODE_CCT
  local x, y = state.x, state.y
  if not x or not y then
    x, y = C.kelvin_to_xy((layout.cct_min + layout.cct_max) / 2)
    mode = C.MODE_CCT
  end

  local kelvin = U.clamp(C.xy_to_kelvin(x, y), layout.cct_min, layout.cct_max)

  if layout.type == "dimmer" then
    -- nothing to mix
  elseif (mode == C.MODE_CCT or not layout.has_rgb) and (layout.has_cct or layout.has_ww_cw) then
    -- CCT request, or a white-only fixture handed a full-color point: both resolve to a Kelvin
    -- value on this fixture's range.
    if layout.has_cct then
      cct_fraction = (kelvin - layout.cct_min) / (layout.cct_max - layout.cct_min)
    end
    if layout.has_ww_cw then
      -- Mix by mired between the fixture's warm and cool ends. Constant-sum, so the light does
      -- not get brighter in the middle of the range; brightness stays with the dimmer path.
      local mw, mc, m = 1e6 / layout.cct_min, 1e6 / layout.cct_max, 1e6 / kelvin
      local t = U.clamp((mw - m) / (mw - mc), 0, 1)
      e.warm_white, e.cool_white = 1 - t, t
      local peak = math.max(e.warm_white, e.cool_white)
      if max_bright and peak > 0 then
        e.warm_white, e.cool_white = e.warm_white / peak, e.cool_white / peak
      end
      -- ...except when a CCT channel is also present, the WW/CW pair then runs full and the
      -- fixture's CCT channel sets the temperature.
      if layout.has_cct then e.warm_white, e.cool_white = 1, 1 end
      if peak <= 0 then e.warm_white, e.cool_white = 1, 1 end
    end
    if layout.has_cct and not layout.has_ww_cw then
      -- A CCT channel with RGB/W emitters: feed the emitters white and let CCT tint it.
      if layout.has_white then e.white = 1 end
      if not layout.has_white and layout.has_rgb then e.red, e.green, e.blue = 1, 1, 1 end
    end
  else
    local r, g, b
    if mode == C.MODE_CCT then
      r, g, b = C.xy_to_rgb(C.kelvin_to_xy(kelvin))
    else
      r, g, b = C.xy_to_rgb(x, y)
    end
    if layout.has_rgb then
      if layout.has_white then
        -- 2. White extraction: take the common part of R, G and B out to the white emitter.
        local w = math.min(r, g, b) * white_mix
        r, g, b = r - w, g - w, b - w
        if max_bright then
          -- Largest scale s such that the chroma part (r,g,b)*s fits AND the white part w*s can be
          -- made by W (up to 1) plus a common R=G=B top-up k in the headroom left by the chroma.
          local maxc = math.max(r, g, b)
          local s = (w + maxc) > 0 and 2 / (w + maxc) or 0
          if maxc > 0 then s = math.min(s, 1 / maxc) end
          local white_total = w * s
          local W = math.min(1, white_total)
          local k = white_total - W
          r, g, b, w = r * s + k, g * s + k, b * s + k, W
        else
          local peak = math.max(r, g, b, w)
          if peak > 0 then r, g, b, w = r / peak, g / peak, b / peak, w / peak end
        end
        e.white = w
      end
      e.red, e.green, e.blue = r, g, b
    elseif layout.has_white then
      e.white = 1
    elseif layout.has_ww_cw then
      e.warm_white, e.cool_white = 1, 1
    else
      -- Incomplete RGB (e.g. red+green only): drive what exists from the RGB ratios.
      e.red, e.green, e.blue = r, g, b
    end
  end

  -- 3. Intensity.
  local drive = level > 0 and level ^ gamma or 0
  if layout.has_dimmer then
    out.dimmer = drive
    for role in pairs(e) do
      if layout.roles[role] then out[role] = e[role] end
    end
  else
    for role in pairs(e) do
      if layout.roles[role] then out[role] = e[role] * drive end
    end
  end
  if layout.has_cct then out.cct = cct_fraction or 0.5 end
  return out
end

-- Fraction -> DMX byte, or {coarse, fine} for a 16-bit pair.
function C.to_byte(f)
  return U.round(U.clamp(f, 0, 1) * 255)
end

function C.to_16(f)
  local v = U.round(U.clamp(f, 0, 1) * 65535)
  return math.floor(v / 256), v % 256
end

return C
