-- Offline harness for the Yamaha soundbar driver.
-- Stubs the DriverWorks C4 API and simulates the bar's SSL socket end-to-end: NetConnect ->
-- ONLINE -> SendToNetwork -> ReceivedFromNetwork(HTTP response) -> OFFLINE.  That exercises the
-- real httpapi transport and HTTP parsing, not just the learn logic.

local DRIVER = arg[1]
local ARCHETYPE = arg[2] or "clamp"   -- clamp | reject | acceptall
local ACTION = arg[3] or "LearnSubwooferRange"

------------------------------------------------------------------ simulated bar
local dev = {
  ["power saving"] = "1", ["sound program"] = "movie", ["3D surround"] = "1",
  ["clear voice"] = "0", ["bass extension"] = "0", ["subwoofer volume"] = "0",
  ["Master volume"] = "24", ["Audio Stream"] = "PCM",
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
local sslOnline = false
C4 = {}
function C4:ErrorLog(s) end
function C4:UpdateProperty(n, v) props[n] = v end
function C4:SendToProxy(b, cmd, params, kind) proxied[#proxied+1] = { cmd = cmd, params = params } end
function C4:SetTimer(ms, fn, rep) schedule(ms, fn); return { Cancel = function() end, Reset = function() end } end
function C4:FileExists() return true end
function C4:CreateNetworkConnection() end
function C4:NetPortOptions() end
function C4:NetDisconnect() sslOnline = false end
function C4:NetConnect(binding, port)
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
function C4:url()
  return { OnDone = function(s, cb) s._cb = cb; return s end,
           SetOptions = function(s) return s end,
           Post = function(s) schedule(1, function() if s._cb then s._cb(nil, nil, 1, "sim: no UPnP") end end) end,
           Get  = function(s) schedule(1, function() if s._cb then s._cb(nil, nil, 1, "sim: no UPnP") end end) end }
end

------------------------------------------------------------------ run
Properties = {
  ["Control Method"] = "IP", ["IP Address"] = "192.168.1.214", ["Owner Approved"] = "Yes",
  ["State Poll Seconds"] = "0", ["Poll Interval Seconds"] = "3",
  ["Log Level"] = "5 - Debug", ["Log Mode"] = "Print",
  ["3D Surround"] = "Off", ["Clear Voice"] = "Off", ["Bass Extension"] = "Off",
}
dofile(DRIVER)
OnDriverInit(); OnDriverLateInit()
drain()

print(("==== archetype=%s action=%s ===="):format(ARCHETYPE, ACTION))
ExecuteCommand("LUA_ACTION", { ACTION = ACTION })
local ticks = drain()

print(("-- simulated bar: subwoofer now '%s', %d commands sent, %d timer ticks")
  :format(dev["subwoofer volume"], #writes, ticks))
print(("-- surround notifications sent: %d"):format((function()
  local c = 0; for _, p in ipairs(proxied) do if p.cmd == "SURROUND_MODE_CHANGED" then c = c + 1 end end; return c
end)()))
