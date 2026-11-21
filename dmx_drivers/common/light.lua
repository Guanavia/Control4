-- light.lua -- the driver side of the light_v2 proxy, written from Snap One's PUBLIC Light V2
-- protocol documentation (docs-driverworks-proxyprotocol-lightv2).
--
-- Deliberately NOT built on Snap One's drivers-template-code: that code is licensed as
-- confidential, requires a Control4 licence to use, and assigns ownership of derivative works to
-- Control4. This repository is public, so the template cannot be vendored here.
--
-- The light never touches DMX. It owns brightness/color intent and all proxy traffic, and calls
-- opts.apply(state, level_ms, color_ms) whenever the output should change; the fixture turns
-- that into channel values.
--
-- Scenes: dmx_light uses reduced ALS (the agent sends SET_BRIGHTNESS_TARGET / SET_COLOR_TARGET).
-- dmx_mover uses FULL ALS (opts.full_als) because it needs ACTIVATE_SCENE's scene id to link a
-- position preset to a lighting scene.

local U = require "util"

local Light = {}
Light.__index = Light

Light.BUTTON_TOP, Light.BUTTON_BOTTOM, Light.BUTTON_TOGGLE = 0, 1, 2
Light.ACTION_RELEASE_HOLD, Light.ACTION_PRESS, Light.ACTION_RELEASE_CLICK = 0, 1, 2
Light.ORIGIN_DEVICE, Light.ORIGIN_GLOBAL = 1, 2     -- colour preset origins
Light.HOLD_DEBOUNCE_MS = 250

local function now_ms()
  return C4:GetTime()
end

function Light.new(opts)
  local self = setmetatable({}, Light)
  self.binding = opts.binding or 5001
  self.button_base = opts.button_base or 300
  self.full_als = opts.full_als or false
  self.apply = opts.apply
  self.on_scene_activated = opts.on_scene_activated
  self.log = opts.log or function() end
  self.warn = opts.warn or self.log
  -- Returns the proxy's GET_SETUP XML (brightness + colour presets); nil when unavailable.
  self.get_setup = opts.get_setup
  self.persist = opts.persist
  self.timers = {}
  self.online = false
  local s = {
    level = 0, x = nil, y = nil, mode = 1,
    preset_level = 100, min_on = 1, max_on = 100,
    click_up = 250, click_down = 750, hold_up = 5000, hold_down = 5000,
    cold_start_level = 0, cold_start_time = 0,
    last_on_level = 100,
    scenes = {},
    button_colors = Light.default_button_colors(),
    -- Control4 DMX Light parity (2026-11-21): what the proxy tells the light about presets.
    on_mode = nil,             -- { id, level }: UPDATE_BRIGHTNESS_ON_MODE (the level ON goes to)
    color_on_mode = nil,       -- { on = {x,y,mode}, dim = {x,y,mode} }: UPDATE_COLOR_ON_MODE
    default_on_color = nil,    -- colour preset 1 ("On"), from UPDATE_COLOR_PRESET / GET_SETUP
    default_off_color = nil,   -- colour preset 2 ("Off"/dim)
    brightness_presets = {},   -- id -> level (UPDATE_BRIGHTNESS_PRESET / GET_SETUP)
    color_presets = {},        -- "origin:id" -> {x,y,mode}
  }
  self.s = s
  self.fade = nil          -- { from, to, t0, dur } for the brightness ramp in progress
  self.color_fade = nil
  self.buttons = {}
  self.scene_run = nil
  self.last_scene = nil
  return self
end

---------------------------------------------------------------------------------------------
-- Persistence (the fixture owns the storage call; this only shapes the data).
---------------------------------------------------------------------------------------------
function Light:snapshot()
  return U.copy(self.s)
end

function Light:restore(t)
  if type(t) ~= "table" then return end
  for k, v in pairs(t) do self.s[k] = v end
  self.s.scenes = self.s.scenes or {}
  self.s.button_colors = self.s.button_colors or Light.default_button_colors()
  self.s.brightness_presets = self.s.brightness_presets or {}
  self.s.color_presets = self.s.color_presets or {}
end

function Light:save()
  if self.persist then self.persist() end
end

---------------------------------------------------------------------------------------------
-- Notifies
---------------------------------------------------------------------------------------------
function Light:notify(cmd, params)
  -- Whole numbers go as integer STRINGS: a Lua number reached the proxy as "6.5535e+06" (bench,
  -- 2026-10-10, Show Proxy Capabilities), which integer parsers in Composer/Navigator can reject.
  -- Fractions (color x/y) stay numbers.
  if type(params) == "table" then
    local out = {}
    for k, v in pairs(params) do
      if type(v) == "number" and v == math.floor(v) and math.abs(v) < 2^53 then
        out[k] = string.format("%d", v)
      else
        out[k] = v
      end
    end
    params = out
  end
  C4:SendToProxy(self.binding, cmd, params or {}, "NOTIFY")
