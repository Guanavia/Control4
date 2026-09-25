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
-- @optional-properties: Reset Value, Reset Hold (ms)

local F = {
  kind = "light",
  layout = nil,          -- compiled, currently running layout
  start = nil,           -- start address the running layout is registered at
  sent = {},             -- offset -> value the node currently holds for us
  extra = {},            -- role -> 0..255 raw value for Extras-controlled roles
  node_id = nil,
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

local function custom_channels_from_props()
  local count = U.clamp(tonumber(Properties["Channel Count"]) or 1, 1, L.MAX_CHANNELS)
  local channels = {}
  for i = 1, count do
    local role = L.role_from_text(Properties["Channel " .. i .. " Function"] or "") or "unused"
    channels[i] = { role = role, default = tonumber(Properties["Channel " .. i .. " Default"]) or 0 }
  end
  return channels
end

-- Channel-specific extras defaults for Custom layouts come from Channel N Default; reset
-- behaviour from the Reset Value / Reset Hold properties (mover), per brief 5.3.
local function layout_def_from_props()
  local t = type_from_props()
  local choice = Properties["Layout"] or L.CUSTOM_LABEL
  if choice ~= L.CUSTOM_LABEL then
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
  return { id = L.CUSTOM_ID, label = L.CUSTOM_LABEL, type = t.id, channels = channels }, t
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
  local items = F.layout_items(t)
  local current = Properties["Layout"]
  local found = false
  for _, it in ipairs(items) do if it == current then found = true end end
  if not found then
    current = items[1]
    Properties["Layout"] = current
  end
  C4:UpdatePropertyList("Layout", table.concat(items, ","), current)
  local roles = F.role_items(t)
  local role_list = table.concat(roles, ",")
  for i = 1, L.MAX_CHANNELS do
    local name = "Channel " .. i .. " Function"
    local value = Properties[name]
    local ok = false
    for _, r in ipairs(roles) do if r == value then ok = true end end
    if not ok then value = L.ROLES.unused.label end
    C4:UpdatePropertyList(name, role_list, value)
    Properties[name] = value
  end
  if F.ext.refresh_lists then F.ext.refresh_lists() end
  F.refresh_visibility()
end

function F.refresh_visibility()
  local custom = Properties["Layout"] == L.CUSTOM_LABEL
  local count = tonumber(Properties["Channel Count"]) or 1
  F.show_prop("Channel Count", custom)
  for i = 1, L.MAX_CHANNELS do
    F.show_prop("Channel " .. i .. " Function", custom and i <= count)
    F.show_prop("Channel " .. i .. " Default", custom and i <= count)
  end
  local lay = F.layout
  local cct = lay and (lay.has_cct or lay.has_ww_cw) or false
  F.show_prop("CCT Min (K)", cct)
  F.show_prop("CCT Max (K)", cct)
  F.show_prop("White Mix (%)", lay and lay.has_white and lay.has_rgb or false)
  local has_reset = custom and lay and lay.roles.reset ~= nil or false
  F.show_prop("Reset Value", has_reset)
  F.show_prop("Reset Hold (ms)", has_reset)
end

-- Write a channel list into the Custom properties + the Channel Map mirror (no callbacks fire:
-- UpdateProperty does not raise OnPropertyChanged).
function F.write_custom_props(channels)
  F.set_prop("Channel Count", U.int(#channels))
  for i = 1, L.MAX_CHANNELS do
    local ch = channels[i]
    F.set_prop("Channel " .. i .. " Function", ch and L.ROLES[ch.role].label or L.ROLES.unused.label)
    F.set_prop("Channel " .. i .. " Default", U.int(ch and ch.default or 0))
  end
  F.set_prop("Channel Map", L.format_map(channels))
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
  elseif not F.node_id then
    lines[#lines + 1] = "NOT OUTPUTTING: no Art-Net node bound (Connections: bind this fixture's 'Art-Net Node' input to an Art-Net Node driver)"
    problem = true
  elseif not F.accepted then
    lines[#lines + 1] = "NOT OUTPUTTING: " .. (F.conflict ~= "" and F.conflict or "waiting for the node to accept registration")
    problem = true
  else
    lines[#lines + 1] = string.format("OK: %s on %s", L.footprint_text(F.start, F.layout.count),
      F.node_name and ("'" .. F.node_name .. "'") or "the node")
    if F.conflict ~= "" then lines[#lines + 1] = "Note: " .. F.conflict end
    if not F.node_online then lines[#lines + 1] = "Note: the node reports its Art-Net device is not reachable" end
  end
  if F.layout and not F.layout.verified then
    lines[#lines + 1] = "Layout '" .. F.layout.label .. "' has not been verified against the fixture yet"
  end
  local text = table.concat(lines, " | ")
  if text ~= F.last_status then
    F.last_status = text
    F.set_prop("Status", text)
    if problem then F.critical("%s", text) else F.debug("%s", text) end
  end
  if F.light then
    local online = F.layout ~= nil and F.node_id ~= nil and F.accepted
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
  F.set_prop("Footprint", L.footprint_text(start, layout.count))
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

function F.push_capabilities()
  local lay = F.layout
  if not lay or not F.light then return end
  local caps = {
    dimmer = lay.controllable,
    supports_target = true,
    supports_brightness_stop = true,
    supports_color = lay.supports_color,
    supports_color_correlated_temperature = lay.supports_cct,
    has_extras = (#lay.extras > 0) or (F.ext.has_extras and F.ext.has_extras()) or false,
  }
  if lay.supports_cct then
    caps.color_correlated_temperature_min = lay.cct_min
    caps.color_correlated_temperature_max = lay.cct_max
  end
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

-- The complete footprint from current intent. Returns offset -> value (0..255).
function F.compute()
  local lay = F.layout
  local out = {}
  if not lay then return out end
  local state = F.light and F.light:target_state() or { level = 0 }
  if F.overrides.level then
    state = { level = F.overrides.level, x = state.x, y = state.y, mode = state.mode }
  end
  local mix = C.mix(lay, state, {
    white_mix = (tonumber(Properties["White Mix (%)"]) or 100) / 100,
    gamma = F.gamma(),
  })
  for _, ch in ipairs(lay.channels) do
    local role, off = ch.role, ch.offset
    local v = ch.default or 0
    if lay.roles[role] ~= off and role ~= "fixed" and role ~= "unused" then
      v = ch.default or 0         -- a repeated role only drives its first channel
    elseif role == "dimmer" and lay.roles.dimmer_fine then
      v = C.to_16(mix.dimmer or 0)
    elseif role == "dimmer_fine" then
      v = select(2, C.to_16(mix.dimmer or 0))
    elseif mix[role] ~= nil and (L.MIXED_EMITTERS[role] or role == "dimmer" or role == "cct") then
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
    if role ~= "level" and lay.roles[role] then out[lay.roles[role]] = v end
  end
  return out
end

-- Send the offsets that differ from what the node holds. fade_ms applies to all of them.
function F.refresh(fade_ms, force_all)
  if not F.layout then return end
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
  if not F.node_id then return end
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
  return F.node_id
end

function F.fixture_name()
  local name = C4.GetDeviceDisplayName and C4:GetDeviceDisplayName(C4:GetDeviceID()) or nil
  if not name or name == "" then name = C4:GetDriverConfigInfo("name") or F.kind end
  return name
end

function F.register(reason)
  if not F.layout then F.update_status(); return end
  if not F.node_id then F.find_node() end
  if not F.node_id then F.update_status(); return end
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
  local state = { light = F.light and F.light:snapshot() or nil, extra = F.extra }
  if F.ext.snapshot then state.ext = F.ext.snapshot() end
  C4:PersistSetValue(F.PERSIST_KEY, state)
end

function F.restore()
  local state = C4:PersistGetValue(F.PERSIST_KEY)
  if type(state) ~= "table" then return end
  if state.light and F.light then F.light:restore(state.light) end
  if type(state.extra) == "table" then F.extra = state.extra end
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

function F.on_property(name)
  if not F.init_done then return end
  local value = Properties[name]
  if name == "Debug Mode" or name == "Status" or name == "Footprint" or name == "Driver Version" then
    return
  elseif name == "Fixture Type" then
    F.refresh_lists()
    if Properties["Layout"] == L.CUSTOM_LABEL then F.write_custom_props(custom_channels_from_props()) end
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
    local channels, err = L.parse_map(value)
    if not channels then
      F.config_error = "Channel Map: " .. err
      F.set_prop("Channel Map", F.layout and L.format_map(F.layout.channels) or "")
      F.update_status()
      return
    end
    -- Editing the map implies a Custom layout.
    if Properties["Layout"] ~= L.CUSTOM_LABEL then F.set_prop("Layout", L.CUSTOM_LABEL) end
    F.write_custom_props(channels)
    F.refresh_visibility()
    F.apply_config("channel map edited")
  elseif name == "Channel Count" or name:match(CHANNEL_PROP) then
    F.set_prop("Channel Map", L.format_map(custom_channels_from_props()))
    F.refresh_visibility()
    F.apply_config("custom channel edited")
  elseif name == "Start Address" or name == "CCT Min (K)" or name == "CCT Max (K)"
      or name == "Reset Value" or name == "Reset Hold (ms)" then
    F.apply_config(name .. " changed")
  elseif name == "White Mix (%)" or name == "Dimming Curve" then
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
    F.light = Light.new({
      binding = F.PROXY_BINDING, button_base = F.BUTTON_BASE, full_als = opts.full_als,
      apply = function(state, level_ms, color_ms)
        F.refresh(math.max(level_ms or 0, color_ms or 0))
      end,
      on_scene_activated = F.ext.on_scene_activated,
      log = F.debug,
      persist = F.schedule_persist,
    })
    F.restore()
    F.refresh_lists()
    F.init_done = true
    F.find_node()
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
    if idBinding ~= P.FIXTURE_INPUT_BINDING then return end
    if bIsBound then
      F.node_id = tonumber(otherDeviceId)
      F.node_name = nil
      F.register("node bound")
    else
      F.unregister()
      F.node_id, F.accepted, F.conflict, F.node_name = nil, false, "", nil
      F.update_status()
    end
  end

  function ReceivedFromProxy(idBinding, strCommand, tParams)
    tParams = tParams or {}
    local ok, err = pcall(function()
      local extra = X.object_for_command(strCommand)
      if extra then
        F.on_extra(extra, tParams.value or tParams.VALUE)
      elseif not F.light:handle(strCommand, tParams) then
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
      elseif strCommand == P.NODE_RESYNC then
        if tParams.NODE_ID then F.node_id = tonumber(tParams.NODE_ID) or F.node_id end
        F.register("node asked for resync")
      elseif strCommand == "LUA_ACTION" then
        local action = tParams.ACTION
        if action == "IDENTIFY" then F.identify()
        elseif action == "REREGISTER" then F.find_node(); F.register("re-register action")
        elseif action == "RESET_MOTORS" then F.reset_motors()
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
