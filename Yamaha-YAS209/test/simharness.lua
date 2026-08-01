-- Offline harness for the Yamaha soundbar driver.
-- Stubs the DriverWorks C4 API and simulates the bar's SSL socket end-to-end: NetConnect ->
-- ONLINE -> SendToNetwork -> ReceivedFromNetwork(HTTP response) -> OFFLINE.  That exercises the
-- real httpapi transport and HTTP parsing, not just the learn logic.

local DRIVER = arg[1]
local ARCHETYPE = arg[2] or "clamp"   -- clamp | reject | acceptall | noemitter | irworks | unbound | certfail | premuted | desync
local ACTION = arg[3] or "LearnSubwooferRange"

------------------------------------------------------------------ declared IR codes
-- Read straight out of driver.xml so the sim rejects any id the driver would send but the
-- package does not declare. That mismatch is invisible on hardware (IR is one-way, so a bad
-- id and a dead emitter both produce silence) and it is exactly the class of bug this
-- harness exists to catch before a trip to the bar.
BOUND_IR = (ARCHETYPE ~= "unbound")
local IRCODES = {}
do
  local xml = io.open((DRIVER or "driver.lua"):gsub("%.lua$", ".xml"), "r")
  if xml then
    local text = xml:read("*a"); xml:close()
    for block in text:gmatch("<ircode>(.-)</ircode>") do
      local id   = block:match("<id>%s*(%d+)%s*</id>")
      local name = block:match("<name>%s*(.-)%s*</name>")
      if id then IRCODES[id] = name or "?" end
    end
  end
end

------------------------------------------------------------------ simulated bar
local dev = {
  ["power saving"] = "1", ["sound program"] = "movie", ["3D surround"] = "1",
  ["clear voice"] = "0", ["bass extension"] = "0", ["subwoofer volume"] = "0",
  ["Master volume"] = "24", ["Audio Stream"] = "PCM", ["mute"] = "0",
}
local SUB_MIN, SUB_MAX = -6, 6
local writes = {}

local function setSub(v)
  local n = tonumber(v)
  if ARCHETYPE == "acceptall" then dev["subwoofer volume"] = v; return end
  if not n then return end                                  -- junk: refuse (both real archetypes)
  if ARCHETYPE == "clamp" then
    if n > SUB_MAX then n = SUB_MAX elseif n < SUB_MIN then n = SUB_MIN end
    dev["subwoofer volume"] = tostring(n)
  else -- reject
    if n >= SUB_MIN and n <= SUB_MAX then dev["subwoofer volume"] = tostring(n) end
  end
end

