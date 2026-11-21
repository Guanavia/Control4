-- c4sim.lua -- an offline stand-in for Director, good enough to run the BUILT drivers
-- (build/<name>/driver.lua) together: a node and its fixtures in one process.
--
-- Rules this stub follows so it cannot be more forgiving than the real thing (YAS209 lesson: a
-- forgiving stub turns a real bug into a passing test):
--   * Only C4 functions verified against Snap One's published API exist. Anything else raises.
--   * C4:SetTimer honours bRepeat. A one-shot fires once. Timer objects have Cancel() and nothing
--     else -- no Reset(), because whether Reset restarts a fired one-shot is undocumented.
--   * UpdateProperty does NOT call OnPropertyChanged (Director only does that for user edits).
--   * SendToDevice is QUEUED and delivered after the sender returns, with every parameter
--     converted to a string, as Director does.
--   * Each driver gets its own global environment, like its own Lua state on the controller.

local A = require "artnet"

local Sim = {}
Sim.__index = Sim

local function copy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = copy(v) end
  return c
end

local function stringify(params)
  if type(params) ~= "table" then return params end
  local out = {}
  for k, v in pairs(params) do
    if type(v) == "boolean" then out[k] = v and "true" or "false"
    elseif type(v) == "number" then
      out[k] = (v == math.floor(v)) and string.format("%d", v) or tostring(v)
    else out[k] = tostring(v) end
  end
  return out
end

-- Property names and defaults from a staged driver.xml.
local function read_properties(xml)
  local props, order = {}, {}
  for body in xml:gmatch("<property>(.-)</property>") do
    local name = body:match("<name>(.-)</name>")
    local default = body:match("<default>(.-)</default>") or ""
    if name then
      props[name] = default
      order[#order + 1] = name
    end
  end
  return props, order
end

function Sim.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Sim)
  self.clock = 1000000
  self.timers = {}
  self.timer_seq = 0
  self.devices = {}
  self.bindings = {}          -- list of { consumer, cbinding, provider, pbinding }
  self.queue = {}
  self.packets = {}
  self.persist = opts.persist or {}   -- device id -> store; pass the same table to "reboot"
  self.ping_ok = {}
  self.quiet = opts.quiet ~= false
  self.max_repeats = opts.max_repeats or 100000
  return self
end

