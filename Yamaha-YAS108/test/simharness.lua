-- Offline harness for the Yamaha YAS-108 driver.
--
-- The YAS-108 has NO network interface, so unlike the YAS-209 harness there is no socket or UPnP
-- to simulate: the entire testable surface is "which IR code came out, on which binding". That
-- is also the entire failure surface, since IR is one-way.
--
--   lua test/simharness.lua driver.lua <archetype> <action|PROXY:CMD|PROP:Name=Value>
--
-- archetypes: normal | unbound (Director reports nothing on the IR binding)
--
-- Any code id the driver sends that is NOT declared in driver.xml is a hard error here. On real
-- hardware that mistake is invisible - a bad id and a dead emitter both produce silence.

local DRIVER    = arg[1] or "driver.lua"
local ARCHETYPE = arg[2] or "normal"
local ACTION    = arg[3] or "TestIrEmitter"

local IRCODES = {}
do
  local xml = io.open((DRIVER):gsub("%.lua$", ".xml"), "r")
  if xml then
    local text = xml:read("*a"); xml:close()
    for block in text:gmatch("<ircode>(.-)</ircode>") do
      local id   = block:match("<id>%s*(%d+)%s*</id>")
      local name = block:match("<name>%s*(.-)%s*</name>")
      if id then IRCODES[id] = name or "?" end
    end
  end
end

local timers, now = {}, 0
local function schedule(ms, fn) timers[#timers+1] = { at = now + (ms or 0), fn = fn } end
local function drain(limit)
  local n = 0
  while #timers > 0 do
    table.sort(timers, function(a, b) return a.at < b.at end)
    local t = table.remove(timers, 1)
    now = t.at
    t.fn({ Reset = function() end, Cancel = function() end })
    n = n + 1
    if n > (limit or 5000) then error("timer storm") end
  end
  return n
end

local props, proxied, irFired = {}, {}, {}
local BOUND = (ARCHETYPE ~= "unbound")

C4 = {}
function C4:ErrorLog(s) end
function C4:UpdateProperty(n, v) props[n] = v end
function C4:SendToProxy(b, cmd, params) proxied[#proxied+1] = { cmd = cmd, params = params } end
function C4:SetTimer(ms, fn, rep) schedule(ms, fn); return { Cancel = function() end, Reset = function() end } end
function C4:GetDeviceID() return 777 end
function C4:GetBoundProviderDevice() return BOUND and 55 or nil end
function C4:GetBoundConsumerDevices() return {} end
function C4:SendIR(binding, code)
  if not IRCODES[tostring(code)] then
    error(("no <ircode> with id %s in driver.xml"):format(tostring(code)))
  end
  irFired[#irFired+1] = { binding = binding, code = tostring(code) }
end
function C4:SendIRStart(b, c) irFired[#irFired+1] = { binding = b, code = tostring(c), start = true } end
function C4:SendIRStop(b, c)  irFired[#irFired+1] = { binding = b, code = tostring(c), stop = true } end

------------------------------------------------------------------ run
local PROXY_CMD = ACTION:match("^PROXY:(.+)$")
local PROP_NAME, PROP_VALUE = ACTION:match("^PROP:([^=]+)=(.+)$")

Properties = {
  ["Log Level"] = "5 - Debug", ["Log Mode"] = "Print",
  ["DTS Virtual:X (3D Surround)"] = "Off", ["Clear Voice"] = "Off",
  ["Bass Extension"] = "Off", ["Bluetooth Standby"] = "Off",
  ["Subwoofer Level"] = "0",
}
dofile(DRIVER)
OnDriverInit(); OnDriverLateInit()
if BOUND and OnBindingChanged then OnBindingChanged(2, "IR_OUT", true) end
drain()

print(("==== archetype=%s action=%s ===="):format(ARCHETYPE, ACTION))
if PROP_NAME then
  Properties[PROP_NAME] = PROP_VALUE
  OnPropertyChanged(PROP_NAME)
elseif PROXY_CMD then
  local name, arg1 = PROXY_CMD:match("^([^=]+)=(.+)$")
  name = name or PROXY_CMD
  ReceivedFromProxy(5001, name, arg1 and
    { LEVEL = arg1, INPUT = arg1, SurroundMode = arg1, MODE = arg1 } or {})
else
  ExecuteCommand("LUA_ACTION", { ACTION = ACTION })
end
local ticks = drain()

if #irFired > 0 then
  local parts = {}
  for _, f in ipairs(irFired) do
    parts[#parts+1] = (IRCODES[f.code] or "?") .. "(" .. f.code .. ")"
    if f.binding ~= 2 then print(("-- !! IR on binding %s, expected 2"):format(tostring(f.binding))) end
  end
  print(("-- IR fired (%d): %s"):format(#irFired, table.concat(parts, " ")))
else
  print("-- IR fired: none")
end
local st = {}
for _, n in ipairs({"Assumed Power","Assumed Input","Assumed Volume","Assumed Mute"}) do
  st[#st+1] = ("%s=%s"):format(n, tostring(props[n]))
end
print("-- " .. table.concat(st, "  "))
print(("-- %d timer ticks, %d proxy notifications"):format(ticks, #proxied))