end

function Light:set_online(online)
  self.online = online and true or false
  self:notify("ONLINE_CHANGED", { STATE = self.online })
end

function Light:capabilities(caps)
  -- One DYNAMIC_CAPABILITIES_CHANGED carrying every capability: the light_v2 docs warn that
  -- splitting color and CCT across two notifies flips preset modes.
  self:notify("DYNAMIC_CAPABILITIES_CHANGED", caps)
end

function Light:level_state()
  return self.s.level > 0
end

---------------------------------------------------------------------------------------------
-- Button LED colors (has_leds). Composer's LED color settings arrive as SET_BUTTON_COLOR; the
-- driver owns them and reports them two ways: BUTTON_INFO to the light proxy (colors the On/Off/
-- Toggle buttons on the device screen) and BUTTON_COLORS + MATCH_LED_STATE down each BUTTON_LINK
-- (colors a keypad button bound to that link: what the keypad's "follow connection" shows).
-- Button ids: 0 = On (top), 1 = Off (bottom), 2 = Toggle. Colors are 6-char hex strings.
---------------------------------------------------------------------------------------------
function Light.default_button_colors()
  -- Lit while the button's own state is true: On and Toggle light when the load is on, Off lights
  -- when it is off. Blue/black is Control4's default keypad pairing.
  return {
    ["0"] = { on = "0000ff", off = "000000" },
    ["1"] = { on = "000000", off = "0000ff" },
    ["2"] = { on = "0000ff", off = "000000" },
  }
end

function Light:button_colors(id)
  local c = self.s.button_colors[tostring(id)]
  if not c then
    c = Light.default_button_colors()[tostring(id)] or { on = "0000ff", off = "000000" }
    self.s.button_colors[tostring(id)] = c
  end
  return c
end

local function link_bound(binding)
  local bound = C4:GetBoundConsumerDevices(0, binding)
  return bound and next(bound) ~= nil
end

-- Report one button's colors to the proxy and, if a keypad is linked, down its BUTTON_LINK.
function Light:report_button(id, to_link)
  local c = self:button_colors(id)
  local state = self:level_state()
  self:notify("BUTTON_INFO", { BUTTON_ID = id, ON_COLOR = c.on, OFF_COLOR = c.off,
    CURRENT_COLOR = state and c.on or c.off })
  local binding = self.button_base + id
  if to_link and link_bound(binding) then
    C4:SendToProxy(binding, "BUTTON_COLORS", { ON_COLOR = c.on, OFF_COLOR = c.off }, "NOTIFY")
    C4:SendToProxy(binding, "MATCH_LED_STATE", { STATE = state })
  end
end

function Light:report_all_buttons()
  for i = 0, 2 do self:report_button(i, true) end
end

local function hex6(v)
  v = v and tostring(v):gsub("^#", ""):lower()
  if v and v:match("^%x%x%x%x%x%x$") then return v end
end

function Light:set_button_color(id, on, off)
  if id == nil or id < 0 or id > 2 then return end
  local c = self:button_colors(id)
  c.on = hex6(on) or c.on
  c.off = hex6(off) or c.off
  self:save()
  self:report_button(id, true)
end

function Light:match_leds()
  local state = self:level_state()
  if state == self.led_state then return end
  self.led_state = state
  for i = 0, 2 do
    local c = self:button_colors(i)
    self:notify("BUTTON_INFO", { BUTTON_ID = i, ON_COLOR = c.on, OFF_COLOR = c.off,
      CURRENT_COLOR = state and c.on or c.off })
    local binding = self.button_base + i
    if link_bound(binding) then
      C4:SendToProxy(binding, "MATCH_LED_STATE", { STATE = state })
    end
  end
end

function Light:cancel_timer(name)
  local t = self.timers[name]
  if t then t:Cancel() end
  self.timers[name] = nil
end

function Light:timer(name, ms, fn)
  self:cancel_timer(name)
  self.timers[name] = C4:SetTimer(math.max(1, ms), function()
    self.timers[name] = nil
    fn()
  end)
end

---------------------------------------------------------------------------------------------
-- Brightness
---------------------------------------------------------------------------------------------
function Light:current_level()
  local f = self.fade
  if not f then return self.s.level end
  local p = f.dur > 0 and (now_ms() - f.t0) / f.dur or 1
  if p >= 1 then return f.to end
  return f.from + (f.to - f.from) * math.max(p, 0)
end

function Light:clamp_on(level)
  if level <= 0 then return 0 end
  return U.clamp(level, self.s.min_on, self.s.max_on)
end

-- Move brightness to `level` over `ms`. The single entry point every command funnels into.
-- color_ms non-nil means the color in self.s has ALSO just changed and fades over color_ms.
function Light:go(level, ms, color_ms)
  level = self:clamp_on(U.round(U.clamp(tonumber(level) or 0, 0, 100)))
  ms = math.max(0, U.round(tonumber(ms) or 0))
  local current = self:current_level()
  local was_off = current <= 0

  -- Control4's DMX Light: turning ON (from off) takes the next-on colour (picked while off) or the
  -- On colour (colour on-mode preset, else colour preset 1); turning OFF (from on) takes the dim
  -- colour (colour on-mode dim/fade preset, else colour preset 2). Only when this command does
  -- not carry its own colour, and only on a light that has colour or temperature control.
  if color_ms == nil and self.color_capable then
    local off_color, on_color = self:default_colors()
    local c
    if level > 0 and was_off then
      c = self.next_on_color or on_color
    elseif level <= 0 and not was_off then
      c = off_color
    end
    if c then
      self.s.x, self.s.y, self.s.mode = c.x, c.y, c.mode or 0
      color_ms = ms
    end
  end
  if level > 0 then self.next_on_color = nil end
  local change_color = color_ms ~= nil
  if change_color then color_ms = math.max(0, U.round(tonumber(color_ms) or 0)) end

  self.s.level = level
  if level > 0 then self.s.last_on_level = level end
  self.fade = ms > 0 and { from = current, to = level, t0 = now_ms(), dur = ms } or nil
  self.apply(self:target_state(), ms, change_color and color_ms or nil)

  if ms > 0 then
    self:notify("LIGHT_BRIGHTNESS_CHANGING", {
      LIGHT_BRIGHTNESS_CURRENT = U.round(current),
      LIGHT_BRIGHTNESS_TARGET = level,
      RATE = ms,
    })
    self:timer("brightness", ms, function()
      self.fade = nil
      self:notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level })
    end)
  else
    self:cancel_timer("brightness")
    self:notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level })
  end
  if change_color then
    if color_ms > 0 then
      self:timer("color", color_ms, function() self:notify_color_done() end)
    else
      self:cancel_timer("color")
      self:notify_color_done()
    end
  end
  self:match_leds()
  self:save()