---------------------------------------------------------------------------------------------
-- The C4 object for one device.
---------------------------------------------------------------------------------------------
function Sim:make_c4(dev)
  local world = self
  local api = {}

  function api:ErrorLog(msg) dev.errorlog[#dev.errorlog + 1] = tostring(msg) end
  function api:GetDeviceID() return dev.id end
  -- Documented (API 25_proxy / 36_variable). The sim's proxy is the device itself; variable 6661
  -- echoes the last DYNAMIC_CAPABILITIES_CHANGED as the light proxy's XML would.
  function api:GetProxyDevices() return dev.id end
  -- Documented (API: C4:SendUIRequest). Only GET_SETUP to a device's own proxy is modelled: the
  -- test sets dev.proxy_setup to the XML the light_v2 proxy would return.
  function api:SendUIRequest(id, request, params)
    local d = world.devices[tonumber(id)]
    if request == "GET_SETUP" and d then return d.proxy_setup or "" end
    return ""
  end
  function api:GetDeviceVariable(id, var)
    if tonumber(var) == 6661 and dev.proxy_caps then
      local parts = { "<DynamicCapabilities>" }
      for k, v in pairs(dev.proxy_caps) do parts[#parts + 1] = "<" .. k .. ">" .. tostring(v) .. "</" .. k .. ">" end
      return table.concat(parts) .. "</DynamicCapabilities>"
    end
    return nil
  end
  function api:GetDeviceDisplayName(id)
    local d = world.devices[tonumber(id)]
    return d and d.name or ""
  end
  function api:GetDriverConfigInfo(key)
    if key == "name" then return dev.driver end
    return ""
  end
  function api:GetTime() return world.clock end

  function api:UpdateProperty(name, value)
    dev.env.Properties[name] = tostring(value)
    dev.prop_updates[#dev.prop_updates + 1] = { name, tostring(value) }
  end
  function api:UpdatePropertyList(name, list, default)
    dev.lists[name] = list
    if default ~= nil then dev.env.Properties[name] = default end
  end
  function api:SetPropertyAttribs(name, hidden) dev.hidden[name] = hidden == 1 end

  function api:SendToProxy(binding, cmd, params, kind)
    if cmd == "DYNAMIC_CAPABILITIES_CHANGED" then
      -- The proxy merges each update into what it holds.
      dev.proxy_caps = dev.proxy_caps or {}
      for k, v in pairs(params or {}) do dev.proxy_caps[k] = v end
    end
    -- params: integer strings read back as numbers (what most checks compare); raw: exactly as
    -- sent, for checks on the wire FORMAT (e.g. "6553500", never "6.5535e+06").
    local norm = {}
    if type(params) == "table" then
      for k, v in pairs(params) do
        norm[k] = (type(v) == "string" and v:match("^%-?%d+$")) and tonumber(v) or v
      end
    else
      norm = params
    end
    dev.notifies[#dev.notifies + 1] = { binding = binding, cmd = cmd, params = norm, raw = copy(params), t = world.clock }
  end
  function api:SendToDevice(id, cmd, params)
    world.queue[#world.queue + 1] = { from = dev.id, to = tonumber(id), cmd = cmd, params = stringify(params) }
  end

  function api:GetBoundProviderDevice(dev_id, binding)
    dev_id = (dev_id == 0 or dev_id == nil) and dev.id or dev_id
    for _, b in ipairs(world.bindings) do
      if b.consumer == dev_id and b.cbinding == binding then return b.provider end
    end
    return nil
  end
  function api:GetBoundConsumerDevices(dev_id, binding)
    dev_id = (dev_id == 0 or dev_id == nil) and dev.id or dev_id
    local out, any = {}, false
    for _, b in ipairs(world.bindings) do
      if b.provider == dev_id and b.pbinding == binding then
        out[b.consumer] = world.devices[b.consumer].name
        any = true
      end
    end
    return any and out or nil
  end
  function api:GetDevicesByC4iName(name)
    local out = {}
    for id, d in pairs(world.devices) do
      if "lensshift_" .. d.driver .. ".c4z" == name then out[id] = d.name end
    end
    return out
  end

  function api:SetTimer(ms, fn, repeating)
    assert(type(ms) == "number" and ms > 0, "SetTimer delay must be > 0 (got " .. tostring(ms) .. ")")
    world.timer_seq = world.timer_seq + 1
    local t = { id = world.timer_seq, due = world.clock + ms, period = ms, fn = fn,
      repeating = repeating == true, dev = dev, fired = 0 }
    local obj = {}
    function obj:Cancel() t.cancelled = true end
    t.obj = obj
    world.timers[#world.timers + 1] = t
    return obj
  end

  function api:PersistSetValue(name, value)
    world.persist[dev.id] = world.persist[dev.id] or {}
    world.persist[dev.id][name] = copy(value)
  end
  function api:PersistGetValue(name)
    local store = world.persist[dev.id]
    return store and copy(store[name]) or nil
  end

  function api:CreateNetworkConnection(binding, address) dev.net[binding] = { ip = address } end
  function api:NetConnect(binding, port, kind)
    assert(dev.net[binding], "NetConnect before CreateNetworkConnection")
    dev.net[binding].port, dev.net[binding].kind = port, kind
  end
  function api:NetDisconnect(binding, port) if dev.net[binding] then dev.net[binding].port = nil end end
  function api:SendToNetwork(binding, port, data)
    local conn = dev.net[binding]
    assert(conn and conn.port == port, "SendToNetwork on a binding/port that is not connected")
    world.packets[#world.packets + 1] = { dev = dev.id, ip = conn.ip, port = port, kind = conn.kind,
      data = data, t = world.clock }
  end

  function api:CreatePingClient()
    local client, cb = {}, nil
    function client:SetOnResult(fn) cb = fn; return client end
    function client:Ping(ip, rounds)
      api:SetTimer(10, function()
        local ok = world.ping_ok[ip]
        if ok == nil then ok = true end
        if cb then cb(client, ok, ok and nil or "timeout") end
      end)
      return client
    end
    return client
  end

  function api:FireEvent(name) dev.events[#dev.events + 1] = name end
  function api:AddVariable(name, value, kind) dev.variables[name] = value end
  function api:SetVariable(name, value) dev.variables[name] = value end

  return setmetatable({}, {
    __index = function(_, key)
      local f = api[key]
      if f == nil then error("C4:" .. tostring(key) .. " is not a stubbed (doc-verified) DriverWorks API", 2) end
      return f
    end,
  })
end

---------------------------------------------------------------------------------------------
-- Devices
---------------------------------------------------------------------------------------------
function Sim:load(driver, id, name, props)
  local xml = assert(io.open("build/" .. driver .. "/driver.xml")):read("*a")
  local dev = {
    driver = driver, id = id, name = name or driver .. " " .. id,
    notifies = {}, errorlog = {}, prop_updates = {}, lists = {}, hidden = {}, events = {},
    variables = {}, net = {}, printed = {},
  }
  local properties = read_properties(xml)
  for k, v in pairs(props or {}) do properties[k] = v end
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.Properties = properties
  env.C4 = self:make_c4(dev)
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    dev.printed[#dev.printed + 1] = table.concat(parts, " ")
    if not self.quiet then print("[" .. dev.name .. "] " .. table.concat(parts, " ")) end
  end
  dev.env = env
  local chunk = assert(loadfile("build/" .. driver .. "/driver.lua"))
  setfenv(chunk, env)
  chunk()
  self.devices[id] = dev
  return dev
end

function Sim:call(dev, fname, ...)
  local f = rawget(dev.env, fname)
  if not f then return end
  local ok, err = pcall(f, ...)
  if not ok then error(dev.name .. " " .. fname .. ": " .. tostring(err), 0) end
  self:flush()
end

function Sim:init(dev)
  self:call(dev, "OnDriverInit")
  self:call(dev, "OnDriverLateInit")
  self:flush()
end

-- Bind consumer (fixture) input to provider (node) output; fires OnBindingChanged on both.
function Sim:bind(consumer, cbinding, provider, pbinding, quiet)
  self.bindings[#self.bindings + 1] = { consumer = consumer.id, cbinding = cbinding, provider = provider.id, pbinding = pbinding }
  if quiet then return end
  self:call(consumer, "OnBindingChanged", cbinding, "ARTNET_DMX", true, provider.id, pbinding)
  self:call(provider, "OnBindingChanged", pbinding, "ARTNET_DMX", true, consumer.id, cbinding)
end

function Sim:unbind(consumer, cbinding, provider, pbinding)
  for i, b in ipairs(self.bindings) do
    if b.consumer == consumer.id and b.cbinding == cbinding then table.remove(self.bindings, i); break end
  end
  self:call(consumer, "OnBindingChanged", cbinding, "ARTNET_DMX", false, provider.id, pbinding)
  self:call(provider, "OnBindingChanged", pbinding, "ARTNET_DMX", false, consumer.id, cbinding)
end

-- Deliver queued SendToDevice messages (which may queue more).
function Sim:flush()
  local guard = 0
  while #self.queue > 0 do
    guard = guard + 1
    assert(guard < 10000, "SendToDevice storm: messages keep generating messages")
    local m = table.remove(self.queue, 1)
    local target = self.devices[m.to]
    if target and rawget(target.env, "ExecuteCommand") then
      local ok, err = pcall(target.env.ExecuteCommand, m.cmd, m.params)
      if not ok then error(target.name .. " ExecuteCommand " .. m.cmd .. ": " .. tostring(err), 0) end
    end
  end
end

-- Advance the clock, firing due timers in order.
function Sim:advance(ms)
  local stop = self.clock + ms
  while true do
    local next_t
    for _, t in ipairs(self.timers) do
      if not t.cancelled and t.due <= stop and (not next_t or t.due < next_t.due or (t.due == next_t.due and t.id < next_t.id)) then
        next_t = t
      end
    end
    if not next_t then break end
    self.clock = next_t.due
    next_t.fired = next_t.fired + 1
    if next_t.repeating then
      next_t.due = next_t.due + next_t.period
      assert(next_t.fired < self.max_repeats, "a repeating timer ran away")
    else
      next_t.cancelled = true
    end
    local ok, err = pcall(next_t.fn, next_t.obj, 0)
    if not ok then error(next_t.dev.name .. " timer: " .. tostring(err), 0) end
    self:flush()
  end
  self.clock = stop
  -- Drop dead timers so the list stays small.
  local live = {}
  for _, t in ipairs(self.timers) do if not t.cancelled then live[#live + 1] = t end end
  self.timers = live
end

---------------------------------------------------------------------------------------------
-- Driving the drivers the way Composer / Navigator would
---------------------------------------------------------------------------------------------
function Sim:set_property(dev, name, value)
  assert(dev.env.Properties[name] ~= nil, "property '" .. name .. "' is not declared by " .. dev.driver)
  dev.env.Properties[name] = tostring(value)
  self:call(dev, "OnPropertyChanged", name)
end

function Sim:proxy(dev, cmd, params)
  self:call(dev, "ReceivedFromProxy", 5001, cmd, stringify(params or {}))
end

function Sim:command(dev, cmd, params)
  self:call(dev, "ExecuteCommand", cmd, stringify(params or {}))
end

function Sim:action(dev, action, params)
  local p = params or {}
  p.ACTION = action
  self:call(dev, "ExecuteCommand", "LUA_ACTION", stringify(p))
end

-- Most recent ArtDmx frame, parsed.
function Sim:frame()
  for i = #self.packets, 1, -1 do
    local p = A.parse(self.packets[i].data)
    if p and p.opcode == A.OP_DMX then return p, self.packets[i] end
  end
end

function Sim:slots(first, last)
  local f = self:frame()
  if not f then return nil end
  local out = {}
  for n = first, last do out[#out + 1] = A.slot(f, n) end
  return out
end

function Sim:packets_between(t0, t1)
  local n = 0
  for _, p in ipairs(self.packets) do if p.t > t0 and p.t <= t1 then n = n + 1 end end
  return n
end

function Sim:notifies(dev, cmd)
  local out = {}
  for _, n in ipairs(dev.notifies) do if n.cmd == cmd then out[#out + 1] = n end end
  return out
end

function Sim:last_notify(dev, cmd)
  local list = self:notifies(dev, cmd)
  return list[#list]
end

function Sim:clear(dev)
  dev.notifies, dev.errorlog, dev.events = {}, {}, {}
end

return Sim
