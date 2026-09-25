-- layouts.lua -- the role catalogue, fixture types, built-in channel layouts and the compiler
-- that turns any of them (or a Custom channel map) into ONE runtime shape.
--
-- Everything downstream (color engine, extras, presets, the node registration) sees only a
-- compiled layout, so a built-in and a Custom map that describe the same fixture behave
-- identically.

local U = require "util"

local L = {}

---------------------------------------------------------------------------------------------
-- Roles. `group` decides where a role is controlled:
--   intensity / color  -> the light_v2 load (brightness slider, color picker)
--   color_extra        -> emitters with no place in xy color space (Amber, UV, Lime, Cyan):
--                         Extras sliders in v1, see the brief's section 7.3
--   position           -> mover pan/tilt engine
--   beam / effects     -> Extras controls
--   maintenance        -> Extras buttons (Reset)
--   fixed / unused     -> never controlled, always output their default
---------------------------------------------------------------------------------------------
L.ROLES = {
  dimmer          = { label = "Dimmer",            group = "intensity" },
  dimmer_fine     = { label = "Dimmer Fine",       group = "intensity", fine_of = "dimmer" },
  red             = { label = "Red",               group = "color" },
  green           = { label = "Green",             group = "color" },
  blue            = { label = "Blue",              group = "color" },
  white           = { label = "White",             group = "color" },
  warm_white      = { label = "Warm White",        group = "color" },
  cool_white      = { label = "Cool White",        group = "color" },
  cct             = { label = "CCT",               group = "color" },
  amber           = { label = "Amber",             group = "color_extra" },
  uv              = { label = "UV",                group = "color_extra" },
  lime            = { label = "Lime",              group = "color_extra" },
  cyan            = { label = "Cyan",              group = "color_extra" },
  strobe          = { label = "Strobe/Shutter",    group = "beam" },
  strobe_duration = { label = "Strobe Duration",   group = "beam" },
  zoom            = { label = "Zoom",              group = "beam" },
  focus           = { label = "Focus",             group = "beam" },
  iris            = { label = "Iris",              group = "beam" },
  frost           = { label = "Frost",             group = "beam" },
  prism           = { label = "Prism",             group = "beam" },
  color_wheel     = { label = "Color Wheel",       group = "beam" },
  gobo_wheel      = { label = "Gobo Wheel",        group = "beam" },
  gobo_rotation   = { label = "Gobo Rotation",     group = "beam" },
  color_macro     = { label = "Color Macro",       group = "effects" },
  macro_speed     = { label = "Macro Speed",       group = "effects" },
  program         = { label = "Program/Auto",      group = "effects" },
  sound_sens      = { label = "Sound Sensitivity", group = "effects" },
  movement_macro  = { label = "Movement Macro",    group = "effects" },
  pan             = { label = "Pan",               group = "position" },
  pan_fine        = { label = "Pan Fine",          group = "position", fine_of = "pan" },
  tilt            = { label = "Tilt",              group = "position" },
  tilt_fine       = { label = "Tilt Fine",         group = "position", fine_of = "tilt" },
  pt_speed        = { label = "Pan/Tilt Speed",    group = "position" },
  reset           = { label = "Reset/Control",     group = "maintenance" },
  fixed           = { label = "Fixed Value",       group = "fixed",  repeatable = true },
  unused          = { label = "Unused",            group = "unused", repeatable = true },
}

-- Emitters the color engine drives from light_v2 xy/CCT.
L.MIXED_EMITTERS = { red = true, green = true, blue = true, white = true, warm_white = true, cool_white = true }

-- Display order for any list of roles (Composer dropdowns, Extras sections).
L.ROLE_ORDER = {
  "dimmer", "dimmer_fine", "red", "green", "blue", "white", "warm_white", "cool_white", "cct",
  "amber", "uv", "lime", "cyan", "strobe", "strobe_duration", "zoom", "focus", "iris", "frost",
  "prism", "color_wheel", "gobo_wheel", "gobo_rotation", "color_macro", "macro_speed", "program",
  "sound_sens", "movement_macro", "pan", "pan_fine", "tilt", "tilt_fine", "pt_speed", "reset",
  "fixed", "unused",
}