end

-- Freeze a ramp where it is (SET_BRIGHTNESS_STOP, button release, STOP_SCENE_RAMP).
function Light:stop()
  if not self.fade then return end
  local level = U.round(self:current_level())
  self.fade = nil
  self:cancel_timer("brightness")
  self.s.level = level
  if level > 0 then self.s.last_on_level = level end
  self.apply(self:target_state(), 0, nil)
  self:notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level })
  self:match_leds()
  self:save()
end

-- Ramp toward `target` at a full-scale rate (hold ramps: time scales with distance to travel).
function Light:ramp_toward(target, full_scale_ms)
  local current = self:current_level()
  local ms = full_scale_ms * math.abs(target - current) / 100
  self:go(target, ms)
end

local function valid_color(c)
  return c and tonumber(c.x) and tonumber(c.y) and { x = tonumber(c.x), y = tonumber(c.y), mode = tonumber(c.mode) or 0 } or nil
end

-- (dim/off colour, on colour), as Control4's GetDefaultColors: the colour on-mode presets when the
-- proxy has set them and at least one is valid, else colour presets 2 and 1.
function Light:default_colors()
  local m = self.s.color_on_mode
  if m and m.on then
    local on, dim = valid_color(m.on), valid_color(m.dim)
    if on or dim then return dim, on end
  end
  return valid_color(self.s.default_off_color), valid_color(self.s.default_on_color)
end

-- Learn presets from the proxy's GET_SETUP (on load) so On/Off colours and scene presets work
-- before the proxy pushes any update.
function Light:seed_presets(xml)
  local brightness, colors = Light.parse_presets(xml)
  local any = false
  for id, level in pairs(brightness) do self.s.brightness_presets[tostring(id)] = level; any = true end
  for origin, list in pairs(colors) do
    for id, c in pairs(list) do
      self.s.color_presets[origin .. ":" .. id] = c
      any = true
      if origin == Light.ORIGIN_DEVICE and id == 1 then self.s.default_on_color = c end
      if origin == Light.ORIGIN_DEVICE and id == 2 then self.s.default_off_color = c end
    end
  end
  if any then self:save() end
  return any
end

