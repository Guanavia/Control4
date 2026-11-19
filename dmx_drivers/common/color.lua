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

---------------------------------------------------------------------------------------------
-- Colour spaces for the Extended Range type: xy -> linear RGB in a chosen gamut, so hue and
-- saturation can be expressed relative to sRGB (what Control4's own HSIC mode does) or to a wider
-- gamut (Rec. 2020, or a fixture's own primaries). White point D65 throughout.
---------------------------------------------------------------------------------------------
C.D65 = { 0.3127, 0.3290 }
C.SPACES = {
  srgb    = { 0.640, 0.330, 0.300, 0.600, 0.150, 0.060 },
  rec2020 = { 0.708, 0.292, 0.170, 0.797, 0.131, 0.046 },
}

local function xyz(x, y) return x / y, 1, (1 - x - y) / y end

local function inverse3(m)
  local a, b, c = m[1][1], m[1][2], m[1][3]
  local d, e, f = m[2][1], m[2][2], m[2][3]
  local g, h, i = m[3][1], m[3][2], m[3][3]
  local A, B, Cc = e * i - f * h, -(d * i - f * g), d * h - e * g
  local det = a * A + b * B + c * Cc
  if math.abs(det) < 1e-12 then return nil end
  return {
    { A / det, -(b * i - c * h) / det, (b * f - c * e) / det },
    { B / det, (a * i - c * g) / det, -(a * f - c * d) / det },
    { Cc / det, -(a * h - b * g) / det, (a * e - b * d) / det },
  }
end

-- XYZ -> linear RGB matrix for primaries {rx, ry, gx, gy, bx, by}, D65 white. nil if degenerate.
function C.space_matrix(p)
  local R, G, B = { xyz(p[1], p[2]) }, { xyz(p[3], p[4]) }, { xyz(p[5], p[6]) }
  local m = { { R[1], G[1], B[1] }, { R[2], G[2], B[2] }, { R[3], G[3], B[3] } }
  local inv = inverse3(m)
  if not inv then return nil end
  local Wx, Wy, Wz = xyz(C.D65[1], C.D65[2])
  local S = {}
  for k = 1, 3 do S[k] = inv[k][1] * Wx + inv[k][2] * Wy + inv[k][3] * Wz end
  local M = {}
  for r = 1, 3 do M[r] = { m[r][1] * S[1], m[r][2] * S[2], m[r][3] * S[3] } end
  return inverse3(M)
end

-- Parse "rx,ry,gx,gy,bx,by"; nil, reason when unusable.
function C.parse_primaries(text)
  local v = {}
  for n in tostring(text or ""):gmatch("[^,%s]+") do v[#v + 1] = tonumber(n) end
  if #v ~= 6 then return nil, "Custom Primaries needs six numbers: red x,y, green x,y, blue x,y" end
  for _, n in ipairs(v) do
    if not n or n <= 0 or n >= 1 then return nil, "Custom Primaries values must be CIE x/y between 0 and 1" end
  end
  if not C.space_matrix(v) then return nil, "Custom Primaries do not form a triangle" end
  return v
end

local function srgb_encode(c)
  if c <= 0.0031308 then return 12.92 * c end
  return 1.055 * c ^ (1 / 2.4) - 0.055
end

-- xy -> hue (0..360) and saturation (0..1) in the given colour space, the usual HSV definition on
-- transfer-encoded RGB (what apps and Control4's conversions mean by hue/saturation). Colours
-- outside the space are clipped to its edge, i.e. full saturation at that hue.
function C.xy_to_hs(x, y, primaries)
  local M = C.space_matrix(primaries or C.SPACES.srgb)
  if not M or not x or not y or y <= 0 then return 0, 0 end
  local X, Y, Z = xyz(x, y)
  local rgb = {}
  for k = 1, 3 do rgb[k] = math.max(0, M[k][1] * X + M[k][2] * Y + M[k][3] * Z) end
  local m = math.max(rgb[1], rgb[2], rgb[3])
  if m <= 0 then return 0, 0 end
  local r, g, b = srgb_encode(rgb[1] / m), srgb_encode(rgb[2] / m), srgb_encode(rgb[3] / m)
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local d = mx - mn
  local sat = mx > 0 and d / mx or 0
  if d <= 1e-9 then return 0, 0 end
  local h
  if mx == r then h = ((g - b) / d) % 6
  elseif mx == g then h = (b - r) / d + 2
  else h = (r - g) / d + 4 end
  return (h * 60) % 360, U.clamp(sat, 0, 1)
end

-- Gamma used for the intensity path. "Auto" = 2.2 when dimming is virtual (emitters scaled), 1.0
-- when the fixture has its own dimmer channel (the fixture applies its own curve).
function C.resolve_gamma(setting, has_dimmer)
  local g = tonumber(setting)
  if g and g > 0 then return g end
  return has_dimmer and 1.0 or 2.2
end

-- The core mix. layout: a compiled layout (layouts.lua). state: { level = 0..100, x, y, mode }.
-- opts: { white_mix = 0..1, gamma = number, rgb_white_mix = bool (default false),
--         space = primaries (Extended), hue_offset = degrees (Extended), cct_in_color = 0..1 }.
--
-- 2026-11-18 (Dave): RGB / RGBW / RGBWW behave as Control4's own DMX Light. Tunable white pairs
-- are normalised to their peak (Control4's ColorCCTtoMaxChannels); RGBW makes white from the W
-- LED alone (no R=G=B top-up); RGBWW makes colour from RGB and white from the whites. The one
-- departure is opt-in: rgb_white_mix adds R/G/B at the same colour temperature to an RGBWW's
-- white. (Max Brightness, the property this replaced, made RGBW whites from W + R=G=B; retired.)
--
-- Returns { role = fraction } for every intensity/color role the layout has.
function C.mix(layout, state, opts)
  opts = opts or {}
  local white_mix = U.clamp(tonumber(opts.white_mix) or 1.0, 0, 1)
  local rgb_white = opts.rgb_white_mix == true
  local gamma = tonumber(opts.gamma) or C.resolve_gamma(nil, layout.has_dimmer)
  local level = U.clamp((state.level or 0) / 100, 0, 1)
  local out = {}

  -- 1. Chromaticity -> emitter ratios at full brightness.
  local e = { red = 0, green = 0, blue = 0, white = 0, warm_white = 0, cool_white = 0 }
  local cct_fraction
  local mode = state.mode or C.MODE_CCT
  local x, y = state.x, state.y
  if not x or not y then
    if layout.supports_cct then
      x, y = C.kelvin_to_xy((layout.cct_min + layout.cct_max) / 2)
      mode = C.MODE_CCT
    else
      x, y, mode = C.D65[1], C.D65[2], C.MODE_FULL     -- no temperature control: plain white
    end
  end

  local kelvin = U.clamp(C.xy_to_kelvin(x, y), layout.cct_min, layout.cct_max)

  if layout.type == "dimmer" then
    -- nothing to mix
  elseif layout.extended then
    -- The fixture mixes. Colour: hue + saturation in the chosen space, CCT channel at its
    -- colour-mode value. CCT request: saturation 0 and the CCT channel carries the temperature.
    if mode == C.MODE_CCT and layout.has_cct then
      out.saturation = 0
      cct_fraction = (kelvin - layout.cct_min) / (layout.cct_max - layout.cct_min)
    else
      local h, sat = C.xy_to_hs(x, y, opts.space)
      out.hue = ((h + (tonumber(opts.hue_offset) or 0)) % 360) / 360
      out.saturation = sat
      cct_fraction = U.clamp(tonumber(opts.cct_in_color) or 1, 0, 1)
    end
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
      if peak > 0 then
        e.warm_white, e.cool_white = e.warm_white / peak, e.cool_white / peak
      end
      if rgb_white and layout.has_rgb then
        -- RGB White Mixing: R/G/B add the same colour temperature on top of the white LEDs.
        e.red, e.green, e.blue = C.xy_to_rgb(C.kelvin_to_xy(kelvin))
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
        -- Control4's RGBW: the white part is the white LED alone; normalise to the peak.
        local peak = math.max(r, g, b, w)
        if peak > 0 then r, g, b, w = r / peak, g / peak, b / peak, w / peak end
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
