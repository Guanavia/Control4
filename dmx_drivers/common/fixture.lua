-- fixture.lua -- everything dmx_light and dmx_mover share: Composer properties, the layout
-- lifecycle, registration with the Art-Net node, output diffing, persistence, the light_v2 load
-- and the Extras tab. The mover adds position and presets through the hooks in F.ext.
--
-- A fixture NEVER touches the network. It computes channel values and sends them to its node
-- with DMX_UPDATE; the node does all fading and output.
--
-- Output model: every change updates intent (light state, extras values, position), then
-- F.refresh(fade) recomputes the whole footprint from intent and sends only the offsets that
-- differ from what the node already has. One code path for every source of change.

local U = require "util"
local L = require "layouts"
local C = require "color"
local P = require "protocol"
local X = require "extras"
local Light = require "light"

-- Declared only by dmx_mover's driver.xml; nil (and defaulted) in dmx_light:
-- @optional-properties: Reset Value, Reset Hold (ms), Layout
-- Declared only by dmx_light's driver.xml (pixels); nil in dmx_mover, which never has pixels:
-- @optional-properties: Pixel Count, Channels Per Pixel, Fixture Channels Before Pixels, Layout Summary, Gateway Line
-- @optional-properties: Tunable White Mode, Color Space, Custom Primaries, Hue Offset (deg), CCT In Color Mode

local F = {
  kind = "light",
  layout = nil,          -- compiled, currently running layout
  start = nil,           -- start address the running layout is registered at
  sent = {},             -- offset -> value the node currently holds for us
  extra = {},            -- role -> 0..255 raw value for Extras-controlled roles
  node_id = nil,
  gw_id = nil,           -- bound DMX gateway driver (second input; dmx_light only)
  gw_lines = nil,        -- DMX-capable gateway lines from LINES_INFO, e.g. {1, 2}; nil = not told yet
  gw_online = nil,       -- gateway's NETWORK_STATUS; nil = not told yet
  gw_written = nil,      -- {line, first, last}: the absolute channels we last drove on the gateway
  node_name = nil,
  node_online = false,
  accepted = false,
  conflict = "",
  config_error = nil,
  init_done = false,
  overrides = {},        -- role -> value, temporary (Identify, Reset Motors)
  ext = {},              -- hooks the mover fills in
}

F.PROXY_BINDING = 5001
F.BUTTON_BASE = 300
F.PERSIST_KEY = "DMX_FIXTURE_STATE"
F.PERSIST_DEBOUNCE_MS = 5000

---------------------------------------------------------------------------------------------
-- Logging. Debug Mode gates chatter only; configuration problems go through critical(), which
-- nothing can silence. (YAS209 lesson: a re-add resets properties, including the log switches,
-- so the one message that says "I cannot work" must not depend on them.)
---------------------------------------------------------------------------------------------
function F.debug(fmt, ...)
  if Properties and Properties["Debug Mode"] == "On" then
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    print("[" .. F.kind .. "] " .. msg)
  end
end