-- ON goes to the brightness on-mode preset when the proxy has set one, else the preset level
-- (Control4's GetPresetLevel).
function Light:on_level()
  local m = self.s.on_mode
  if m and tonumber(m.level) and tonumber(m.level) > 0 then return tonumber(m.level) end
  return self.s.preset_level > 0 and self.s.preset_level or 100
end

function Light:on(ms)
  self:go(self:on_level(), ms or 0)
end

function Light:off(ms)
  self:go(0, ms or 0)
end

function Light:toggle(ms)
  if self:level_state() then self:off(ms) else self:on(ms) end
end

---------------------------------------------------------------------------------------------
-- Color
---------------------------------------------------------------------------------------------
function Light:target_state()
  return { level = self.s.level, x = self.s.x, y = self.s.y, mode = self.s.mode }
end

function Light:notify_color_done()
  self:notify("LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = self.s.x, LIGHT_COLOR_CURRENT_Y = self.s.y,
    LIGHT_COLOR_CURRENT_COLOR_MODE = self.s.mode,
  })
end

function Light:set_color(x, y, mode, ms)
  x, y = tonumber(x), tonumber(y)
  if not x or not y then return end
  mode = tonumber(mode) or 0
  ms = math.max(0, U.round(tonumber(ms) or 0))
  if not self:level_state() then
    -- Color set while off: remember it and come on in it (same behaviour as Control4's own
    -- lights), and tell the proxy so the UI shows the chosen color.
    self.next_on_color = { x = x, y = y, mode = mode }
    self.s.x, self.s.y, self.s.mode = x, y, mode
    self.apply(self:target_state(), nil, 0)
    self:notify_color_done()
    self:save()
    return
  end
  local from = { x = self.s.x, y = self.s.y, mode = self.s.mode }
  self.s.x, self.s.y, self.s.mode = x, y, mode
  self.apply(self:target_state(), nil, ms)
  if ms > 0 then
    self:notify("LIGHT_COLOR_CHANGING", {
      LIGHT_COLOR_TARGET_X = x, LIGHT_COLOR_TARGET_Y = y, LIGHT_COLOR_TARGET_COLOR_MODE = mode,
      LIGHT_COLOR_TARGET_RATE = ms,
      LIGHT_COLOR_CURRENT_X = from.x, LIGHT_COLOR_CURRENT_Y = from.y, LIGHT_COLOR_CURRENT_COLOR_MODE = from.mode,
    })
    self:timer("color", ms, function() self:notify_color_done() end)
  else
    self:cancel_timer("color")
    self:notify_color_done()
  end
  self:save()
end

-- Brightness and color together (scenes, presets): one apply, so the fixture sends one update.
function Light:go_with_color(level, x, y, mode, level_ms, color_ms)
  x, y = tonumber(x), tonumber(y)
  if not (x and y) then return self:go(level, level_ms) end
  self.s.x, self.s.y, self.s.mode = x, y, tonumber(mode) or 0
  self.next_on_color = nil
  self:go(level, level_ms, color_ms or 0)
end