---------------------------------------------------------------------------------------------
-- Fixture types. `driver` is which c4z offers the type: a par must never be able to become a
-- mover, because the mover's extra controls only exist in dmx_mover.
---------------------------------------------------------------------------------------------
local COLOR_ROLES = { "dimmer", "dimmer_fine", "red", "green", "blue", "white", "amber", "uv", "lime",
  "cyan", "cct", "strobe", "zoom", "color_macro", "macro_speed", "program", "sound_sens" }

local function concat(...)
  local out = {}
  for _, list in ipairs({ ... }) do
    for _, v in ipairs(list) do out[#out + 1] = v end
  end
  return out
end

local MOVER_WASH_ROLES = concat(COLOR_ROLES, { "pan", "pan_fine", "tilt", "tilt_fine", "pt_speed",
  "movement_macro", "reset" })

L.TYPES = {
  { id = "dimmer",        label = "Dimmer",                driver = "light",
    roles = { "dimmer", "dimmer_fine" } },
  { id = "tunable_white", label = "Tunable White",         driver = "light",
    roles = { "dimmer", "dimmer_fine", "warm_white", "cool_white", "cct", "strobe" } },
  { id = "color",         label = "Color Par / Wash",      driver = "light",
    roles = COLOR_ROLES },
  { id = "strobe",        label = "Strobe / Effect",       driver = "light",
    roles = { "dimmer", "dimmer_fine", "strobe", "strobe_duration", "program", "macro_speed",
      "sound_sens", "red", "green", "blue", "white", "amber", "uv" } },
  { id = "mover_wash",    label = "Moving Head Wash",      driver = "mover",
    roles = MOVER_WASH_ROLES },
  { id = "mover_spot",    label = "Moving Head Spot/Beam", driver = "mover",
    roles = concat(MOVER_WASH_ROLES, { "color_wheel", "gobo_wheel", "gobo_rotation", "prism",
      "focus", "iris", "frost" }) },
}

for _, t in ipairs(L.TYPES) do
  t.roles[#t.roles + 1] = "fixed"
  t.roles[#t.roles + 1] = "unused"
  t.allowed = {}
  for _, r in ipairs(t.roles) do t.allowed[r] = true end
end

function L.type_by_id(id)
  for _, t in ipairs(L.TYPES) do if t.id == id then return t end end
end

function L.type_by_label(label)
  for _, t in ipairs(L.TYPES) do if t.label == label then return t end end
end

function L.types_for_driver(driver)
  local out = {}
  for _, t in ipairs(L.TYPES) do if t.driver == driver then out[#out + 1] = t end end
  return out
end

---------------------------------------------------------------------------------------------
-- Built-in layouts. DATA ONLY: add a fixture by appending an entry.
--
-- `verified` is set true ONLY after the layout has been checked against the real fixture on the
-- bench. An unverified layout is still selectable, and its label says so in Composer.
-- `generic` layouts describe a channel arrangement, not a product, so there is nothing to verify.
---------------------------------------------------------------------------------------------
L.BUILTIN = {}
L.BUILTIN_ORDER = {}

local function builtin(id, def)
  def.id = id
  L.BUILTIN[id] = def
  L.BUILTIN_ORDER[#L.BUILTIN_ORDER + 1] = id
end

builtin("generic_dimmer_8", { label = "Generic Dimmer (1ch)", type = "dimmer", generic = true,
  channels = { { role = "dimmer" } } })
builtin("generic_dimmer_16", { label = "Generic Dimmer 16-bit (2ch)", type = "dimmer", generic = true,
  channels = { { role = "dimmer" }, { role = "dimmer_fine" } } })
builtin("generic_tw_2", { label = "Generic Tunable White WW/CW (2ch)", type = "tunable_white", generic = true,
  channels = { { role = "warm_white" }, { role = "cool_white" } } })
builtin("generic_tw_3", { label = "Generic Tunable White Dim/WW/CW (3ch)", type = "tunable_white", generic = true,
  channels = { { role = "dimmer" }, { role = "warm_white" }, { role = "cool_white" } } })
builtin("generic_rgb_3", { label = "Generic RGB (3ch)", type = "color", generic = true,
  channels = { { role = "red" }, { role = "green" }, { role = "blue" } } })
builtin("generic_rgbw_4", { label = "Generic RGBW (4ch)", type = "color", generic = true,
  channels = { { role = "red" }, { role = "green" }, { role = "blue" }, { role = "white" } } })
builtin("generic_drgbw_5", { label = "Generic Dimmer+RGBW (5ch)", type = "color", generic = true,
  channels = { { role = "dimmer" }, { role = "red" }, { role = "green" }, { role = "blue" }, { role = "white" } } })

-- DazzlingStage mini par 4x8W RGBW. The listing only says "4/8 CH" and no public chart exists.
-- These are the TYPICAL layouts for this OEM family and MUST be checked against the paper manual
-- that ships with the lights (brief 6.2). Custom covers any difference immediately.
builtin("dazzlingstage_rgbw_4", { label = "DazzlingStage Mini Par RGBW (4ch)", type = "color", verified = false,
  channels = { { role = "red" }, { role = "green" }, { role = "blue" }, { role = "white" } } })
builtin("dazzlingstage_rgbw_8", { label = "DazzlingStage Mini Par RGBW (8ch)", type = "color", verified = false,
  channels = {
    { role = "dimmer" }, { role = "red" }, { role = "green" }, { role = "blue" }, { role = "white" },
    { role = "strobe", default = 0 },
    { role = "program", steps = { { "Manual (DMX)", 0 } } },
    { role = "macro_speed" },
  } })

-- ColorKey Mover MiniWash Quad 4 MKII. Source: ColorKey MKII manual (B&H copy). Unverified points
-- (brief 11 #9): does strobe 0 mean "no strobe"; which way does speed run; how long must reset be
-- held. Defaults below are the manual's reading; bench-check before setting verified=true.
local COLORKEY_TAIL = {
  { role = "movement_macro", steps = { { "Off", 0 }, { "Auto (fast)", 16, 128 }, { "Auto + Sound (slow)", 129, 255 } } },
  { role = "sound_sens" },
  { role = "color_macro", steps = { { "Off", 0 }, { "Color change", 1, 140 }, { "Sound color", 141, 255 } } },
  { role = "macro_speed", max = 250 },
  { role = "reset", reset_value = 255, reset_hold_ms = 5000 },
}
builtin("colorkey_miniwash_quad4_mk2_16", { label = "ColorKey MiniWash Quad 4 MKII (16ch)", type = "mover_wash",
  verified = false, pan_degrees = 540, tilt_degrees = 270,
  channels = concat({
    { role = "pan" }, { role = "pan_fine" }, { role = "tilt" }, { role = "tilt_fine" },
    { role = "pt_speed", invert = false },
    { role = "dimmer" }, { role = "strobe", default = 0 },
    { role = "red" }, { role = "green" }, { role = "blue" }, { role = "white" },
  }, COLORKEY_TAIL) })
builtin("colorkey_miniwash_quad4_mk2_14", { label = "ColorKey MiniWash Quad 4 MKII (14ch)", type = "mover_wash",
  verified = false, pan_degrees = 540, tilt_degrees = 270,
  channels = concat({
    { role = "pan" }, { role = "tilt" }, { role = "pt_speed", invert = false },
    { role = "dimmer" }, { role = "strobe", default = 0 },
    { role = "red" }, { role = "green" }, { role = "blue" }, { role = "white" },
  }, COLORKEY_TAIL) })

L.CUSTOM_ID = "custom"
L.CUSTOM_LABEL = "Custom"
L.MAX_CHANNELS = 32
L.DEFAULT_CCT_MIN = 2700
L.DEFAULT_CCT_MAX = 6500

-- What Composer shows for a built-in. The suffix is the dealer's only cue that a layout came
-- from a manual reading nobody has checked against the fixture yet.
function L.display_label(def)
  if def.generic or def.verified then return def.label end
  return def.label .. " (unverified)"
end

function L.builtins_for_type(type_id)
  local out = {}
  for _, id in ipairs(L.BUILTIN_ORDER) do
    if L.BUILTIN[id].type == type_id then out[#out + 1] = L.BUILTIN[id] end
  end
  return out
end

function L.builtin_by_display_label(label)
  for _, id in ipairs(L.BUILTIN_ORDER) do
    local def = L.BUILTIN[id]
    if L.display_label(def) == label or def.label == label then return def end
  end
end

---------------------------------------------------------------------------------------------
-- Channel map text: "pan,pan_fine,tilt,strobe:8,fixed:255". `role` or `role:default`.
-- Role ids OR labels are accepted on input so a dealer can paste either.
---------------------------------------------------------------------------------------------
local LABEL_TO_ROLE = {}
for id, r in pairs(L.ROLES) do
  LABEL_TO_ROLE[string.lower(r.label)] = id
  LABEL_TO_ROLE[id] = id
end

function L.role_from_text(s)
  return LABEL_TO_ROLE[string.lower(U.trim(s))]
end

function L.parse_map(text)
  local channels = {}
  for i, item in ipairs(U.split(text, ",")) do
    item = U.trim(item)
    if item == "" then return nil, string.format("channel %d is empty", i) end
    local name, default = item:match("^([^:]+):(.+)$")
    name = name or item
    local role = L.role_from_text(name)
    if not role then return nil, string.format("channel %d: unknown function '%s'", i, name) end
    local ch = { role = role }
    if default then
      local d = tonumber(U.trim(default))
      if not d or d < 0 or d > 255 or d ~= math.floor(d) then
        return nil, string.format("channel %d: default '%s' is not 0-255", i, default)
      end
      ch.default = d
    end
    channels[#channels + 1] = ch
  end
  if #channels == 0 then return nil, "the channel map is empty" end
  return channels
end

function L.format_map(channels)
  local parts = {}
  for _, ch in ipairs(channels) do
    if ch.default and ch.default ~= 0 then
      parts[#parts + 1] = ch.role .. ":" .. U.int(ch.default)
    else
      parts[#parts + 1] = ch.role
    end
  end
  return table.concat(parts, ",")
end

---------------------------------------------------------------------------------------------
-- Compile a definition (built-in or custom) into the runtime layout. Returns nil, reason on any
-- configuration error; the caller refuses the change and shows the reason in Status.
---------------------------------------------------------------------------------------------
function L.compile(def, type_id, opts)
  opts = opts or {}
  local t = L.type_by_id(type_id or def.type)
  if not t then return nil, "unknown fixture type '" .. tostring(type_id or def.type) .. "'" end
  local channels = def.channels or {}
  if #channels < 1 then return nil, "the layout has no channels" end
  if #channels > L.MAX_CHANNELS then
    return nil, string.format("the layout has %d channels; the maximum is %d", #channels, L.MAX_CHANNELS)
  end

  local layout = {
    id = def.id or L.CUSTOM_ID,
    label = def.label or L.CUSTOM_LABEL,
    type = t.id,
    driver = t.driver,
    verified = def.verified or def.generic or false,
    channels = {},
    count = #channels,
    roles = {},                     -- role -> 0-based offset (first occurrence)
    pan_degrees = def.pan_degrees,
    tilt_degrees = def.tilt_degrees,
    cct_min = opts.cct_min or def.cct_min or L.DEFAULT_CCT_MIN,
    cct_max = opts.cct_max or def.cct_max or L.DEFAULT_CCT_MAX,
  }

  for i, src in ipairs(channels) do
    local role = src.role
    local r = L.ROLES[role]
    if not r then return nil, string.format("channel %d: unknown function '%s'", i, tostring(role)) end
    if not t.allowed[role] then
      return nil, string.format("channel %d: '%s' is not available for a %s", i, r.label, t.label)
    end
    if layout.roles[role] and not r.repeatable then
      return nil, string.format("channel %d: '%s' is already on channel %d", i, r.label, layout.roles[role] + 1)
    end
    local ch = U.copy(src)
    ch.offset = i - 1
    ch.default = ch.default or 0
    ch.label = r.label
    ch.group = r.group
    layout.channels[i] = ch
    if not layout.roles[role] then layout.roles[role] = i - 1 end
  end

  for role, offset in pairs(layout.roles) do
    local coarse = L.ROLES[role].fine_of
    if coarse and not layout.roles[coarse] then
      return nil, string.format("channel %d: '%s' needs a '%s' channel", offset + 1,
        L.ROLES[role].label, L.ROLES[coarse].label)
    end
  end
  if layout.cct_min >= layout.cct_max then
    return nil, string.format("CCT Min (%dK) must be below CCT Max (%dK)", layout.cct_min, layout.cct_max)
  end
  if t.driver == "mover" and not (layout.roles.pan or layout.roles.tilt) then
    return nil, "a moving head layout needs at least a Pan or Tilt channel"
  end

  -- Coarse/fine pairs the node must fade as one 16-bit value (brief 3.2 PAIRS).
  layout.pairs = {}
  for _, coarse in ipairs({ "dimmer", "pan", "tilt" }) do
    local fine = coarse .. "_fine"
    if layout.roles[coarse] and layout.roles[fine] then
      layout.pairs[#layout.pairs + 1] = { coarse = layout.roles[coarse], fine = layout.roles[fine], role = coarse }
    end
  end

  -- Capability summary used by the light engine and Composer.
  local has = function(role) return layout.roles[role] ~= nil end
  layout.has_dimmer = has("dimmer")
  layout.has_rgb = has("red") and has("green") and has("blue")
  layout.has_white = has("white")
  layout.has_ww_cw = has("warm_white") and has("cool_white")
  layout.has_cct = has("cct")
  layout.supports_color = layout.has_rgb
  layout.supports_cct = layout.has_cct or layout.has_ww_cw or layout.has_rgb or layout.has_white
  if t.id == "dimmer" then
    layout.supports_color = false
    layout.supports_cct = false
  end
  -- A fixture with only a white emitter and no dimmer still dims: the white channel IS the dimmer.
  layout.controllable = layout.has_dimmer or layout.has_rgb or layout.has_white or layout.has_ww_cw
    or has("red") or has("green") or has("blue")

  -- Roles controlled on the Extras tab (dmx_light) or the mover's Extras.
  layout.extras = {}
  for _, ch in ipairs(layout.channels) do
    local g = ch.group
    if (g == "beam" or g == "effects" or g == "maintenance" or g == "color_extra"
        or (g == "position" and ch.role == "pt_speed")) and layout.roles[ch.role] == ch.offset then
      layout.extras[#layout.extras + 1] = ch
    end
  end
  return layout
end

-- Footprint text for Composer, e.g. "DMX 17-32 (16 ch)".
function L.footprint_text(start, count)
  if count == 1 then return string.format("DMX %d (1 ch)", start) end
  return string.format("DMX %d-%d (%d ch)", start, start + count - 1, count)
end

function L.check_start(start, count)
  if start < 1 or start > 512 then return false, "Start Address must be 1-512" end
  if start + count - 1 > 512 then
    return false, string.format("a %d-channel fixture starting at %d would end at %d, past the end of the universe (512)",
      count, start, start + count - 1)
  end
  return true
end

-- Step helpers for built-in stepped roles. Each step is {label, value} or {label, lo, hi}; the
-- value sent is the low end of the range (or the single value), which is what the manuals list.
function L.step_value(step)
  return step[2]
end

function L.step_for_value(steps, value)
  for i, step in ipairs(steps) do
    local lo, hi = step[2], step[3] or step[2]
    if value >= lo and value <= hi then return i, step end
  end
end

return L