local function yamahaJson()
  local parts = {}
  for k, v in pairs(dev) do parts[#parts+1] = string.format('"%s":"%s"', k, v) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function handle(command)
  writes[#writes+1] = command
  if command:match("^YAMAHA_DATA_GET") then return yamahaJson() end
  local key, val = command:match('^YAMAHA_DATA_SET:{"([^"]+)":"([^"]*)"}$')
  if key then
    if key == "subwoofer volume" then setSub(val)
    elseif key == "sound program" then
      local ok = false
      for _, p in ipairs({"movie","music","sports","game","tv program","stereo"}) do
        if p == val then ok = true end
      end
      if ARCHETYPE == "acceptall" or ok then dev[key] = val end
    else dev[key] = val end
    return "OK"
  end
  if command:match("^getPlayerStatus") then return '{"mode":"43","eq":"0","vol":"45","mute":"0"}' end
  if command:match("^getStatusEx") then return '{"yamaha_model_name":"YAS_209"}' end
  local m = command:match("^setPlayerCmd:mute:(%d)")
  if m then dev["mute"] = m; return "OK" end
  local v = command:match("^setPlayerCmd:vol:(%d+)")
  if v then dev["Master volume"] = v; return "OK" end
  if command:match("^setPlayerCmd") then return "OK" end
  return "unknown command"
end

------------------------------------------------------------------ timer queue
local now, timers, seq = 0, {}, 0
local function schedule(ms, fn)
  seq = seq + 1
  timers[#timers+1] = { at = now + ms, seq = seq, fn = fn }
end
local function drain(limit)
  local n = 0
  while #timers > 0 do
    table.sort(timers, function(a,b) if a.at ~= b.at then return a.at < b.at end return a.seq < b.seq end)
    local t = table.remove(timers, 1)
    now = math.max(now, t.at)
    t.fn({ Reset = function() end, Cancel = function() end })
    n = n + 1
    if n > (limit or 5000) then error("timer storm - possible infinite loop in the driver") end
  end
  return n
end

------------------------------------------------------------------ C4 stub
local props, proxied = {}, {}
-- Fired IR codes, in order. Recording these is the point: IR is one-way on real hardware, so
-- the ONLY place the driver's own IR decisions can be observed is here.
local irFired = {}
local sslOnline = false
C4 = {}
function C4:ErrorLog(s) end
function C4:UpdateProperty(n, v) props[n] = v end
function C4:SendToProxy(b, cmd, params, kind) proxied[#proxied+1] = { cmd = cmd, params = params } end
-- HONOURS bRepeat. The stub used to ignore it and fire every timer exactly once, which meant a
-- polling timer that never repeated on real hardware would still look fine here - and that is
-- precisely the bug this failed to catch. Repeats are capped so the sim terminates.
local REPEAT_CAP = 4
function C4:SetTimer(ms, fn, rep)
  local t = { cancelled = false, fired = 0 }
  t.Cancel = function() t.cancelled = true end
  t.Reset  = function() end   -- deliberately a NO-OP: whether Reset restarts a fired one-shot
                              -- on real Director is undocumented, so the sim must not assume it does
  local function arm()
    schedule(ms, function()
      if t.cancelled then return end
      t.fired = t.fired + 1
      fn(t)
      if rep and t.fired < REPEAT_CAP and not t.cancelled then arm() end
    end)
  end
  arm()
  return t
end
function C4:FileExists() return true end
function C4:GetDeviceID() return 999 end
-- BOUND_IR controls whether the sim pretends the IR binding is attached, so the new binding
-- diagnostics can be exercised in both states without a controller.
function C4:GetBoundProviderDevice(dev, binding) return BOUND_IR and 42 or nil end
function C4:GetBoundConsumerDevices(dev, binding) return BOUND_IR and { [42] = "Controller IR Out 1" } or {} end
-- What a bar that OBEYS these codes would do. Used by the "irworks" archetype as the positive
-- control: the sweep must report WORKS here. Without it, a sweep broken in the always-fail
-- direction is indistinguishable from a genuinely wrong code set -- which is the exact
-- conclusion the real run is meant to draw, so it has to be earned.
local IR_EFFECT = {
  ["101"] = function() dev["power saving"] = "1" end,
  ["102"] = function() dev["power saving"] = "0" end,
  ["137"] = function() dev["mute"] = "1"; upnpMute = "1" end,
  ["138"] = function() dev["mute"] = "0"; upnpMute = "0" end,
  ["106"] = function() upnpVol = upnpVol + 2 end,
  ["107"] = function() upnpVol = upnpVol - 2 end,
}

function C4:SendIR(binding, code)
  if ARCHETYPE == "noemitter" then
    irFired[#irFired+1] = { binding = binding, code = tostring(code), dead = true }
    return
  end
  -- Real Director accepts the id of an <ircode> declared in driver.xml. Mirror that: an
  -- undeclared id is a driver bug that must not pass silently in the sim either.
  if not IRCODES[tostring(code)] then
    error(("no <ircode> with id %s in driver.xml"):format(tostring(code)))
  end
  irFired[#irFired+1] = { binding = binding, code = tostring(code) }
  if ARCHETYPE == "irworks" then
    local fx = IR_EFFECT[tostring(code)]
    if fx then fx() end
  end
end
function C4:SendIRStart(binding, code) irFired[#irFired+1] = { binding = binding, code = tostring(code), start = true } end
function C4:SendIRStop(binding, code)  irFired[#irFired+1] = { binding = binding, code = tostring(code), stop = true } end
function C4:CreateNetworkConnection() end
function C4:NetPortOptions() end
function C4:NetDisconnect() sslOnline = false end
function C4:NetConnect(binding, port)
  -- "certfail" simulates a bar that refuses the client certificate: the socket closes without
  -- ever coming ONLINE, which is what a rotated cert would look like. The compatibility test's
  -- FAILURE verdict is the branch that actually matters, so it has to be exercised.
  if ARCHETYPE == "certfail" then
    schedule(1, function() OnConnectionStatusChanged(binding, port, "OFFLINE") end)
    return
  end
  schedule(1, function() sslOnline = true; OnConnectionStatusChanged(binding, port, "ONLINE") end)
end
function C4:SendToNetwork(binding, port, data)
  local path = data:match("^GET%s+(%S+)")
  local cmd = path and path:match("command=(.*)$") or ""
  cmd = cmd:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  local body = handle(cmd)
  local resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: " ..
    #body .. "\r\n\r\n" .. body
  schedule(1, function()
    ReceivedFromNetwork(binding, port, resp)
    schedule(1, function() OnConnectionStatusChanged(binding, port, "OFFLINE") end)
  end)
end
-- UPnP RenderingControl, simulated. The IR verification reads volume/mute from HERE (not from
-- YAMAHA_DATA_GET, whose "mute"/"Master volume" were shown on hardware not to track), so the sim
-- has to answer these or the reworked sweep cannot be tested offline at all.
-- "premuted" starts the simulated bar MUTED while the driver's belief is still unknown, which
-- is the exact mismatch that made the first press of the remote's mute button do nothing.
upnpVol, upnpMute = 20, (ARCHETYPE == "premuted") and "1" or "0" 
upnpSeq = {}
local function upnpHandle(body)
  local action = body and body:match("<u:(%a+) xmlns") or ""
  upnpSeq[#upnpSeq+1] = action
  if action == "SetVolume" then upnpVol = tonumber(body:match("<DesiredVolume>(%d+)")) or upnpVol
  elseif action == "SetMute" then upnpMute = body:match("<DesiredMute>(%d)") or upnpMute
  elseif action == "GetVolume" then return "<CurrentVolume>" .. upnpVol .. "</CurrentVolume>"
  elseif action == "GetMute" then return "<CurrentMute>" .. upnpMute .. "</CurrentMute>" end
  return "<ok/>"
end
function C4:url()
  return { OnDone = function(s, cb) s._cb = cb; return s end,
           SetOptions = function(s) return s end,
           Post = function(s, url, body)
             local resp = upnpHandle(body)
             -- IR that the sim's bar obeys also moves these, so irworks can score them.
             schedule(1, function() if s._cb then s._cb(nil, resp, 0, "") end end)
           end,
           Get  = function(s) schedule(1, function() if s._cb then s._cb(nil, nil, 1, "sim: no UPnP") end end) end }
end

------------------------------------------------------------------ run
-- "PROXY:<CMD>" drives a receiver-proxy command instead of a Composer Action, and "IR:<CMD>"
-- does the same with Control Method = IR. That second form is what a Navigator/Halo button
-- press actually looks like to the driver, and it is the only way to check offline that a
-- given button reaches the emitter at all -- the failure that looked identical to a dead
-- emitter on real hardware.
local PROXY_CMD  = ACTION:match("^IR:(.+)$") or ACTION:match("^PROXY:(.+)$")
local PROXY_IR   = ACTION:match("^IR:") ~= nil
-- "IRPROP:Name=Value" changes a Composer PROPERTY with Control Method = IR. That is how the
-- DSP toggles and the subwoofer trim are actually driven, and neither path is reachable
-- through a proxy command, so without this they would ship unexercised.
if ACTION:match("^IRACTION:") then PROXY_IR = true; ACTION = ACTION:gsub("^IRACTION:","") end
local PROP_NAME, PROP_VALUE = ACTION:match("^IRPROP:([^=]+)=(.+)$")
if PROP_NAME then PROXY_IR = true
else PROP_NAME, PROP_VALUE = ACTION:match("^PROP:([^=]+)=(.+)$") end

Properties = {
  ["Control Method"] = PROXY_IR and "IR" or "IP - See Documentation for Usage",
  ["IP Address"] = (ARCHETYPE == "noaddr") and "" or "192.168.1.214", ["Owner Approved"] = "Yes",
  ["State Poll Seconds"] = "0", ["Poll Interval Seconds"] = "3",
  ["Log Level"] = "5 - Debug", ["Log Mode"] = "Print",
  ["3D Surround"] = "Off", ["Clear Voice"] = "Off", ["Bass Extension"] = "Off",
}
dofile(DRIVER)
OnDriverInit(); OnDriverLateInit()
if BOUND_IR and OnBindingChanged then OnBindingChanged(2, "IR_OUT", true) end
drain()

print(("==== archetype=%s action=%s ===="):format(ARCHETYPE, ACTION))
local SEQ = ACTION:match("^SEQ:(.+)$")
if SEQ then
  -- A whole room interaction, one command per step, exactly as the proxy sends them. Added after
  -- DISCONNECT_OUTPUT was wired to power and made the bar switch itself off when the user picked
  -- a source that bypasses it: single-command tests all passed while the SEQUENCE was broken.
  for cmd in SEQ:gmatch("[^,]+") do
    local name, arg1 = cmd:match("^([^=]+)=(.+)$")
    name = name or cmd
    ReceivedFromProxy(5001, name, arg1 and
      { LEVEL = arg1, INPUT = arg1, SurroundMode = arg1, MODE = arg1, OUTPUT = arg1 } or {})
    drain()
  end
elseif PROP_NAME then
  Properties[PROP_NAME] = PROP_VALUE
  OnPropertyChanged(PROP_NAME)
elseif PROXY_CMD then
  local name, arg1 = PROXY_CMD:match("^([^=]+)=(.+)$")
  name = name or PROXY_CMD
  -- Proxy commands take differently-named params (LEVEL, INPUT, SurroundMode...). Set the
  -- common ones to the same value so "CMD=value" works for any of them.
  ReceivedFromProxy(5001, name, arg1 and
    { LEVEL = arg1, INPUT = arg1, SurroundMode = arg1, MODE = arg1 } or {})
else
  ExecuteCommand("LUA_ACTION", { ACTION = ACTION })
end
local ticks = drain()

if #irFired > 0 then
  local parts = {}
  for _, f in ipairs(irFired) do
    parts[#parts+1] = (IRCODES[f.code] or "?") .. "(" .. f.code .. ")" ..
      (f.start and "[start]" or f.stop and "[stop]" or "")
  end
  print(("-- IR fired (%d): %s"):format(#irFired, table.concat(parts, " ")))
  for _, f in ipairs(irFired) do
    if f.binding ~= 2 then print(("-- !! IR on binding %s, expected 2"):format(tostring(f.binding))) end
  end
else
  print("-- IR fired: none")
end
do
  local reads = 0
  for _, w in ipairs(writes) do
    if w:match("^YAMAHA_DATA_GET") or w:match("^getPlayerStatus") then reads = reads + 1 end
  end
  do
  local wire = { optical = true, HDMI = true, bluetooth = true, wifi = true }
  local shown = props["Current Input"]
  if shown then
    print(("-- Current Input property: %q%s"):format(shown,
      wire[shown] and "   <-- BUG: that is a Linkplay wire value, not an input name" or ""))
  end
end
do
  local seq = {}
  for _, a in ipairs(upnpSeq) do if a:match("Mute") then seq[#seq+1] = a end end
  print("-- UPnP mute calls, in order: " .. (table.concat(seq, " -> ")))
end
do
  local st = {}
  for _, n in ipairs({"Connected","Power State","Current Input","Current Volume","Muted"}) do
    st[#st+1] = ("%s=%s"):format(n, tostring(props[n]))
  end
  print("-- status props: " .. table.concat(st, "  "))
end
print(("-- bar mute after run: %s   (driver property Muted=%s)")
  :format(tostring(upnpMute), tostring(props["Muted"])))
do
  local pw = {}
  for _, w in ipairs(writes) do
    local v = w:match('power saving"?:"?(%d)')
    if v then pw[#pw+1] = (v == "1") and "ON" or "OFF" end
  end
  print("-- power commands sent: " .. (#pw > 0 and table.concat(pw, " -> ") or "none"))
end
print(("-- state-feedback reads issued: %d (Control Method = %s)")
    :format(reads, tostring(Properties["Control Method"])))
end
print(("-- simulated bar: subwoofer now '%s', %d commands sent, %d timer ticks")
  :format(dev["subwoofer volume"], #writes, ticks))
print(("-- surround notifications sent: %d"):format((function()
  local c = 0; for _, p in ipairs(proxied) do if p.cmd == "SURROUND_MODE_CHANGED" then c = c + 1 end end; return c
end)()))