---------------------------------------------------------------------------------------------
-- Buttons (BUTTON_ACTION from the proxy's TOP/BOTTOM/TOGGLE button links)
---------------------------------------------------------------------------------------------
function Light:click(button)
  if button == Light.BUTTON_TOP then
    self:on(self.s.click_up)
  elseif button == Light.BUTTON_BOTTOM then
    self:off(self.s.click_down)
  else
    if self:level_state() then self:off(self.s.click_down) else self:on(self.s.click_up) end
  end
end

function Light:hold(button)
  local up = button == Light.BUTTON_TOP or (button == Light.BUTTON_TOGGLE and not self:level_state())
  if up then self:ramp_toward(100, self.s.hold_up) else self:ramp_toward(0, self.s.hold_down) end
end

function Light:button_action(button, action)
  -- The proxy expects the action echoed back, or it synthesises a second press (light_v2 docs).
  self:notify("BUTTON_ACTION", { BUTTON_ID = button, ACTION = action })
  local b = self.buttons[button] or {}
  self.buttons[button] = b
  if action == Light.ACTION_PRESS then
    b.ramping = false
    self:timer("button" .. button, Light.HOLD_DEBOUNCE_MS, function()
      b.ramping = true
      self:hold(button)
    end)
  elseif action == Light.ACTION_RELEASE_CLICK or action == Light.ACTION_RELEASE_HOLD then
    local pending = self.timers["button" .. button] ~= nil
    self:cancel_timer("button" .. button)
    if b.ramping then
      b.ramping = false
      self:stop()
    elseif pending or action == Light.ACTION_RELEASE_CLICK then
      self:click(button)
    end
  end
end

---------------------------------------------------------------------------------------------
-- Full Advanced Lighting Scenes (dmx_mover only)
---------------------------------------------------------------------------------------------
-- PUSH_SCENE ELEMENTS: a run of <element> blocks with flat children (delay, rate|brightnessRate,
-- level|brightness, brightnessEnabled, colorEnabled, colorRate, colorX, colorY, colorMode).
function Light.parse_elements(xml)
  local out = {}
  for body in tostring(xml or ""):gmatch("<element>(.-)</element>") do
    local e = {}
    for tag, value in body:gmatch("<([%w_]+)>([^<]*)</[%w_]+>") do e[tag] = value end
    local el = {
      delay = tonumber(e.delay) or 0,
      level = tonumber(e.level or e.brightness),
      level_rate = tonumber(e.rate or e.brightnessRate) or 0,
      level_enabled = e.brightnessEnabled == nil and (e.level or e.brightness) ~= nil or U.toboolean(e.brightnessEnabled),
      color_enabled = U.toboolean(e.colorEnabled),
      color_rate = tonumber(e.colorRate) or 0,
      x = tonumber(e.colorX), y = tonumber(e.colorY), mode = tonumber(e.colorMode) or 0,
      -- Scenes built from presets carry the preset ids; the level/colour values beside them are
      -- not authoritative (Control4's own DMX Light ignores them and looks the preset up).
      brightness_preset = tonumber(e.brightnessPresetID) or 0,
      color_preset = tonumber(e.colorPresetID) or 0,
      color_origin = tonumber(e.colorPresetOrigin) or 0,
    }
    out[#out + 1] = el
  end
  return out
end

-- The proxy's presets, from GET_SETUP: <brightnesses><brightness id level .../></brightnesses> and
-- <colors><color origin id color_x color_y [color_mode] .../></colors> (attributes, as Control4's
-- own DMX Light reads them). Returns brightness[id] = level, colors[origin][id] = {x, y, mode}.
local function attrs(tag)
  local a = {}
  for k, v in tag:gmatch('([%w_]+)%s*=%s*"([^"]*)"') do a[k] = v end
  for k, v in tag:gmatch("([%w_]+)%s*=%s*'([^']*)'") do a[k] = v end
  return a
end

function Light.parse_presets(xml)
  local brightness, colors = {}, {}
  xml = tostring(xml or "")
  local b = xml:match("<brightnesses[^>]*>(.-)</brightnesses>") or ""
  for tag in b:gmatch("<brightness%s([^>]*)>") do
    local a = attrs(tag)
    local id, level = tonumber(a.id), tonumber(a.level)
    if id and level then brightness[id] = level end
  end
  local c = xml:match("<colors[^>]*>(.-)</colors>") or ""
  for tag in c:gmatch("<color%s([^>]*)>") do
    local a = attrs(tag)
    local origin, id = tonumber(a.origin), tonumber(a.id)
    local x, y = tonumber(a.color_x), tonumber(a.color_y)
    if origin and id and x and y then
      colors[origin] = colors[origin] or {}
      colors[origin][id] = { x = x, y = y, mode = tonumber(a.color_mode) }
    end
  end
  return brightness, colors
end

-- A copy of a scene's elements with every preset id replaced by the preset's current value.
function Light:resolve_presets(elements)
  local uses = false
  for _, el in ipairs(elements) do
    if el.brightness_preset > 0 or el.color_preset > 0 then uses = true end
  end
  if not uses then return elements end
  local ok, xml = pcall(function() return self.get_setup and self.get_setup() end)
  local brightness, colors = Light.parse_presets(ok and xml or "")
  -- Anything GET_SETUP did not list: what the proxy pushed (UPDATE_*_PRESET) or seeded earlier.
  for id, level in pairs(self.s.brightness_presets) do
    if brightness[tonumber(id)] == nil then brightness[tonumber(id)] = level end
  end
  for key, c in pairs(self.s.color_presets) do
    local origin, id = key:match("^(%d+):(%d+)$")
    origin, id = tonumber(origin), tonumber(id)
    colors[origin] = colors[origin] or {}
    if colors[origin][id] == nil then colors[origin][id] = c end
  end
  local out = {}
  for i, el in ipairs(elements) do
    local r = U.copy(el)
    if el.brightness_preset > 0 then
      local level = brightness[el.brightness_preset]
      if level then r.level = level
      else self.warn("scene uses brightness preset " .. el.brightness_preset .. ", which the proxy does not list; using the level in the scene (" .. tostring(el.level) .. ")") end
    end
    if el.color_preset > 0 then
      local c = colors[el.color_origin] and colors[el.color_origin][el.color_preset]
      if c then r.x, r.y, r.mode = c.x, c.y, c.mode or el.mode
      else self.warn("scene uses color preset " .. el.color_preset .. " (origin " .. el.color_origin .. "), which the proxy does not list; using the color in the scene") end
    end
    out[i] = r
  end
  return out
end

function Light:push_scene(id, elements_xml, flash, ignore_ramp)
  self.s.scenes[tostring(id)] = {
    elements = Light.parse_elements(elements_xml),
    flash = U.toboolean(flash), ignore_ramp = U.toboolean(ignore_ramp),
  }
  self:save()
end

function Light:stop_scene()
  self:cancel_timer("scene")
  self.scene_run = nil
end

function Light:run_scene_step()
  local run = self.scene_run
  if not run then return end
  local scene = run.scene
  local action = math.floor(run.state / 2) + 1
  if action > #scene.elements then
    if scene.flash and #scene.elements > 0 then
      run.state = 0
      action = 1
    else
      self.scene_run = nil
      return
    end
  end
  local el = scene.elements[action]
  local sleep = el.delay
  if run.state % 2 == 1 then
    if el.level_enabled and el.color_enabled and el.x then
      self:go_with_color(el.level, el.x, el.y, el.mode, el.level_rate, el.color_rate)
      sleep = math.max(el.level_rate, el.color_rate)
    elseif el.color_enabled and el.x then
      self:set_color(el.x, el.y, el.mode, el.color_rate)
      sleep = el.color_rate
    elseif el.level then
      self:go(el.level, el.level_rate)
      sleep = el.level_rate
    else
      sleep = 0
    end
  end
  run.state = run.state + 1
  if sleep > 0 then
    self:timer("scene", sleep, function() self:run_scene_step() end)
  else
    self:run_scene_step()
  end
end

function Light:activate_scene(id)
  local scene = self.s.scenes[tostring(id)]
  self.last_scene = tonumber(id)
  if not scene then
    self.log("ACTIVATE_SCENE " .. tostring(id) .. ": scene was never pushed to this driver")
  else
    self:stop_scene()
    -- Presets resolved when the scene FIRES, so editing a preset needs no re-push.
    local run_scene = { elements = self:resolve_presets(scene.elements), flash = scene.flash, ignore_ramp = scene.ignore_ramp }
    self.scene_run = { scene = run_scene, state = 0 }
    self:run_scene_step()
  end
  if self.on_scene_activated then self.on_scene_activated(tonumber(id)) end
end

function Light:ramp_scene(id, up, rate)
  local scene = self.s.scenes[tostring(id)]
  if scene and scene.ignore_ramp then return end
  self:stop_scene()
  self:go(up and (self.s.preset_level > 0 and self.s.preset_level or 100) or 0, rate or 0)
end

---------------------------------------------------------------------------------------------
-- Proxy command dispatch. Returns true if the command was a light_v2 command.
---------------------------------------------------------------------------------------------
local function num(v, default)
  local n = tonumber(v)
  if n == nil then return default end
  return n
end

function Light:handle(cmd, p, binding)
  p = p or {}
  local s = self.s
  -- Any direct command interrupts a running (e.g. flashing) scene.
  local interrupts = {
    ON = true, OFF = true, TOGGLE = true, SET_LEVEL = true, RAMP_TO_LEVEL = true,
    SET_BRIGHTNESS_TARGET = true, SET_COLOR_TARGET = true, BUTTON_ACTION = true,
  }
  if interrupts[cmd] then self:stop_scene() end

  if cmd == "ON" then self:on(s.rate_default)
  elseif cmd == "OFF" then self:off(s.rate_default)
  elseif cmd == "TOGGLE" then self:toggle(s.rate_default)
  elseif cmd == "SET_LEVEL" then self:go(num(p.LEVEL, 0), 0)
  elseif cmd == "RAMP_TO_LEVEL" then self:go(num(p.LEVEL, 0), num(p.TIME, 0))
  elseif cmd == "SET_BRIGHTNESS_TARGET" then
    self:go(num(p.LIGHT_BRIGHTNESS_TARGET, num(p.LEVEL, 0)), num(p.RATE, num(p.TIME, 0)))
  elseif cmd == "SET_BRIGHTNESS_STOP" then self:stop()
  elseif cmd == "SET_COLOR_TARGET" then
    -- OS 3.3.2 renamed RATE to LIGHT_COLOR_TARGET_RATE; accept both.
    self:set_color(p.LIGHT_COLOR_TARGET_X, p.LIGHT_COLOR_TARGET_Y, num(p.LIGHT_COLOR_TARGET_MODE, 0),
      num(p.LIGHT_COLOR_TARGET_RATE, num(p.RATE, s.color_rate_default or 0)))
  elseif cmd == "SET_COLOR_STOP" then
    self:cancel_timer("color")
    self:notify_color_done()
  elseif cmd == "SET_BUTTON_COLOR" then
    local id = tonumber(p.BUTTON_ID)
    if id == nil and binding then id = binding - self.button_base end
    self:set_button_color(id, p.ON_COLOR, p.OFF_COLOR)
  elseif cmd == "REQUEST_BUTTON_COLORS" then
    -- Arrives on the BUTTON_LINK binding of the keypad that is asking.
    local id = binding and (binding - self.button_base)
    if id and id >= 0 and id <= 2 then self:report_button(id, true) else self:report_all_buttons() end
  elseif cmd == "BUTTON_ACTION" then
    self:button_action(num(p.BUTTON_ID, 2), num(p.ACTION, 2))
  elseif cmd == "UPDATE_BRIGHTNESS_ON_MODE" then
    s.on_mode = { id = num(p.BRIGHTNESS_PRESET_ID, 0), level = num(p.BRIGHTNESS_PRESET_LEVEL, 0) }
    self:save()
  elseif cmd == "UPDATE_BRIGHTNESS_PRESET" then
    local id, level, what = num(p.ID, 0), num(p.LEVEL, 0), tostring(p.COMMAND or "")
    if what == "DELETED" then s.brightness_presets[tostring(id)] = nil else s.brightness_presets[tostring(id)] = level end
    if s.on_mode and s.on_mode.id == id then
      if what == "DELETED" then s.on_mode = nil else s.on_mode.level = level end
    end
    self:save()
  elseif cmd == "UPDATE_COLOR_ON_MODE" then
    local function preset(prefix)
      local origin = num(p[prefix .. "_ORIGIN"], 0)
      if origin == 0 then return nil end           -- origin 0 = invalid (no preset)
      return { id = num(p[prefix .. "_ID"], 0), origin = origin, x = tonumber(p[prefix .. "_COLOR_X"]),
        y = tonumber(p[prefix .. "_COLOR_Y"]), mode = tonumber(p[prefix .. "_COLOR_MODE"]) }
    end
    s.color_on_mode = { on = preset("COLOR_PRESET"), dim = preset("COLOR_FADE_PRESET") }
    self:save()
  elseif cmd == "UPDATE_COLOR_PRESET" then
    local id, what = num(p.ID, 0), tostring(p.COMMAND or "")
    local c = { x = tonumber(p.COLOR_X), y = tonumber(p.COLOR_Y), mode = tonumber(p.COLOR_MODE) or 0 }
    local key = Light.ORIGIN_DEVICE .. ":" .. id
    if what == "DELETED" then
      s.color_presets[key] = nil
    elseif what == "MODIFIED" or what == "ADDED" then
      s.color_presets[key] = c
      if id == 1 then s.default_on_color = c end
      if id == 2 then s.default_off_color = c end
      local m = s.color_on_mode
      for _, slot in ipairs({ "on", "dim" }) do
        local pr = m and m[slot]
        if pr and pr.id == id and pr.origin == Light.ORIGIN_DEVICE then pr.x, pr.y, pr.mode = c.x, c.y, c.mode end
      end
    end
    self:save()
  elseif cmd == "COLOR_SEQUENCE_COMMAND" then
    local x, y, mode, ms = tonumber(p.X), tonumber(p.Y), num(p.COLOR_MODE, 0), num(p.TIME, 0)
    if x and y then
      if p.BRIGHTNESS ~= nil and p.BRIGHTNESS ~= "" then
        self:go_with_color(num(p.BRIGHTNESS, 0), x, y, mode, ms, ms)
      else
        self:set_color(x, y, mode, ms)
      end
    end
  elseif cmd == "SET_ALL_LED" then
    local color = hex6(p.COLOR)
    if color then
      for i = 0, 2 do
        local c = self:button_colors(i)
        c.on, c.off = color, color
      end
      self:save()
      self:report_all_buttons()
    end
  elseif cmd == "DO_PUSH" or cmd == "DO_CLICK" or cmd == "DO_RELEASE" then
    -- A press on a button-link binding (300 On / 301 Off / 302 Toggle).
    local id = binding and (binding - self.button_base)
    if id and id >= 0 and id <= 2 then
      local action = cmd == "DO_PUSH" and Light.ACTION_PRESS
        or cmd == "DO_CLICK" and Light.ACTION_RELEASE_CLICK or Light.ACTION_RELEASE_HOLD
      self:button_action(id, action)
    end
  elseif cmd == "PROTOCOL_COMMAND" then
    self.log("PROTOCOL_COMMAND (ignored)")
  elseif cmd == "SET_PRESET_LEVEL" then
    s.preset_level = U.clamp(num(p.LEVEL, 100), 0, 100)
    self:notify("PRESET_LEVEL", tostring(s.preset_level))
  elseif cmd == "SET_CLICK_RATE_UP" then s.click_up = num(p.RATE, s.click_up); self:notify("CLICK_RATE_UP", tostring(s.click_up))
  elseif cmd == "SET_CLICK_RATE_DOWN" then s.click_down = num(p.RATE, s.click_down); self:notify("CLICK_RATE_DOWN", tostring(s.click_down))
  elseif cmd == "SET_HOLD_RATE_UP" then s.hold_up = num(p.RATE, s.hold_up); self:notify("HOLD_RATE_UP", tostring(s.hold_up))
  elseif cmd == "SET_HOLD_RATE_DOWN" then s.hold_down = num(p.RATE, s.hold_down); self:notify("HOLD_RATE_DOWN", tostring(s.hold_down))
  elseif cmd == "SET_MIN_ON_LEVEL" then s.min_on = U.clamp(num(p.LEVEL, 1), 1, 100); self:notify("MIN_ON_LEVEL", tostring(s.min_on))
  elseif cmd == "SET_MAX_ON_LEVEL" then s.max_on = U.clamp(num(p.LEVEL, 100), 1, 100); self:notify("MAX_ON_LEVEL", tostring(s.max_on))
  elseif cmd == "SET_COLD_START_LEVEL" then s.cold_start_level = num(p.LEVEL, 0); self:notify("COLD_START_LEVEL", tostring(s.cold_start_level))
  elseif cmd == "SET_COLD_START_TIME" then s.cold_start_time = num(p.TIME, 0); self:notify("COLD_START_TIME", tostring(s.cold_start_time))
  elseif cmd == "UPDATE_COLOR_RATE_DEFAULT" or cmd == "SET_COLOR_RATE_DEFAULT" then
    -- Composer's Default Color Rate: used when a color change arrives with no rate.
    s.color_rate_default = num(p.RATE, num(p.LIGHT_COLOR_RATE_DEFAULT, 0))
    self:save()
  elseif cmd == "UPDATE_BRIGHTNESS_RATE_DEFAULT" or cmd == "SET_BRIGHTNESS_RATE_DEFAULT" then
    s.rate_default = num(p.RATE, num(p.BRIGHTNESS_RATE_DEFAULT, 0))
  elseif cmd == "GET_CONNECTED_STATE" then self:notify("ONLINE_CHANGED", { STATE = self.online })
  elseif cmd == "GET_LIGHT_LEVEL" then self:notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = s.level })
  -- Scenes. Reduced ALS (dmx_light) only receives the ramp commands; full ALS gets them all.
  elseif cmd == "RAMP_SCENE_UP" then self:ramp_scene(p.SCENE_ID, true, num(p.RATE, 0))
  elseif cmd == "RAMP_SCENE_DOWN" then self:ramp_scene(p.SCENE_ID, false, num(p.RATE, 0))
  elseif cmd == "STOP_SCENE_RAMP" then self:stop_scene(); self:stop()
  elseif cmd == "PUSH_SCENE" then self:push_scene(p.SCENE_ID, p.ELEMENTS, p.FLASH, p.IGNORE_RAMP)
  elseif cmd == "ACTIVATE_SCENE" then self:activate_scene(p.SCENE_ID)
  elseif cmd == "REMOVE_SCENE" then s.scenes[tostring(p.SCENE_ID)] = nil; self:save()
  elseif cmd == "CLEAR_ALL_SCENES" then s.scenes = {}; self:save()
  elseif cmd == "ALL_SCENES_PUSHED" or cmd == "SYNC_SCENE" or cmd == "SYNC_ALL_SCENES" then
    -- nothing to do: scenes are applied from what was pushed
  -- Load groups are not declared (load_group_support False); these are no-ops if they arrive.
  elseif cmd == "JOIN_GROUP" or cmd == "LEAVE_GROUP" or cmd == "SET_GROUP_SYNC" then
  elseif cmd == "GROUP_RAMP_TO_LEVEL" then self:go(num(p.LEVEL, 0), num(p.TIME, 0))
  elseif cmd == "GROUP_SET_LEVEL" then self:go(num(p.LEVEL, 0), 0)
  elseif cmd == "GROUP_START_RAMP" then
    if U.toboolean(p.RAMP_UP) then self:ramp_toward(100, num(p.RATE, s.hold_up)) else self:ramp_toward(0, num(p.RATE, s.hold_down)) end
  elseif cmd == "GROUP_STOP_RAMP" then self:stop()
  else
    return false
  end
  return true
end

-- Tell the proxy everything it needs after a (re)load: online state, level and color.
function Light:announce()
  self:notify("ONLINE_CHANGED", { STATE = self.online })
  self:notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = self.s.level })
  if self.s.x and self.s.y then self:notify_color_done() end
  self.led_state = nil
  self:match_leds()
  self:report_all_buttons()
end

return Light