function F.critical(fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  C4:ErrorLog("[" .. F.kind .. "] " .. msg)
  print("[" .. F.kind .. "] " .. msg)
end

function F.set_prop(name, value)
  if Properties and Properties[name] ~= nil and Properties[name] ~= value then
    C4:UpdateProperty(name, value)
    Properties[name] = value
  end
end

function F.show_prop(name, visible)
  if Properties and Properties[name] ~= nil then C4:SetPropertyAttribs(name, visible and 0 or 1) end
end

---------------------------------------------------------------------------------------------
-- Configuration from properties
---------------------------------------------------------------------------------------------
local function type_from_props()
  return L.type_by_label(Properties["Fixture Type"]) or L.types_for_driver(F.kind)[1]
end

-- dmx_light declares no Layout property: a light is always its channel map. dmx_mover keeps the
-- built-in model list.
local function has_layout_prop()
  return Properties["Layout"] ~= nil
end

local function custom_mode()
  return not has_layout_prop() or Properties["Layout"] == L.CUSTOM_LABEL
end

-- Channel Count may be 0 on a pixel fixture whose every channel is in the pixel group.
local function custom_channels_from_props()
  local count = U.clamp(tonumber(Properties["Channel Count"]) or 1, 0, L.MAX_CHANNELS)
  local channels = {}
  for i = 1, count do
    local role = L.role_from_text(Properties["Channel " .. i .. " Function"] or "") or "unused"
    channels[i] = { role = role, default = tonumber(Properties["Channel " .. i .. " Default"]) or 0 }
  end
  return channels
end

-- Pixels exist only in dmx_light (the properties are absent in dmx_mover), and only when
-- Pixel Count is 2 or more: one pixel IS a plain fixture.
local function has_pixel_props()
  return Properties["Pixel Count"] ~= nil
end

local function pixel_count_prop()
  return U.clamp(math.floor(tonumber(Properties["Pixel Count"]) or 1), 1, L.MAX_PIXELS)
end

local function pixels_from_props(fixture_count)
  if not has_pixel_props() then return nil end
  local count = pixel_count_prop()
  if count < 2 then return nil end
  local size = U.clamp(tonumber(Properties["Channels Per Pixel"]) or 1, 1, L.MAX_PIXEL_CHANNELS)
  local channels = {}
  for i = 1, size do
    local role = L.role_from_text(Properties["Pixel Channel " .. i .. " Function"] or "") or "unused"
    channels[i] = { role = role, default = tonumber(Properties["Pixel Channel " .. i .. " Default"]) or 0 }
  end
  local at = U.clamp(tonumber(Properties["Fixture Channels Before Pixels"]) or fixture_count, 0, fixture_count)
  return { count = count, at = at, channels = channels }
end

-- The running layout as Channel Map text (fixture channels + pixel group).
local function layout_map_text(layout)
  if not layout then return "" end
  if layout.pixel_def then return L.format_map(layout.fixture_channels, layout.pixel_def) end
  return L.format_map(layout.channels)
end

-- Channel-specific extras defaults for Custom layouts come from Channel N Default; reset
-- behaviour from the Reset Value / Reset Hold properties (mover), per brief 5.3.
local function layout_def_from_props()
  local t = type_from_props()
  local choice = Properties["Layout"] or L.CUSTOM_LABEL
  if has_layout_prop() and choice ~= L.CUSTOM_LABEL then
    local def = L.builtin_by_display_label(choice)
    if def and def.type == t.id then return def, t end
  end
  local channels = custom_channels_from_props()
  for _, ch in ipairs(channels) do
    if ch.role == "reset" then
      ch.reset_value = tonumber(Properties["Reset Value"]) or 255
      ch.reset_hold_ms = tonumber(Properties["Reset Hold (ms)"]) or 5000
    end
  end
  return { id = L.CUSTOM_ID, label = L.CUSTOM_LABEL, type = t.id, channels = channels,
    pixels = pixels_from_props(#channels) }, t
end

function F.layout_items(t)
  local items = {}
  for _, def in ipairs(L.builtins_for_type(t.id)) do items[#items + 1] = L.display_label(def) end
  items[#items + 1] = L.CUSTOM_LABEL
  return items
end

function F.role_items(t)
  local items = {}
  for _, role in ipairs(L.ROLE_ORDER) do
    if t.allowed[role] then items[#items + 1] = L.ROLES[role].label end
  end
  return items
end

-- Rebuild every DYNAMIC_LIST (they are not persisted by Director) and fix up visibility.
function F.refresh_lists()
  local t = type_from_props()
  if has_layout_prop() then
    local items = F.layout_items(t)
    local current = Properties["Layout"]
    local found = false
    for _, it in ipairs(items) do if it == current then found = true end end
    if not found then
      current = items[1]
      Properties["Layout"] = current
    end
    C4:UpdatePropertyList("Layout", table.concat(items, ","), current)
  end
  local roles = F.role_items(t)
  local role_list = table.concat(roles, ",")
  local function fill(name)
    local value = Properties[name]
    local ok = false
    for _, r in ipairs(roles) do if r == value then ok = true end end
    if not ok then value = L.ROLES.unused.label end
    C4:UpdatePropertyList(name, role_list, value)
    Properties[name] = value
  end
  for i = 1, L.MAX_CHANNELS do fill("Channel " .. i .. " Function") end
  if has_pixel_props() then
    for i = 1, L.MAX_PIXEL_CHANNELS do fill("Pixel Channel " .. i .. " Function") end
  end
  if F.ext.refresh_lists then F.ext.refresh_lists() end
  F.refresh_gateway_list()
  F.refresh_visibility()
end

function F.refresh_visibility()
  local custom = custom_mode()
  local count = tonumber(Properties["Channel Count"]) or 1
  F.show_prop("Channel Count", custom)
  for i = 1, L.MAX_CHANNELS do
    F.show_prop("Channel " .. i .. " Function", custom and i <= count)
    F.show_prop("Channel " .. i .. " Default", custom and i <= count)
  end
  -- Pixel rows only while there ARE pixels; "Before Pixels" only when there is something to
  -- place before them.
  if has_pixel_props() then
    local on = pixel_count_prop() >= 2
    local size = tonumber(Properties["Channels Per Pixel"]) or 1
    F.show_prop("Channels Per Pixel", on)
    F.show_prop("Fixture Channels Before Pixels", on and count > 0)
    for i = 1, L.MAX_PIXEL_CHANNELS do
      F.show_prop("Pixel Channel " .. i .. " Function", on and i <= size)
      F.show_prop("Pixel Channel " .. i .. " Default", on and i <= size)
    end
  end
  local lay = F.layout
  local cct = lay and (lay.has_cct or lay.has_ww_cw) or false
  F.show_prop("CCT Min (K)", cct)
  F.show_prop("CCT Max (K)", cct)
  F.show_prop("White Mix (%)", lay and lay.has_white and lay.has_rgb or false)
  F.show_prop("Tunable White Mode", lay and lay.type_id == "rgb_tw" or false)
  local ext = lay and lay.extended or false
  F.show_prop("Color Space", ext)
  F.show_prop("Custom Primaries", ext and Properties["Color Space"] == F.CUSTOM_SPACE)
  F.show_prop("Hue Offset (deg)", ext)
  F.show_prop("CCT In Color Mode", ext and lay.has_cct or false)
  local has_reset = custom and lay and lay.roles.reset ~= nil or false
  F.show_prop("Reset Value", has_reset)
  F.show_prop("Reset Hold (ms)", has_reset)
end

-- Write a channel list into the Custom properties + the Channel Map mirror (no callbacks fire:
-- UpdateProperty does not raise OnPropertyChanged).
-- `pixels` (dmx_light only) writes the pixel rows too; nil means "no pixels" (Pixel Count 1).
-- With no pixels the pixel rows are left as they were: hidden, and ignored.
function F.write_custom_props(channels, pixels)
  if pixels and (pixels.count or 1) < 2 then channels, pixels = L.flatten(channels, pixels), nil end
  F.set_prop("Channel Count", U.int(#channels))
  for i = 1, L.MAX_CHANNELS do
    local ch = channels[i]
    F.set_prop("Channel " .. i .. " Function", ch and L.ROLES[ch.role].label or L.ROLES.unused.label)
    F.set_prop("Channel " .. i .. " Default", U.int(ch and ch.default or 0))
  end
  if has_pixel_props() then
    F.set_prop("Pixel Count", U.int(pixels and pixels.count or 1))
    if pixels then
      F.set_prop("Channels Per Pixel", U.int(#pixels.channels))
      F.set_prop("Fixture Channels Before Pixels", U.int(U.clamp(pixels.at or #channels, 0, #channels)))
      for i = 1, L.MAX_PIXEL_CHANNELS do
        local ch = pixels.channels[i]
        F.set_prop("Pixel Channel " .. i .. " Function", ch and L.ROLES[ch.role].label or L.ROLES.unused.label)
        F.set_prop("Pixel Channel " .. i .. " Default", U.int(ch and ch.default or 0))
      end
    end
  end
  F.set_prop("Channel Map", L.format_map(channels, pixels))
end

-- The Channel Map text as the current Channel / Pixel rows describe it.
local function map_from_props()
  local channels = custom_channels_from_props()
  return L.format_map(channels, pixels_from_props(#channels))
end

-- On load, for a driver without a Layout property (dmx_light):
--   * a Fixture Type from before the 2026-10-10 redesign is mapped to its new type, from the
--     channels the fixture already has, so an update never changes the output;
--   * the Channel Map text is the source of truth when it parses (it was the only record of a
--     built-in layout, whose property no longer exists);
--   * a brand-new fixture (every channel Unused) starts from its type's default map.
function F.reconcile_config()
  if has_layout_prop() then return end
  local channels, pixels = L.parse_map(Properties["Channel Map"] or "")
  if not channels then
    channels = custom_channels_from_props()
    pixels = pixels_from_props(#channels)
    local any = false
    for _, ch in ipairs(L.all_channels(channels, pixels)) do if ch.role ~= "unused" then any = true end end
    if not any then channels, pixels = nil, nil end
  end
  if pixels and not has_pixel_props() then pixels = nil end
  local label = Properties["Fixture Type"]
  local t = L.type_by_label(label)
  if not t or t.driver ~= F.kind then
    t = L.legacy_type(label, channels) or L.types_for_driver(F.kind)[1]
    F.critical("Fixture Type '%s' is from an older version: now '%s'", tostring(label), t.label)
    F.set_prop("Fixture Type", t.label)
  end
  if not channels then channels = L.default_channels(t) end
  F.write_custom_props(channels, pixels)
end

---------------------------------------------------------------------------------------------
-- Status
---------------------------------------------------------------------------------------------
function F.update_status()
  local lines = {}
  local problem = false
  if F.config_error then
    lines[#lines + 1] = "CONFIG ERROR: " .. F.config_error .. (F.layout and " (still running the previous layout)" or "")
    problem = true
  end
  if not F.layout then
    lines[#lines + 1] = "NOT OUTPUTTING: no valid layout"
    problem = true
  elseif F.output() == "both" then
    lines[#lines + 1] = "NOT OUTPUTTING: both inputs are bound (Art-Net Node AND DMX Gateway). Unbind one in Connections"
    problem = true
  elseif F.output() == "gateway" then
    local line = F.gateway_line()
    if not line then
      if F.gw_lines and #F.gw_lines == 0 then
        lines[#lines + 1] = "NOT OUTPUTTING: the gateway reports no DMX lines (only DALI or empty): choose the Gateway Line once one is set to DMX"
      else
        lines[#lines + 1] = "NOT OUTPUTTING: choose the Gateway Line this fixture is wired to"
      end
      problem = true
    else
      lines[#lines + 1] = string.format("OK: %s on DMX gateway line %d", L.footprint_text(F.start, F.layout.count, F.layout.pixel_count), line)
      if F.gw_online == false then lines[#lines + 1] = "Note: the gateway reports it is offline" end
      if not F.gw_lines then
        lines[#lines + 1] = "Note: the gateway has not reported its DMX lines yet, so line " .. line .. " is assumed (its driver sends them when it connects: run its 'Connect to Edidio' action)"
      end
    end
  elseif not F.node_id then
    if F.has_gateway_input() then
      lines[#lines + 1] = "NOT OUTPUTTING: nothing bound (Connections: bind this fixture's 'Art-Net Node' input to an Art-Net Node driver, OR its 'DMX Gateway' input to a DMX gateway driver such as the eDIDIO)"
    else
      lines[#lines + 1] = "NOT OUTPUTTING: no Art-Net node bound (Connections: bind this fixture's 'Art-Net Node' input to an Art-Net Node driver)"
    end
    problem = true
  elseif not F.accepted then
    lines[#lines + 1] = "NOT OUTPUTTING: " .. (F.conflict ~= "" and F.conflict or "waiting for the node to accept registration")
    problem = true
  else
    lines[#lines + 1] = string.format("OK: %s on %s", L.footprint_text(F.start, F.layout.count, F.layout.pixel_count),
      F.node_name and ("'" .. F.node_name .. "'") or "the node")
    if F.conflict ~= "" then lines[#lines + 1] = "Note: " .. F.conflict end
    if not F.node_online then lines[#lines + 1] = "Note: the node reports its Art-Net device is not reachable" end
  end
  if F.layout and not F.layout.verified and F.layout.id ~= L.CUSTOM_ID then
    lines[#lines + 1] = "Layout '" .. F.layout.label .. "' has not been verified against the fixture yet"
  end
  local text = table.concat(lines, " | ")
  if text ~= F.last_status then
    F.last_status = text
    F.set_prop("Status", text)
    if problem then F.critical("%s", text) else F.debug("%s", text) end
  end
  if F.light then
    local online = F.outputting()
    if online ~= F.light.online then F.light:set_online(online) end
  end
end

---------------------------------------------------------------------------------------------
-- Layout lifecycle
---------------------------------------------------------------------------------------------
local function extras_default(ch)
  if ch.steps and ch.default == 0 then return L.step_value(ch.steps[1]) end
  return ch.default or 0
end

-- Compile the configured layout and, if it is valid, make it the running one.
function F.apply_config(reason)
  local def, t = layout_def_from_props()
  local layout, err = L.compile(def, t.id, {
    cct_min = tonumber(Properties["CCT Min (K)"]), cct_max = tonumber(Properties["CCT Max (K)"]),
  })
  if not layout then
    F.config_error = err
    F.update_status()
    return false
  end
  local start = tonumber(Properties["Start Address"]) or 1
  local fits, why = L.check_start(start, layout.count)
  if not fits then
    -- Refuse, revert, explain (brief 5.2).
    local keep = F.start or 1
    F.config_error = "Start Address " .. start .. " refused: " .. why .. ". Reverted to " .. keep .. "."
    F.set_prop("Start Address", U.int(keep))
    if not F.layout then
      -- Nothing running yet: try the reverted address with the new layout.
      if L.check_start(keep, layout.count) then start = keep else F.update_status(); return false end
    else
      F.update_status()
      return false
    end
  else
    F.config_error = nil
  end

  local old = F.layout
  local moved = not old or old.count ~= layout.count or F.start ~= start or old.id ~= layout.id
    or L.format_map(old.channels) ~= L.format_map(layout.channels)
  F.layout = layout
  F.start = start
  F.set_prop("Footprint", L.footprint_text(start, layout.count, layout.pixel_count))
  F.set_prop("Layout Summary", L.summary(layout))
  -- Extras values: keep what the user set for roles that still exist, default the rest.
  local extra = {}
  for _, ch in ipairs(layout.extras) do
    if ch.role ~= "reset" then
      extra[ch.role] = F.extra[ch.role] or extras_default(ch)
    end
  end
  F.extra = extra
  if F.ext.on_layout(layout, old) == false then return false end
  F.push_capabilities()
  F.push_extras_setup()
  F.refresh_visibility()
  if moved then
    F.sent = {}
    F.register(reason or "layout changed")
  else
    F.refresh(0)
  end
  F.update_status()
  return true
end

-- Diagnostic: what the light PROXY actually holds (light_v2 variable 6661, "Light Dynamic
-- Capabilities"), as opposed to what this driver sent. Settles whether DYNAMIC_CAPABILITIES_CHANGED
-- is being applied at all (has_extras, the color rate ranges...). Logged unsilenceably.
F.PROXY_CAPS_VARIABLE = 6661

function F.show_proxy_caps()
  local ok, proxy = pcall(function() return C4:GetProxyDevices() end)
  local id = ok and (tonumber(proxy) or (type(proxy) == "table" and tonumber(next(proxy)))) or nil
  if not id then
    F.critical("Show Proxy Capabilities: could not find this driver's proxy (GetProxyDevices returned %s)", tostring(proxy))
    return
  end
  local ok2, xml = pcall(function() return C4:GetDeviceVariable(id, F.PROXY_CAPS_VARIABLE) end)
  F.critical("Show Proxy Capabilities: proxy %d holds: %s", id, ok2 and tostring(xml) or ("error " .. tostring(xml)))
  local sent = {}
  for k, v in pairs(F.last_caps or {}) do sent[#sent + 1] = k .. "=" .. tostring(v) end
  table.sort(sent)
  F.critical("Show Proxy Capabilities: this driver last sent: %s", table.concat(sent, ", "))
end

function F.push_capabilities()
  local lay = F.layout
  if not lay or not F.light then return end
  local caps = {
    dimmer = lay.controllable and not lay.switch,   -- On/Off shows a switch, not a slider
    supports_target = true,
    on_off = true,                                  -- also static in driver.xml (needed for OFF)
    ramp_level = true,
    supports_brightness_stop = true,
    supports_color = lay.supports_color,
    supports_color_correlated_temperature = lay.supports_cct,
    has_extras = (#lay.extras > 0) or (F.ext.has_extras and F.ext.has_extras()) or false,
    -- ALWAYS restate the rate ranges: the proxy's own defaults are behavior 0 with a 0-0 range,
    -- and Composer's rate controls throw out-of-range when a default rate exceeds that
    -- (bench, 2026-10-10). Must match driver.xml.
    color_rate_behavior = 2,
    color_rate_min = 0,
    color_rate_max = 6553500,
    brightness_rate_min = 0,
    brightness_rate_max = 6553500,
  }
  if lay.supports_cct then
    caps.color_correlated_temperature_min = lay.cct_min
    caps.color_correlated_temperature_max = lay.cct_max
  end
  F.last_caps = caps
  F.light:capabilities(caps)
end

---------------------------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------------------------
function F.gamma()
  local setting = Properties["Dimming Curve"] or "Auto"
  local g = tonumber(setting:match("^([%d%.]+)"))
  return C.resolve_gamma(g, F.layout and F.layout.has_dimmer)
end

-- Extended Range colour space -> primaries for color.lua. A bad Custom entry falls back to sRGB
-- (Status says so, from the property handler).
F.RGB_WHITE_MIXING = "RGB White Mixing"
F.CUSTOM_SPACE = "Custom (fixture primaries)"
local SPACE_BY_LABEL = {
  ["sRGB (Control4 standard)"] = C.SPACES.srgb,
  ["Rec. 2020 (wide gamut)"] = C.SPACES.rec2020,
}
function F.color_space()
  local label = Properties["Color Space"]
  if label == F.CUSTOM_SPACE then
    return C.parse_primaries(Properties["Custom Primaries"]) or C.SPACES.srgb
  end
  return SPACE_BY_LABEL[label] or C.SPACES.srgb
end

-- The complete footprint from current intent. Returns offset -> value (0..255).
function F.compute()
  local lay = F.layout
  local out = {}
  if not lay then return out end
  local state = F.light and F.light:target_state() or { level = 0 }
  if F.overrides.level then
    state = { level = F.overrides.level, x = state.x, y = state.y, mode = state.mode }
  end
  if lay.switch and (state.level or 0) > 0 then
    state = { level = 100, x = state.x, y = state.y, mode = state.mode }
  end
  local mix = C.mix(lay, state, {
    white_mix = (tonumber(Properties["White Mix (%)"]) or 100) / 100,
    rgb_white_mix = Properties["Tunable White Mode"] == F.RGB_WHITE_MIXING,
    space = F.color_space(),
    hue_offset = tonumber(Properties["Hue Offset (deg)"]) or 0,
    cct_in_color = (tonumber(Properties["CCT In Color Mode"]) or 255) / 255,
    gamma = F.gamma(),
  })
  for _, ch in ipairs(lay.channels) do
    local role, off = ch.role, ch.offset
    local v = ch.default or 0
    if lay.roles[role] ~= off and not ch.pixel and role ~= "fixed" and role ~= "unused" then
      v = ch.default or 0         -- a repeated role only drives its first channel (pixel copies
                                  -- are not repeats: every pixel gets the same value)
    elseif role == "dimmer" and lay.roles.dimmer_fine then
      v = C.to_16(mix.dimmer or 0)
    elseif role == "dimmer_fine" then
      v = select(2, C.to_16(mix.dimmer or 0))
    elseif role == "hue" and lay.roles.hue_fine and mix.hue ~= nil then
      v = C.to_16(mix.hue)
    elseif role == "hue_fine" and mix.hue ~= nil then
      v = select(2, C.to_16(mix.hue))
    elseif (role == "hue" or role == "saturation") and mix[role] ~= nil then
      v = C.to_byte(mix[role])
    elseif mix[role] ~= nil and (role == "dimmer" or (not lay.manual and (L.MIXED_EMITTERS[role] or role == "cct"))) then
      v = C.to_byte(mix[role])
    elseif F.overrides[role] ~= nil then
      v = F.overrides[role]
    elseif F.extra[role] ~= nil then
      v = F.extra[role]
    end
    out[off] = v
  end
  if F.ext.compute then F.ext.compute(out, lay) end
  for role, v in pairs(F.overrides) do
    if role ~= "level" and lay.offsets[role] then
      for _, o in ipairs(lay.offsets[role]) do out[o] = v end
    end
  end
  return out
end

-- Send the offsets that differ from what the node holds. fade_ms applies to all of them.
function F.refresh(fade_ms, force_all)
  if not F.layout then return end
  if F.layout.switch then fade_ms = 0 end
  local out = F.compute()
  local offsets, values = {}, {}
  for off = 0, F.layout.count - 1 do
    local v = out[off] or 0
    if force_all or F.sent[off] ~= v then
      offsets[#offsets + 1] = off
      values[#values + 1] = v
      F.sent[off] = v
    end
  end
  if #offsets == 0 then return end
  local dest = F.output()
  if dest == "gateway" then
    F.send_gateway(offsets, values, fade_ms, force_all)
    F.schedule_persist()
    return
  end
  if dest ~= "node" then return end
  local changed = {}
  for _, off in ipairs(offsets) do changed[off] = true end
  local pair_list = {}
  for _, p in ipairs(F.layout.pairs) do
    if changed[p.coarse] or changed[p.fine] then pair_list[#pair_list + 1] = p end
  end
  C4:SendToDevice(F.node_id, P.UPDATE, {
    FIXTURE_ID = U.int(C4:GetDeviceID()),
    OFFSETS = force_all and "ALL" or P.encode_list(offsets),
    VALUES = P.encode_list(values),
    FADE_MS = U.int(fade_ms or 0),
    PAIRS = P.encode_pairs(pair_list),
  })
  F.schedule_persist()
end

---------------------------------------------------------------------------------------------
-- Node link
---------------------------------------------------------------------------------------------
local function first_device(result)
  if type(result) == "number" then return result end
  if type(result) == "table" then
    for id, name in pairs(result) do return tonumber(id), name end
  end
end

function F.find_node()
  local id, name = first_device(C4:GetBoundProviderDevice(0, P.FIXTURE_INPUT_BINDING))
  if id and id ~= 0 then
    F.node_id = id
    F.node_name = F.node_name or name
  end
  if F.has_gateway_input() then
    local gw = first_device(C4:GetBoundProviderDevice(0, P.GATEWAY_INPUT_BINDING))
    if gw and gw ~= 0 then F.gw_id = gw end
  end
  return F.node_id
end

---------------------------------------------------------------------------------------------
-- Gateway output (dmx_light's second input). The gateway driver owns the network link and runs
-- the fades; this driver sends absolute channel values with a fade time. No overlap policy: the
-- node's refusal of lights on a mover's channels cannot apply to a gateway it does not run.
---------------------------------------------------------------------------------------------
function F.has_gateway_input()
  return Properties and Properties["Gateway Line"] ~= nil
end

-- "node", "gateway", "both" (refused) or nil.
function F.output()
  local node, gw = F.node_id ~= nil, F.gw_id ~= nil
  if node and gw then return "both" end
  if gw then return "gateway" end
  if node then return "node" end
  return nil
end

function F.outputting()
  if not F.layout then return false end
  local out = F.output()
  if out == "node" then return F.accepted and true or false end
  if out == "gateway" then return F.gateway_line() ~= nil and F.gw_online ~= false end
  return false
end

-- The line to drive: the only DMX line if the gateway has one, else the property (which must be
-- one of the gateway's DMX lines once the gateway has said which they are).
function F.gateway_line()
  local lines = F.gw_lines
  if lines and #lines == 1 then return lines[1] end
  local chosen = tonumber(Properties["Gateway Line"])
  if not chosen then return nil end
  if lines then
    for _, l in ipairs(lines) do if l == chosen then return chosen end end
    return nil
  end
  return chosen
end

function F.refresh_gateway_list()
  if not F.has_gateway_input() then return end
  -- Until the gateway reports its lines, list only the current setting: never offer lines that
  -- may not exist (bench, 2026-11-17: the old {1, 2} placeholder showed a line 2 that was not there).
  local items = {}
  local known = F.gw_lines or { tonumber(Properties["Gateway Line"]) or 1 }
  for _, l in ipairs(known) do items[#items + 1] = U.int(l) end
  local current = Properties["Gateway Line"]
  local found = false
  for _, it in ipairs(items) do if it == current then found = true end end
  if not found then current = items[1] or "" end
  C4:UpdatePropertyList("Gateway Line", table.concat(items, ","), current)
  Properties["Gateway Line"] = current
  -- Always shown (Dave): like Control4's own DMX Light, the list holds only the gateway's DMX
  -- lines, so it cannot be set wrong, but it always says what the fixture is on.
  F.show_prop("Gateway Line", true)
end

local function gateway_message(line, fade_ms)
  return { LINE = U.int(line), DEVICE_ID = U.int(C4:GetDeviceID()), TIME = U.int(fade_ms or 0) }
end

-- Before a full resend: zero what we drove last time and no longer drive (moved address, smaller
-- footprint, another line), so the old channels do not stay lit.
local function gateway_release_old(line, first, last)
  local w = F.gw_written
  if not w then return end
  local params, any = gateway_message(w.line, 0), false
  for ch = w.first, w.last do
    if w.line ~= line or ch < first or ch > last then
      params[ch] = 0
      any = true
    end
  end
  if any then C4:SendToProxy(P.GATEWAY_INPUT_BINDING, P.GW_LEVEL, params) end
end

function F.send_gateway(offsets, values, fade_ms, force_all)
  local line = F.gateway_line()
  if not line then return end
  local first, last = F.start, F.start + F.layout.count - 1
  if force_all then gateway_release_old(line, first, last) end
  local params = gateway_message(line, fade_ms)
  for i, off in ipairs(offsets) do params[F.start + off] = values[i] end
  C4:SendToProxy(P.GATEWAY_INPUT_BINDING, P.GW_LEVEL, params)
  F.gw_written = { line = line, first = first, last = last }
end

-- Messages from the gateway driver (via the binding, or ExecuteCommand: Control4's own light
-- accepts both, so we do too). Returns true if it was one.
function F.on_gateway(cmd, p)
  p = p or {}
  -- Every gateway message except level replies is logged regardless of Debug Mode: this protocol
  -- is read from Control4's light driver, not documented, so the first bench runs need to see it.
  if cmd ~= P.GW_LEVELS then
    local parts = {}
    for k, v in pairs(p) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    table.sort(parts)
    F.critical("from gateway: %s {%s}", tostring(cmd), table.concat(parts, ", "))
  end
  if cmd == P.GW_LINES then
    local lines = {}
    for k, v in pairs(p) do
      if tonumber(k) and tostring(v):upper() == "DMX" then lines[#lines + 1] = tonumber(k) end
    end
    table.sort(lines)
    F.gw_lines = lines
    F.debug("gateway DMX lines: %s", table.concat(lines, ","))
    F.refresh_gateway_list()
    F.register("gateway reported its lines")
    F.schedule_persist()
    return true
  elseif cmd == P.GW_STATUS then
    local was = F.gw_online
    F.gw_online = U.toboolean(p.STATUS)
    -- Back online (e.g. the gateway rebooted): restore the whole look.
    if F.gw_online and was == false then F.register("gateway back online") else F.update_status() end
    return true
  elseif cmd == P.GW_LEVELS then
    return true    -- reply to a query we never send; nothing to do
  end
  return false
end

function F.fixture_name()
  local name = C4.GetDeviceDisplayName and C4:GetDeviceDisplayName(C4:GetDeviceID()) or nil
  if not name or name == "" then name = C4:GetDriverConfigInfo("name") or F.kind end
  return name
end

function F.register(reason)
  if not F.layout then F.update_status(); return end
  if not F.node_id and not F.gw_id then F.find_node() end
  if F.output() == "gateway" then
    F.debug("sending the whole footprint to the gateway (%s)", reason or "")
    F.refresh(0, true)
    F.update_status()
    return
  end
  if F.output() ~= "node" then F.update_status(); return end
  F.debug("registering with node %s (%s)", tostring(F.node_id), reason or "")
  C4:SendToDevice(F.node_id, P.REGISTER, {
    FIXTURE_ID = U.int(C4:GetDeviceID()),
    NAME = F.fixture_name(),
    START = U.int(F.start),
    FOOTPRINT = U.int(F.layout.count),
    KIND = F.kind,
    LAYOUT = F.layout.label,
  })
  F.refresh(0, true)
  F.update_status()
end

function F.unregister()
  if F.node_id then
    C4:SendToDevice(F.node_id, P.UNREGISTER, { FIXTURE_ID = U.int(C4:GetDeviceID()) })
  end
end

function F.on_node_state(p)
  F.node_online = U.toboolean(p.ONLINE)
  F.accepted = U.toboolean(p.ACCEPTED)
  F.conflict = p.CONFLICT or ""
  if p.NODE_NAME and p.NODE_NAME ~= "" then F.node_name = p.NODE_NAME end
  F.update_status()
end

---------------------------------------------------------------------------------------------
-- Persistence (debounced: fades and sliders would otherwise write constantly)
---------------------------------------------------------------------------------------------
function F.schedule_persist()
  if F.persist_timer then return end
  F.persist_timer = C4:SetTimer(F.PERSIST_DEBOUNCE_MS, function()
    F.persist_timer = nil
    F.persist_now()
  end)
end

function F.persist_now()
  local state = { light = F.light and F.light:snapshot() or nil, extra = F.extra, gw_lines = F.gw_lines,
    gw_written = F.gw_written }
  if F.ext.snapshot then state.ext = F.ext.snapshot() end
  C4:PersistSetValue(F.PERSIST_KEY, state)
end

function F.restore()
  local state = C4:PersistGetValue(F.PERSIST_KEY)
  if type(state) ~= "table" then return end
  if state.light and F.light then F.light:restore(state.light) end
  if type(state.extra) == "table" then F.extra = state.extra end
  if type(state.gw_lines) == "table" then F.gw_lines = state.gw_lines end
  if type(state.gw_written) == "table" then F.gw_written = state.gw_written end
  if state.ext and F.ext.restore then F.ext.restore(state.ext) end
end

---------------------------------------------------------------------------------------------
-- Extras tab
---------------------------------------------------------------------------------------------
local SECTION_FOR_GROUP = {
  color_extra = "Color", beam = "Beam", effects = "Effects", position = "Position", maintenance = "Maintenance",
}
local SECTION_ORDER = { "Position", "Color", "Beam", "Effects", "Presets", "Maintenance" }

function F.role_object(ch)
  local id = "r_" .. ch.role
  if ch.role == "reset" then
    return { type = "button", id = "a_reset", label = F.kind == "mover" and "Reset Motors" or "Reset", text = "Reset" }
  end
  if ch.steps then
    local items = {}
    for i, step in ipairs(ch.steps) do items[#items + 1] = { text = step[1], value = U.int(i) } end
    local idx = L.step_for_value(ch.steps, F.extra[ch.role] or 0)
    return { type = "list", id = id, label = ch.label, items = items, value = U.int(idx or 1) }
  end
  return { type = "slider", id = id, label = ch.label, min = 0, max = ch.max or 255, resolution = 1,
    value = F.extra[ch.role] or 0 }
end

function F.extras_sections()
  local by = {}
  for _, name in ipairs(SECTION_ORDER) do by[name] = {} end
  if F.layout then
    for _, ch in ipairs(F.layout.extras) do
      local section = SECTION_FOR_GROUP[ch.group] or "Effects"
      table.insert(by[section], F.role_object(ch))
    end
    if #F.layout.extras > 0 then
      table.insert(by.Maintenance, { type = "button", id = "a_defaults", label = "Restore Defaults", text = "Restore" })
    end
  end
  if F.ext.extras_objects then F.ext.extras_objects(by) end
  local sections = {}
  for _, name in ipairs(SECTION_ORDER) do
    if #by[name] > 0 then sections[#sections + 1] = { label = name, objects = by[name] } end
  end
  return sections
end

function F.push_extras_setup()
  if not F.light then return end
  local sections = F.extras_sections()
  local xml = X.setup_xml(sections)
  if xml ~= F.last_extras_setup then
    F.last_extras_setup = xml
    F.light:notify("EXTRAS_SETUP_CHANGED", { XML = xml })
    F.debug("Extras setup sent: %s", xml)
  end
end

function F.push_extras_state(values)
  if F.light then F.light:notify("EXTRAS_STATE_CHANGED", { XML = X.state_xml(values) }) end
end

-- Set one Extras-controlled role from a raw value; returns the value actually applied.
function F.set_role(role, value, fade_ms)
  local lay = F.layout
  if not lay or lay.roles[role] == nil then return nil end
  local ch = lay.channels[lay.roles[role] + 1]
  value = U.clamp(U.round(tonumber(value) or 0), 0, ch.max or 255)
  F.extra[role] = value
  F.refresh(fade_ms or 0)
  return value
end

function F.restore_defaults()
  if not F.layout then return end
  for _, ch in ipairs(F.layout.extras) do
    if ch.role ~= "reset" then F.extra[ch.role] = extras_default(ch) end
  end
  F.refresh(0)
  F.push_extras_setup_state()
end

-- Re-send every Extras value (after a bulk change).
function F.push_extras_setup_state()
  local values = {}
  for _, s in ipairs(F.extras_sections()) do
    for _, o in ipairs(s.objects) do
      if o.value ~= nil then values[#values + 1] = { id = o.id, value = o.value } end
    end
  end
  F.push_extras_state(values)
end

function F.on_extra(id, value)
  local role = id:match("^r_(.+)$")
  if role and F.layout and F.layout.roles[role] then
    local ch = F.layout.channels[F.layout.roles[role] + 1]
    if ch.steps then
      local step = ch.steps[tonumber(value) or 1] or ch.steps[1]
      F.set_role(role, L.step_value(step))
    else
      F.set_role(role, value)
    end
    -- The UI reverts after 10 s unless the new state is echoed back.
    F.push_extras_state({ { id = id, value = value } })
    return
  end
  if id == "a_defaults" then
    F.restore_defaults()
    F.push_extras_state({ { id = id } })
    return
  end
  if id == "a_reset" then
    F.reset_motors()
    F.push_extras_state({ { id = id } })
    return
  end
  if F.ext.on_extra and F.ext.on_extra(id, value) then return end
  F.debug("unhandled Extras object %s", id)
  F.push_extras_state({ { id = id } })
end

---------------------------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------------------------
function F.identify()
  if not F.layout then return end
  local flashes, step = 0, 0
  F.overrides.level = 100
  F.refresh(0)
  local timer
  timer = C4:SetTimer(500, function(t)
    step = step + 1
    if step % 2 == 1 then
      F.overrides.level = 0
      flashes = flashes + 1
    else
      F.overrides.level = 100
    end
    if flashes >= 3 and step % 2 == 0 then
      t:Cancel()
      F.overrides.level = nil
      F.refresh(0)
      return
    end
    F.refresh(0)
  end, true)
  F.identify_timer = timer
end

function F.reset_motors()
  local lay = F.layout
  if not lay or lay.roles.reset == nil then
    F.critical("Reset: this layout has no Reset/Control channel")
    return
  end
  local ch = lay.channels[lay.roles.reset + 1]
  F.overrides.reset = ch.reset_value or 255
  F.refresh(0)
  if F.ext.on_reset then F.ext.on_reset(true) end
  C4:SetTimer(ch.reset_hold_ms or 5000, function()
    F.overrides.reset = nil
    F.refresh(0)
    if F.ext.on_reset then F.ext.on_reset(false) end
  end)
end

---------------------------------------------------------------------------------------------
-- Property changes
---------------------------------------------------------------------------------------------
local CHANNEL_PROP = "^Channel (%d+) (%a+)$"
local PIXEL_PROP = "^Pixel Channel (%d+) (%a+)$"

function F.on_property(name)
  if not F.init_done then return end
  local value = Properties[name]
  if name == "Debug Mode" or name == "Status" or name == "Footprint" or name == "Driver Version" then
    return
  elseif name == "Fixture Type" then
    if not has_layout_prop() then
      -- Keep the map if the new type allows every channel on it, else start from the type's
      -- default (Dave: picking a type fills in a sensible starting map).
      local t = type_from_props()
      local channels = custom_channels_from_props()
      local pixels = pixels_from_props(#channels)
      local function fits(c, p)
        return L.map_fits(t, c, p) and L.compile({ channels = c, pixels = p }, t.id) and true or false
      end
      if not fits(channels, pixels) then
        if pixels then
          -- Pixels stay pixels: the type's starting map becomes the pixel group, and the fixture
          -- channels the new type still allows (master dimmer, strobe...) are kept.
          local group = L.default_channels(t)
          local in_group = {}
          for _, ch in ipairs(group) do
            in_group[ch.role] = true
            if L.ROLES[ch.role .. "_fine"] then in_group[ch.role .. "_fine"] = true end
          end
          local kept, before = {}, 0
          for i, ch in ipairs(channels) do
            if t.allowed[ch.role] and not in_group[ch.role] then
              kept[#kept + 1] = ch
              if i <= pixels.at then before = before + 1 end
            end
          end
          pixels = { count = pixels.count, at = before, channels = group }
          channels = kept
          if not fits(channels, pixels) then
            channels, pixels.at = {}, 0
          end
        else
          channels = L.default_channels(t)
        end
      end
      F.write_custom_props(channels, pixels)
    end
    F.refresh_lists()
    if has_layout_prop() and Properties["Layout"] == L.CUSTOM_LABEL then F.write_custom_props(custom_channels_from_props()) end
    F.apply_config("fixture type changed")
  elseif name == "Layout" then
    if value == L.CUSTOM_LABEL and F.layout and F.layout.id ~= L.CUSTOM_ID then
      -- Switching to Custom starts from the running built-in, so a built-in can be tweaked.
      F.write_custom_props(F.layout.channels)
    elseif value ~= L.CUSTOM_LABEL then
      local def = L.builtin_by_display_label(value)
      if def then F.set_prop("Channel Map", L.format_map(def.channels)) end
    end
    F.refresh_visibility()
    F.apply_config("layout changed")
  elseif name == "Channel Map" then
    local channels, pixels_or_err = L.parse_map(value)
    local err = not channels and pixels_or_err or nil
    if channels and pixels_or_err and not has_pixel_props() then
      err = "a moving head cannot have pixels"
    end
    if err then
      F.config_error = "Channel Map: " .. err
      F.set_prop("Channel Map", F.layout and layout_map_text(F.layout) or "")
      F.update_status()
      return
    end
    -- Editing the map implies a Custom layout.
    if Properties["Layout"] ~= L.CUSTOM_LABEL then F.set_prop("Layout", L.CUSTOM_LABEL) end
    F.write_custom_props(channels, pixels_or_err)
    F.refresh_visibility()
    F.apply_config("channel map edited")
  elseif name == "Pixel Count" then
    -- Turning pixels on splits the single-cell map into fixture channels + one pixel's group
    -- (the run of color channels); turning them off puts one copy back in place. The Channel Map
    -- text still describes the configuration BEFORE this edit, so it says which way we are going.
    local old_channels, old_pixels = L.parse_map(Properties["Channel Map"] or "")
    if not old_channels then
      old_channels = custom_channels_from_props()
      old_pixels = nil
    end
    local count = pixel_count_prop()
    if count >= 2 and not old_pixels then
      local fixture, group = L.split_for_pixels(old_channels, type_from_props())
      group.count = count
      F.write_custom_props(fixture, group)
    elseif count >= 2 then
      old_pixels.count = count
      F.write_custom_props(old_channels, old_pixels)
    elseif old_pixels then
      F.write_custom_props(L.flatten(old_channels, old_pixels), nil)
    else
      F.write_custom_props(old_channels, nil)
    end
    F.refresh_visibility()
    F.apply_config("pixel count changed")
  elseif name == "Channel Count" or name:match(CHANNEL_PROP) or name:match(PIXEL_PROP)
      or name == "Channels Per Pixel" or name == "Fixture Channels Before Pixels" then
    if name == "Channel Count" and has_pixel_props() then
      -- "Before Pixels" stays inside the new count, and if every fixture channel came before the
      -- pixels (the usual case: master dimmer and strobe first), new rows join them there.
      local n = U.clamp(tonumber(value) or 0, 0, L.MAX_CHANNELS)
      local before = tonumber(Properties["Fixture Channels Before Pixels"]) or n
      local was_channels, was_pixels = L.parse_map(Properties["Channel Map"] or "")
      if was_channels and was_pixels and was_pixels.at == #was_channels then before = n end
      F.set_prop("Fixture Channels Before Pixels", U.int(math.min(before, n)))
    end
    F.set_prop("Channel Map", map_from_props())
    F.refresh_visibility()
    F.apply_config("custom channel edited")
  elseif name == "Gateway Line" then
    F.register("gateway line changed")
  elseif name == "Start Address" or name == "CCT Min (K)" or name == "CCT Max (K)"
      or name == "Reset Value" or name == "Reset Hold (ms)" then
    F.apply_config(name .. " changed")
  elseif name == "White Mix (%)" or name == "Dimming Curve" or name == "Tunable White Mode"
      or name == "Hue Offset (deg)" or name == "CCT In Color Mode" then
    F.refresh(0)
  elseif name == "Color Space" or name == "Custom Primaries" then
    local _, err = C.parse_primaries(Properties["Custom Primaries"])
    if Properties["Color Space"] == F.CUSTOM_SPACE and err then
      F.config_error = err .. " (using sRGB until fixed)"
    elseif F.config_error and F.config_error:find("Custom Primaries", 1, true) then
      F.config_error = nil
    end
    F.refresh_visibility()
    F.update_status()
    F.refresh(0)
  elseif F.ext.on_property then
    F.ext.on_property(name, value)
  end
end

---------------------------------------------------------------------------------------------
-- Programming commands shared by both fixture drivers
---------------------------------------------------------------------------------------------
function F.control_items()
  local items = {}
  if F.layout then
    for _, ch in ipairs(F.layout.extras) do
      if ch.role ~= "reset" then items[#items + 1] = ch.label end
    end
  end
  return items
end

function F.role_by_label(label)
  if not F.layout then return nil end
  for _, ch in ipairs(F.layout.extras) do
    if ch.label == label then return ch.role end
  end
end

function F.default_fade()
  return tonumber(Properties["Default Fade (ms)"]) or 0
end

function F.command(cmd, p)
  if cmd == "Set Control" then
    local role = F.role_by_label(p["Control"])
    if not role then
      F.critical("Set Control: '%s' is not a control on this fixture's layout", tostring(p["Control"]))
      return true
    end
    F.set_role(role, p["Value"], F.default_fade())
    F.push_extras_setup_state()
    return true
  elseif cmd == "Restore Control Defaults" then
    F.restore_defaults()
    return true
  elseif cmd == "Identify" then
    F.identify()
    return true
  end
  return false
end

---------------------------------------------------------------------------------------------
-- Director entry points
---------------------------------------------------------------------------------------------
function F.install(opts)
  F.kind = opts.kind
  F.ext = opts.ext or {}
  F.ext.on_layout = F.ext.on_layout or function() end

  function OnDriverInit()
    -- Most APIs are not allowed here (SetTimer, SendToDevice, UpdatePropertyList...). Everything
    -- happens in OnDriverLateInit.
  end

  function OnDriverLateInit()
    F.critical("loaded %s", "@BUILD@")
    -- A property's driver.xml default applies only on FIRST install: an update keeps the stored
    -- value, so without this the Driver Version shown stays at the first build forever (bench,
    -- 2026-11-21: read "build 37" while 43 was running).
    C4:UpdateProperty("Driver Version", "@BUILD@")
    F.light = Light.new({
      binding = F.PROXY_BINDING, button_base = F.BUTTON_BASE, full_als = opts.full_als,
      apply = function(state, level_ms, color_ms)
        F.refresh(math.max(level_ms or 0, color_ms or 0))
      end,
      on_scene_activated = F.ext.on_scene_activated,
      log = F.debug,
      warn = function(msg) F.critical("%s", msg) end,
      get_setup = function()
        local proxy = C4:GetProxyDevices()
        local id = tonumber(proxy) or (type(proxy) == "table" and tonumber(next(proxy))) or nil
        if not id then return nil end
        local xml = C4:SendUIRequest(id, "GET_SETUP", {})
        F.debug("proxy GET_SETUP: %s", tostring(xml))
        return xml
      end,
      persist = F.schedule_persist,
    })
    F.restore()
    F.reconcile_config()
    F.refresh_lists()
    F.init_done = true
    F.find_node()
    F.refresh_gateway_list()
    F.apply_config("driver loaded")
    F.light:announce()
    F.push_extras_setup_state()
    if F.ext.late_init then F.ext.late_init() end
  end

  function OnDriverDestroyed()
    F.unregister()
  end

  function OnPropertyChanged(name)
    local ok, err = pcall(F.on_property, name)
    if not ok then F.critical("property '%s' failed: %s", name, tostring(err)) end
  end

  function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
    local ok, err = pcall(function()
      if idBinding == P.GATEWAY_INPUT_BINDING then
        if bIsBound then
          F.gw_id = tonumber(otherDeviceId)
          F.refresh_gateway_list()
          F.register("gateway bound")
        else
          F.gw_id, F.gw_online, F.gw_written = nil, nil, nil
          F.refresh_gateway_list()
          F.register("gateway unbound")
        end
        return
      end
      if idBinding ~= P.FIXTURE_INPUT_BINDING then return end
      if bIsBound then
        F.node_id = tonumber(otherDeviceId)
        F.node_name = nil
        F.register("node bound")
      else
        F.unregister()
        F.node_id, F.accepted, F.conflict, F.node_name = nil, false, "", nil
        F.register("node unbound")
      end
    end)
    if not ok then F.critical("binding change failed: %s", tostring(err)) end
  end

  function ReceivedFromProxy(idBinding, strCommand, tParams)
    tParams = tParams or {}
    -- Debug Mode: every command the proxy delivers, with its binding and parameters, so a control
    -- that "does nothing" shows whether anything arrived and what (bench, 2026-11-21: On/Off).
    if Properties["Debug Mode"] == "On" then
      local parts = {}
      for k, v in pairs(tParams) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
      table.sort(parts)
      F.debug("proxy -> %s on binding %s {%s}", tostring(strCommand), tostring(idBinding), table.concat(parts, ", "))
    end
    local ok, err = pcall(function()
      if idBinding == P.GATEWAY_INPUT_BINDING then
        if not F.on_gateway(strCommand, tParams) then F.debug("unhandled gateway message %s", strCommand) end
        return
      end
      local extra = X.object_for_command(strCommand)
      if strCommand == "GET_EXTRAS_SETUP" or strCommand == "GET_EXTRAS_STATE" then
        -- A UI (re)loading asks for both; answer even if nothing changed since the last push.
        F.debug("%s requested", strCommand)
        F.last_extras_setup = nil
        F.push_extras_setup()
        F.push_extras_setup_state()
      elseif extra then
        F.on_extra(extra, tParams.value or tParams.VALUE)
      elseif not F.light:handle(strCommand, tParams, idBinding) then
        F.debug("unhandled proxy command %s", strCommand)
      end
    end)
    if not ok then F.critical("proxy command %s failed: %s", strCommand, tostring(err)) end
  end

  function ExecuteCommand(strCommand, tParams)
    tParams = tParams or {}
    local ok, err = pcall(function()
      if strCommand == P.NODE_STATE then
        F.on_node_state(tParams)
      elseif F.has_gateway_input() and F.on_gateway(strCommand, tParams) then
        -- LINES_INFO / NETWORK_STATUS / DMX_LEVELS sent by the gateway driver with SendToDevice
      elseif strCommand == P.NODE_RESYNC then
        if tParams.NODE_ID then F.node_id = tonumber(tParams.NODE_ID) or F.node_id end
        F.register("node asked for resync")
      elseif strCommand == "LUA_ACTION" then
        local action = tParams.ACTION
        if action == "IDENTIFY" then F.identify()
        elseif action == "REREGISTER" then F.find_node(); F.register("re-register action")
        elseif action == "RESET_MOTORS" then F.reset_motors()
        elseif action == "SHOW_PROXY_CAPS" then F.show_proxy_caps()
        elseif not (F.ext.action and F.ext.action(action, tParams)) then
          F.debug("unhandled action %s", tostring(action))
        end
      elseif not F.command(strCommand, tParams) then
        if not (F.ext.command and F.ext.command(strCommand, tParams)) then
          F.debug("unhandled command %s", strCommand)
        end
      end
    end)
    if not ok then F.critical("command %s failed: %s", strCommand, tostring(err)) end
  end

  function GetCommandParamList(commandName, paramName)
    if paramName == "Control" then return F.control_items() end
    if F.ext.param_list then return F.ext.param_list(commandName, paramName) or {} end
    return {}
  end
end

return F
