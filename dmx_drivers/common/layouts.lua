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
local function concat(...)
  local out = {}
  for _, list in ipairs({ ... }) do
    for _, v in ipairs(list) do out[#out + 1] = v end
  end
  return out
end

-- dmx_light types say HOW a fixture maps onto Control4's controls, not which product it is
-- (Dave, 2026-10-10). Capabilities still come from the channels actually present, so the color
-- engine is unchanged; a type only filters the channel functions offered, supplies the starting
-- map, and flags the two special cases (On/Off, Manual Color).
--   mix_as   the id the color engine sees (color.lua special-cases "dimmer"; reusing it keeps that
--            file untouched for both single-color types)
--   switch   on/off only: light_v2 dimmer=false, any level > 0 outputs full, no fades
--   manual   brightness drives the Dimmer only; every color channel is an Extras slider, no picker
--   default  starting channel map when the type is chosen on a fresh or incompatible map
local INTENSITY = { "dimmer", "dimmer_fine" }
local EXTENDED = { "strobe", "strobe_duration", "zoom", "focus", "iris", "frost", "color_macro",
  "macro_speed", "program", "sound_sens" }
local EXTRA_EMITTERS = { "amber", "uv", "lime", "cyan" }
local COLOR_ROLES = concat(INTENSITY, { "red", "green", "blue", "white", "cct" }, EXTRA_EMITTERS,
  EXTENDED)   -- the movers' color set (unchanged)

local MOVER_WASH_ROLES = concat(COLOR_ROLES, { "pan", "pan_fine", "tilt", "tilt_fine", "pt_speed",
  "movement_macro", "reset" })

L.TYPES = {
  { id = "onoff",         label = "Single Color (On/Off)", driver = "light", mix_as = "dimmer", switch = true,
    roles = concat(INTENSITY, EXTENDED), default = { "dimmer" } },
  { id = "dimmer",        label = "Single Color Dimmable", driver = "light",
    roles = concat(INTENSITY, EXTENDED), default = { "dimmer" } },
  { id = "tunable_white", label = "Tunable White",         driver = "light",
    roles = concat(INTENSITY, { "warm_white", "cool_white", "cct" }, EXTENDED),
    default = { "warm_white", "cool_white" } },
  { id = "rgb",           label = "RGB",                   driver = "light",
    roles = concat(INTENSITY, { "red", "green", "blue" }, EXTRA_EMITTERS, EXTENDED),
    default = { "red", "green", "blue" } },
  { id = "rgbw",          label = "RGBW",                  driver = "light",
    roles = concat(INTENSITY, { "red", "green", "blue", "white" }, EXTRA_EMITTERS, EXTENDED),
    default = { "red", "green", "blue", "white" } },
  { id = "rgb_tw",        label = "RGB + Tunable White",   driver = "light",
    roles = concat(INTENSITY, { "red", "green", "blue", "warm_white", "cool_white", "white", "cct" },
      EXTRA_EMITTERS, EXTENDED),
    default = { "red", "green", "blue", "warm_white", "cool_white" } },
  { id = "manual",        label = "Manual Color",          driver = "light", manual = true,
    roles = concat(INTENSITY, { "red", "green", "blue", "white", "warm_white", "cool_white", "cct" },
      EXTRA_EMITTERS, EXTENDED),
    default = { "dimmer", "red", "green", "blue", "white" } },
  { id = "mover_wash",    label = "Moving Head Wash",      driver = "mover",
    roles = MOVER_WASH_ROLES },
  { id = "mover_spot",    label = "Moving Head Spot/Beam", driver = "mover",
    roles = concat(MOVER_WASH_ROLES, { "color_wheel", "gobo_wheel", "gobo_rotation", "prism",
      "focus", "iris", "frost" }) },
}

-- Types from before the 2026-10-10 redesign, still stored in installed projects. Resolved from
-- the channels the fixture already has, so an update never changes what a fixture outputs.
function L.legacy_type(label, channels)
  if label == "Dimmer" then return L.type_by_id("dimmer") end
  if label ~= "Color Par / Wash" and label ~= "Strobe / Effect" then return nil end
  local has = {}
  for _, ch in ipairs(channels or {}) do has[ch.role] = true end
  local rgb = has.red and has.green and has.blue
  if rgb and (has.warm_white or has.cool_white) then return L.type_by_id("rgb_tw") end
  if rgb and has.white then return L.type_by_id("rgbw") end
  if rgb then return L.type_by_id("rgb") end
  return L.type_by_id("rgbw")
end

-- The channels a type actually depends on: without them its Control4 controls have nothing to
-- drive (an "RGB + Tunable White" map with no RGB would show no color picker).
local NEEDS = {
  onoff = function(h) return h.dimmer end,
  dimmer = function(h) return h.dimmer end,
  tunable_white = function(h) return (h.warm_white and h.cool_white) or h.cct end,
  rgb = function(h) return h.red and h.green and h.blue end,
  rgbw = function(h) return h.red and h.green and h.blue and h.white end,
  rgb_tw = function(h) return h.red and h.green and h.blue and ((h.warm_white and h.cool_white) or h.cct) end,
  manual = function(h) return h.dimmer end,
}

-- Does a map suit type t: every channel allowed, and the channels the type depends on present?
-- Used to keep a map across a type change. Pixel channels count as part of the map.
function L.map_fits(t, channels, pixels)
  local all = L.all_channels(channels, pixels)
  if #all == 0 then return false end
  local h = {}
  for _, ch in ipairs(all) do
    if not t.allowed[ch.role] then return false end
    h[ch.role] = true
  end
  local need = NEEDS[t.id]
  return need == nil or need(h) and true or false
end

-- Every channel row of a definition: the fixture channels plus ONE copy of the pixel group.
function L.all_channels(channels, pixels)
  local out = {}
  for _, ch in ipairs(channels or {}) do out[#out + 1] = ch end
  if pixels then
    for _, ch in ipairs(pixels.channels or {}) do out[#out + 1] = ch end
  end
  return out
end

function L.default_channels(t)
  local out = {}
  for i, role in ipairs(t.default or { "dimmer" }) do out[i] = { role = role } end
  return out
end

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

-- dmx_light has no built-in layouts any more: a light is a Fixture Type plus a channel map
-- (Dave, 2026-10-10). Known maps for the bench fixtures are in the light's documentation.

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
L.MAX_CHANNELS = 32         -- fixture-channel rows (Channel N in Composer)
L.MAX_PIXEL_CHANNELS = 12   -- rows in one pixel's group (Pixel Channel N)
L.MAX_PIXELS = 512          -- the universe is the real limit; this only bounds the property
L.UNIVERSE = 512
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

-- Pixels: ONE group written "18x(red,green,blue,white)" (also "18 x (...)" or "18*(...)")
-- repeats its channels 18 times, in place. Channels before the group come before the pixels on
-- the wire, channels after it come after the last pixel:
--   "dimmer,strobe,4x(red,green,blue),program"  =  Dimmer, Strobe, 4 x RGB, Program
-- Returns channels (the fixture channels), pixels ({count, at, channels} or nil). `at` = how many
-- fixture channels come before the pixels. "1x(...)" is no pixels: inlined, pixels = nil.

-- Parse one comma list. `what` names the row kind in errors ("channel", "pixel channel").
local function parse_items(text, what, number_from, out)
  local items = U.split(text, ",")
  for i, item in ipairs(items) do
    local n = number_from + i - 1
    item = U.trim(item)
    if item == "" then return nil, string.format("%s %d is empty", what, n) end
    local name, default = item:match("^([^:]+):(.+)$")
    name = name or item
    local role = L.role_from_text(name)
    if not role then return nil, string.format("%s %d: unknown function '%s'", what, n, name) end
    local ch = { role = role }
    if default then
      local d = tonumber(U.trim(default))
      if not d or d < 0 or d > 255 or d ~= math.floor(d) then
        return nil, string.format("%s %d: default '%s' is not 0-255", what, n, default)
      end
      ch.default = d
    end
    out[#out + 1] = ch
  end
  return out
end

-- Strip the comma that joins a section to the pixel group; "" stays "".
local function strip_joint(s, side)
  s = U.trim(s)
  if side == "before" then
    if s == "" then return s end
    if s:sub(-1) ~= "," then return nil end
    return U.trim(s:sub(1, -2))
  end
  if s == "" then return s end
  if s:sub(1, 1) ~= "," then return nil end
  return U.trim(s:sub(2))
end

function L.parse_map(text)
  text = tostring(text or "")
  local _, opens = text:gsub("%(", "")
  if opens > 1 then return nil, "only one pixel group is allowed, e.g. dimmer,18x(red,green,blue)" end
  if opens == 0 then
    local channels, err = parse_items(text, "channel", 1, {})
    if not channels then return nil, err end
    if #channels == 0 then return nil, "the channel map is empty" end
    return channels
  end

  local pre, count, inner, post = text:match("^(.-)(%d+)%s*[xX%*]%s*%((.-)%)(.*)$")
  if not pre then
    return nil, "pixel group not understood: write it as a count, x, and the pixel's channels in brackets, e.g. 18x(red,green,blue,white)"
  end
  local before, after = strip_joint(pre, "before"), strip_joint(post, "after")
  if not before or not after then
    return nil, "separate the pixel group from the other channels with commas, e.g. dimmer,18x(red,green,blue),strobe"
  end
  count = tonumber(count)
  if count < 1 or count > L.MAX_PIXELS then
    return nil, string.format("pixel count %d is outside 1-%d", count, L.MAX_PIXELS)
  end

  local channels, err = parse_items(before, "channel", 1, {})
  if not channels then return nil, err end
  local at = #channels
  local pixel_channels
  pixel_channels, err = parse_items(inner, "pixel channel", 1, {})
  if not pixel_channels then return nil, err end
  if #pixel_channels == 0 then return nil, "the pixel group has no channels" end
  channels, err = parse_items(after, "channel", at + 1, channels)
  if not channels then return nil, err end

  if count == 1 then
    return L.flatten(channels, { count = 1, at = at, channels = pixel_channels })
  end
  return channels, { count = count, at = at, channels = pixel_channels }
end

local function format_items(channels, parts, first, last)
  for i = first, last do
    local ch = channels[i]
    if ch.default and ch.default ~= 0 then
      parts[#parts + 1] = ch.role .. ":" .. U.int(ch.default)
    else
      parts[#parts + 1] = ch.role
    end
  end
  return parts
end

-- Without pixels this is the original format, character for character (installed projects store
-- it, and it is the copy-between-projects text).
function L.format_map(channels, pixels)
  if not pixels or (pixels.count or 1) < 2 then
    if pixels then channels = L.flatten(channels, pixels) end
    return table.concat(format_items(channels, {}, 1, #channels), ",")
  end
  local at = U.clamp(pixels.at or #channels, 0, #channels)
  local parts = format_items(channels, {}, 1, at)
  parts[#parts + 1] = string.format("%dx(%s)", pixels.count,
    table.concat(format_items(pixels.channels, {}, 1, #pixels.channels), ","))
  format_items(channels, parts, at + 1, #channels)
  return table.concat(parts, ",")
end

-- One pixel is no pixels: the group's channels inlined where the group sat.
function L.flatten(channels, pixels)
  if not pixels then return channels end
  local at = U.clamp(pixels.at or #channels, 0, #channels)
  local out = {}
  for i = 1, at do out[#out + 1] = channels[i] end
  for _, ch in ipairs(pixels.channels or {}) do out[#out + 1] = ch end
  for i = at + 1, #channels do out[#out + 1] = channels[i] end
  return out
end

-- Turning pixels ON for an existing single-cell map: guess which channels repeat per pixel.
-- The repeating part is the longest run of color channels (emitters, CCT, Amber/UV/...), or for a
-- single-color type the dimmer (with its fine channel); everything else stays a fixture channel.
-- So "dimmer,red,green,blue,white,strobe" becomes Dimmer + N x RGBW + Strobe, and a 4ch par map
-- becomes N x RGBW. With no such run the type's starting map becomes the pixel group.
local PIXEL_GROUPS = { color = true, color_extra = true }
function L.split_for_pixels(channels, t)
  local best_first, best_len, first = nil, 0, nil
  for i = 1, #channels + 1 do
    local ch = channels[i]
    local ok = ch and PIXEL_GROUPS[L.ROLES[ch.role].group]
    if ok and not first then first = i end
    if not ok and first then
      if i - first > best_len then best_first, best_len = first, i - first end
      first = nil
    end
  end
  if not best_first and (t.id == "dimmer" or t.mix_as == "dimmer") then
    for i, ch in ipairs(channels) do
      if ch.role == "dimmer" then
        best_first, best_len = i, (channels[i + 1] and channels[i + 1].role == "dimmer_fine") and 2 or 1
        break
      end
    end
  end
  if not best_first then
    local pix = L.default_channels(t)
    local taken, fixture = {}, {}
    for _, ch in ipairs(pix) do taken[ch.role] = true end
    for _, ch in ipairs(channels) do
      if not taken[ch.role] and ch.role ~= "unused" then fixture[#fixture + 1] = ch end
    end
    return fixture, { at = #fixture, channels = pix }
  end
  local fixture, pix = {}, {}
  for i, ch in ipairs(channels) do
    if i >= best_first and i < best_first + best_len then pix[#pix + 1] = ch else fixture[#fixture + 1] = ch end
  end
  return fixture, { at = best_first - 1, channels = pix }
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
  local px = def.pixels
  if px and (px.count or 1) < 2 then        -- one pixel is no pixels
    channels, px = L.flatten(channels, px), nil
  end
  if px and t.driver == "mover" then return nil, "a moving head cannot have pixels" end
  if px and #(px.channels or {}) == 0 then return nil, "the pixel group has no channels" end
  if px and #px.channels > L.MAX_PIXEL_CHANNELS then
    return nil, string.format("a pixel has %d channels; the maximum is %d", #px.channels, L.MAX_PIXEL_CHANNELS)
  end
  if #channels < 1 and not px then return nil, "the layout has no channels" end
  if #channels > L.MAX_CHANNELS then
    return nil, string.format("the layout has %d %schannels; the maximum is %d", #channels,
      px and "fixture " or "", L.MAX_CHANNELS)
  end
  local at = px and U.clamp(math.floor(tonumber(px.at) or #channels), 0, #channels) or #channels
  local total = #channels + (px and px.count * #px.channels or 0)
  if total > L.UNIVERSE then
    return nil, string.format("%d pixels x %d channels%s = %d channels, more than a DMX universe holds (%d)",
      px.count, #px.channels, #channels > 0 and (" + " .. #channels .. " fixture channels") or "", total, L.UNIVERSE)
  end

  local layout = {
    id = def.id or L.CUSTOM_ID,
    label = def.label or L.CUSTOM_LABEL,
    type = t.mix_as or t.id,       -- what the color engine sees (see L.TYPES)
    type_id = t.id,
    switch = t.switch or false,
    manual = t.manual or false,
    driver = t.driver,
    verified = def.verified or def.generic or false,
    channels = {},
    count = total,
    roles = {},                     -- role -> 0-based offset (first occurrence; pixel 1's copy)
    offsets = {},                   -- role -> every offset it occupies (all pixel copies)
    fixture_count = #channels,
    pixel_count = px and px.count or 0,
    pixel_size = px and #px.channels or 0,
    pixel_at = px and at or nil,    -- offset of pixel 1's first channel
    pixel_channels = px and px.channels or nil,
    pixel_def = px and { count = px.count, at = at, channels = px.channels } or nil,
    fixture_channels = channels,
    pan_degrees = def.pan_degrees,
    tilt_degrees = def.tilt_degrees,
    cct_min = opts.cct_min or def.cct_min or L.DEFAULT_CCT_MIN,
    cct_max = opts.cct_max or def.cct_max or L.DEFAULT_CCT_MAX,
  }

  -- Validate the ROWS (each fixture channel once, the pixel group once): a role may appear once
  -- across both. Errors name the row as Composer shows it.
  local rows, where = {}, {}       -- where[role] = "channel 3" / "pixel channel 2"
  for i, src in ipairs(channels) do rows[#rows + 1] = { src = src, name = "channel " .. i, pixel = false } end
  if px then
    for j, src in ipairs(px.channels) do rows[#rows + 1] = { src = src, name = "pixel channel " .. j, pixel = true } end
  end
  local in_pixel = {}
  for _, row in ipairs(rows) do
    local role = row.src.role
    local r = L.ROLES[role]
    if not r then return nil, string.format("%s: unknown function '%s'", row.name, tostring(role)) end
    if not t.allowed[role] then
      return nil, string.format("%s: '%s' is not available for Fixture Type %s", row.name, r.label, t.label)
    end
    if where[role] and not r.repeatable then
      return nil, string.format("%s: '%s' is already on %s", row.name, r.label, where[role])
    end
    where[role] = where[role] or row.name
    in_pixel[role] = row.pixel
  end
  for role, name in pairs(where) do
    local coarse = L.ROLES[role].fine_of
    if coarse and not where[coarse] then
      return nil, string.format("%s: '%s' needs a '%s' channel", name, L.ROLES[role].label, L.ROLES[coarse].label)
    end
    if coarse and in_pixel[coarse] ~= in_pixel[role] then
      return nil, string.format("%s: '%s' and '%s' must both be pixel channels or both fixture channels",
        name, L.ROLES[role].label, L.ROLES[coarse].label)
    end
  end

  -- Expand onto the wire: fixture channels before the pixels, every pixel, the rest.
  local function add(src, pixel)
    local i = #layout.channels + 1
    local ch = U.copy(src)
    local r = L.ROLES[ch.role]
    ch.offset = i - 1
    ch.default = ch.default or 0
    ch.label = r.label
    ch.group = r.group
    ch.pixel = pixel
    layout.channels[i] = ch
    if not layout.roles[ch.role] then layout.roles[ch.role] = i - 1 end
    if not r.repeatable then
      layout.offsets[ch.role] = layout.offsets[ch.role] or {}
      table.insert(layout.offsets[ch.role], i - 1)
    end
  end
  for i = 1, at do add(channels[i]) end
  if px then
    for p = 1, px.count do
      for _, src in ipairs(px.channels) do add(src, p) end
    end
  end
  for i = at + 1, #channels do add(channels[i]) end
  if layout.cct_min >= layout.cct_max then
    return nil, string.format("CCT Min (%dK) must be below CCT Max (%dK)", layout.cct_min, layout.cct_max)
  end
  if t.driver == "mover" and not (layout.roles.pan or layout.roles.tilt) then
    return nil, "a moving head layout needs at least a Pan or Tilt channel"
  end

  -- Coarse/fine pairs the node must fade as one 16-bit value (brief 3.2 PAIRS). One per pixel
  -- when the pair repeats (both are in the same group, checked above).
  layout.pairs = {}
  for _, coarse in ipairs({ "dimmer", "pan", "tilt" }) do
    local fine = coarse .. "_fine"
    if layout.roles[coarse] and layout.roles[fine] then
      local cs, fs = layout.offsets[coarse], layout.offsets[fine]
      for k = 1, #cs do
        layout.pairs[#layout.pairs + 1] = { coarse = cs[k], fine = fs[k], role = coarse }
      end
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
  if t.id == "dimmer" or t.switch or t.manual then
    layout.supports_color = false
    layout.supports_cct = false
  end
  if t.manual and not layout.has_dimmer then
    return nil, "Manual Color needs a Dimmer channel: it is the only channel the brightness controls drive"
  end
  -- A fixture with only a white emitter and no dimmer still dims: the white channel IS the dimmer.
  layout.controllable = layout.has_dimmer or layout.has_rgb or layout.has_white or layout.has_ww_cw
    or has("red") or has("green") or has("blue")
  if t.manual then layout.controllable = layout.has_dimmer end

  -- Roles controlled on the Extras tab (dmx_light) or the mover's Extras.
  layout.extras = {}
  for _, ch in ipairs(layout.channels) do
    local g = ch.group
    if (g == "beam" or g == "effects" or g == "maintenance" or g == "color_extra"
        or (layout.manual and g == "color")
        or (g == "position" and ch.role == "pt_speed")) and layout.roles[ch.role] == ch.offset then
      layout.extras[#layout.extras + 1] = ch
    end
  end
  return layout
end

-- Footprint text for Composer, e.g. "DMX 17-32 (16 ch)", "DMX 1-72 (72 ch, 18 pixels)".
function L.footprint_text(start, count, pixels)
  local px = (pixels and pixels > 1) and string.format(", %d pixels", pixels) or ""
  if count == 1 then return string.format("DMX %d (1 ch)", start) end
  return string.format("DMX %d-%d (%d ch%s)", start, start + count - 1, count, px)
end

-- Layout Summary for Composer: what is on each channel, numbered as fixture manuals number them
-- (Ch 1 = the Start Address), so it can be read against the manual line by line.
--   "Ch 1 Dimmer | Ch 2 Strobe/Shutter | Ch 3-74 18 pixels x 4 ch: Red, Green, Blue, White | Ch 75 Program/Auto"
local function channel_text(ch)
  if ch.role == "fixed" then return "Fixed " .. U.int(ch.default or 0) end
  return ch.label
end

function L.summary(layout)
  if not layout then return "" end
  local parts = {}
  local function fixture_part(ch)
    parts[#parts + 1] = string.format("Ch %d %s", ch.offset + 1, channel_text(ch))
  end
  local i = 1
  while i <= #layout.channels do
    local ch = layout.channels[i]
    if ch.pixel then
      local first, last = ch.offset + 1, ch.offset + layout.pixel_count * layout.pixel_size
      local names = {}
      for j = i, i + layout.pixel_size - 1 do names[#names + 1] = channel_text(layout.channels[j]) end
      parts[#parts + 1] = string.format("Ch %d-%d %d pixels x %d ch: %s", first, last,
        layout.pixel_count, layout.pixel_size, table.concat(names, ", "))
      i = i + layout.pixel_count * layout.pixel_size
    else
      fixture_part(ch)
      i = i + 1
    end
  end
  return table.concat(parts, " | ")
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
