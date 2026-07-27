--[[
  Yamaha Soundbar (umbrella) - Control4 DriverWorks driver
  Model: YAS-209 (Linkplay/WiiMu module).  See research/LINKPLAY_RE.md.

  Control methods (Control Method property): IR / IP / Serial.  IP is implemented:
    * Volume / mute / transport  -> UPnP SOAP on :49152 (no auth).
    * Power / input select        -> Linkplay httpapi on :443 (mutual-TLS, bundled
                                     client cert), GATED by the "Owner Approved" property.

  Confirmed commands (captured + validated on real hardware, research/LINKPLAY_RE.md):
    Power ON  : httpapi YAMAHA_DATA_SET:{"power saving":"1"}
    Power OFF : httpapi YAMAHA_DATA_SET:{"power saving":"0"}   (standby)
    Input     : httpapi setPlayerCmd:switchmode:HDMI|bluetooth|optical  (TV=optical)
    Volume    : UPnP RenderingControl SetVolume (0-100)  |  Mute: SetMute

  STATUS (2026-07-27): BOTH control surfaces VALIDATED on the real bar via a real director.
    * UPnP half  — volume/mute read live.
    * httpapi    — mutual-TLS handshake SUCCEEDS over the raw SSL network connection
                   (binding 6002) with the PLAIN key; getStatusEx returned HTTP 200, and
                   POWER ON/OFF + INPUT SELECT are confirmed working on the bar.
                   C4:url() was abandoned because it cannot present a client certificate.
    Remaining gap: state FEEDBACK.  Power/input are write-only right now — the driver
    reports back what it last sent, not what the bar is actually doing, so anything that
    changes the bar outside Control4 (remote, front panel, app) drifts the UI.
    All soundbar testing is on real hardware — a virtual director cannot reach the bar.

  Bindings: 5001 receiver proxy | 6001 network (UPnP monitor) | 6002 SSL httpapi (:443)
            7000 room end-point | 2000 HDMI out | 3000..3004 input sources
]]

-------------------------------------------------
-- CONSTANTS
-------------------------------------------------
local RECEIVER_BINDING = 5001
local NETWORK_BINDING  = 6001
local SSL_BINDING      = 6002      -- Linkplay httpapi, mutual-TLS (driver.xml classname SSL)
local OUTPUT_BINDING   = 7000
local UPNP_PORT        = 49152
local HTTPAPI_PORT     = 443
local HTTPAPI_TIMEOUT_MS = 10000

-- Passphrase for the bundled private key.  Only consulted when driver.xml marks
-- <private_key protected="True"> -- the shipped build uses a PLAIN key, so Director
-- never calls GetPrivateKeyPassword.  Kept wired so switching to an encrypted key is a
-- one-attribute XML change (build with ENCRYPT_KEY=1) with no Lua edit.
local HTTPAPI_KEY_PASSWORD = "yas209-linkplay"

-- Control4 input connection id -> Linkplay switchmode value.
-- There is deliberately no separate "Optical In": the bar has ONE optical/ARC input and
-- the Linkplay layer exposes ONE switchmode ("optical") for it, which is what the TV
-- input already selects.  A second entry would have been a duplicate of 3000.
local INPUT_MAP = {
  [3000] = "optical",    -- TV (ARC / optical)
  [3001] = "HDMI",       -- HDMI In
  [3003] = "bluetooth",  -- Bluetooth
  [3004] = "wifi",       -- Network / streaming
}
local INPUT_ORDER = { 3000, 3001, 3003, 3004 }
local SWITCH_TO_CONN = { optical = 3000, HDMI = 3001, bluetooth = 3003, wifi = 3004 }

-- getPlayerStatus "mode" (Linkplay source code) -> our input connection id.
-- PROVISIONAL.  The streaming/bluetooth/optical codes are the documented Linkplay values;
-- HDMI on soundbars varies by firmware and is NOT yet confirmed on this unit.  Any mode we
-- do not recognise is logged at WARNING with its raw value, so switching through the inputs
-- once with Debug logging on is enough to complete this table.
local MODE_TO_CONN = {
  ["1"]  = 3004,  -- AirPlay      \
  ["2"]  = 3004,  -- DLNA          |  all "network / streaming" as far as Control4 cares
  ["10"] = 3004,  -- wiimu playlist|
  ["31"] = 3004,  -- Spotify      /
  ["41"] = 3003,  -- Bluetooth
  ["43"] = 3000,  -- Optical == the YAS-209's TV input
}

local RC = "urn:schemas-upnp-org:service:RenderingControl:1"
local AV = "urn:schemas-upnp-org:service:AVTransport:1"
local RC_CTRL = "/upnp/control/rendercontrol1"
local AV_CTRL = "/upnp/control/rendertransport1"

local LOG_LEVEL = { ALERT=0, ERROR=1, WARNING=2, INFO=3, TRACE=4, DEBUG=5 }

-------------------------------------------------
-- STATE
-------------------------------------------------
local gLogLevel   = LOG_LEVEL.WARNING
local gLogMode    = "Off"
local gCtrlMethod = "IP"
local gAddress    = ""
local gOwnerOK    = false
local gPollSecs   = 3

local gConnected  = false
local gPollFails  = 0
local gPollTimer  = nil
local gStatePollSecs  = 30    -- httpapi power/input read-back; 0 = disabled
local gStatePollTimer = nil
local gUnknownModes   = {}    -- modes already reported, so the log warns once each

local gPower      = nil      -- boolean (best-effort; only known when httpapi/Owner Approved)
local gYxcVolume  = nil      -- 0..100 (UPnP)
local gMute       = nil      -- boolean
local gInputSw    = nil      -- switchmode string

-- httpapi (SSL socket) transport state
local gCertPresent = false   -- bundled PEM passed its sanity check (advisory only)
local gCertInfo    = nil     -- human-readable summary for the diagnostics action
local gSslCreated  = false   -- CreateNetworkConnection has bound 6002 to an address
local gSslAddr     = nil     -- the address it was bound to (re-bind if IP changes)
local gSslOnline   = false   -- socket is up and the mutual-TLS handshake succeeded
local gQueue       = {}      -- pending { command, cb } requests
local gInFlight    = nil     -- { command, cb, sent, rx } currently on the wire
local gReqTimer    = nil

-------------------------------------------------
-- LOGGING
-------------------------------------------------
local function Log(level, msg, ...)
  if gLogMode == "Off" then return end
  if level > gLogLevel then return end
  local ok, s = pcall(string.format, msg, ...)
  if not ok then s = tostring(msg) end
  local line = string.format("[YAMAHASB][%s] %s", os.date("%H:%M:%S"), s)
  if gLogMode == "Print" or gLogMode == "Print and Log" then print(line) end
  -- C4:ErrorLog is the DriverWorks director-log fn (C4:Log does not exist); pcall so a
  -- logging-API mismatch can never crash the driver.
  if gLogMode == "Log" or gLogMode == "Print and Log" then pcall(function() C4:ErrorLog(line) end) end
end
local function LogDebug(m,...)   Log(LOG_LEVEL.DEBUG,m,...) end
local function LogTrace(m,...)   Log(LOG_LEVEL.TRACE,m,...) end
local function LogInfo(m,...)    Log(LOG_LEVEL.INFO,m,...) end
local function LogWarning(m,...) Log(LOG_LEVEL.WARNING,m,...) end
local function LogError(m,...)   Log(LOG_LEVEL.ERROR,m,...) end

-------------------------------------------------
-- SMALL HELPERS
-------------------------------------------------
local function trim(s) return (tostring(s or "")):gsub("^%s*(.-)%s*$", "%1") end
local function UpdateProp(name, value) pcall(function() C4:UpdateProperty(name, tostring(value)) end) end
local function DeviceAddress() if gAddress and gAddress ~= "" then return gAddress end return nil end

local function UrlEncode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function SetConnected(c)
  if gConnected == c then return end
  gConnected = c
  UpdateProp("Connected", tostring(c))
  LogInfo("Connected = %s", tostring(c))
end

-------------------------------------------------
-- PROXY NOTIFICATIONS
-------------------------------------------------
local function NotifyPower(on) C4:SendToProxy(RECEIVER_BINDING, on and "ON" or "OFF", {}, "NOTIFY") end
local function NotifyVolume(level)
  C4:SendToProxy(RECEIVER_BINDING, "VOLUME_LEVEL_CHANGED",
    { LEVEL = tostring(level), OUTPUT = tostring(OUTPUT_BINDING) }, "NOTIFY")
end
local function NotifyMute(m)
  C4:SendToProxy(RECEIVER_BINDING, "MUTE_CHANGED",
    { MUTE = tostring(m), OUTPUT = tostring(OUTPUT_BINDING) }, "NOTIFY")
end
local function NotifyInput(connId)
  C4:SendToProxy(RECEIVER_BINDING, "INPUT_OUTPUT_CHANGED",
    { INPUT = tostring(connId), OUTPUT = tostring(OUTPUT_BINDING) }, "NOTIFY")
end

-------------------------------------------------
-- UPnP SOAP LAYER (:49152, plain HTTP, no auth) - volume/mute/transport
-------------------------------------------------
local function SoapEnvelope(service, action, innerXml)
  return '<?xml version="1.0" encoding="utf-8"?>' ..
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ' ..
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>' ..
    '<u:' .. action .. ' xmlns:u="' .. service .. '">' .. (innerXml or "") ..
    '</u:' .. action .. '></s:Body></s:Envelope>'
end

-- cb(ok, body)   [INSTRUMENTED for on-controller diagnosis]
local function Soap(ctrlPath, service, action, innerXml, cb)
  local addr = DeviceAddress()
  if not addr then LogWarning("SOAP %s: no device address (IP Address property empty)", action); if cb then cb(false) end return end
  local url = "http://" .. addr .. ":" .. UPNP_PORT .. ctrlPath
  local body = SoapEnvelope(service, action, innerXml)
  local headers = {
    ["Content-Type"] = 'text/xml; charset="utf-8"',
    ["SOAPACTION"]   = '"' .. service .. '#' .. action .. '"',
    ["Expect"]       = "",   -- suppress libcurl "Expect: 100-continue" (old Boa server 500s on it)
  }
  LogDebug("SOAP -> POST %s  [%s]", url, action)
  local ok, req = pcall(function() return C4:url() end)
  if not ok or not req then LogError("C4:url() unavailable: %s", tostring(req)); if cb then cb(false) end return end
  req:OnDone(function(transfer, responses, errCode, errMsg)
    local rt = type(responses)
    local rbody, rcode
    if rt == "table" then
      local r = responses[#responses] or responses
      if type(r) == "table" then rbody = r.body or r.data; rcode = r.code end
    elseif rt == "string" then rbody = responses end
    LogDebug("SOAP OnDone %s: err=%s httpcode=%s bodylen=%s",
      action, tostring(errCode), tostring(rcode), tostring(rbody and #rbody or "nil"))
    -- treat a 2xx OR any body we can parse as usable
    local usable = (rbody ~= nil and rbody ~= "") and (rcode == nil or rcode < 400)
    if cb then cb(usable, rbody) end
  end)
  pcall(function() req:SetOptions({ fail_on_error = false, timeout = 6, connect_timeout = 4 }) end)
  -- headers go as the 3rd arg to Post (NOT via SetOptions)
  local okp, errp = pcall(function() req:Post(url, body, headers) end)
  if not okp then LogError("SOAP req:Post threw: %s", tostring(errp)) end
end

-------------------------------------------------
-- httpapi TRANSPORT (:443 mutual-TLS over a raw SSL network connection) - power/input
-- GATED by Owner Approved.
--
-- WHY A RAW SOCKET AND NOT C4:url():  C4:url() has NO client-certificate support
-- (confirmed against Control4's own global/url.lua -- SetOptions handles cookies /
-- fail_on_error / timeouts, and nothing else).  The bar REQUIRES a client cert for
-- mutual TLS on :443, so the url interface can never authenticate.  Instead driver.xml
-- declares binding 6002 / port 443 with classname SSL + certificate/private_key/cacert;
-- Director performs the handshake and hands us a plain byte stream, over which we speak
-- HTTP/1.1 ourselves.
--
-- The bar runs an old Boa server (the same one that 500s on "Expect: 100-continue"), so
-- we send "Connection: close" and treat the socket close as end-of-body.  Content-Length
-- is honoured when present, which usually completes the request before the close arrives.
-- One connect per request; power/input are infrequent enough that this is free.
-------------------------------------------------
local PumpQueue   -- forward declaration (HttpApiFinish pumps the next request)

-- Split a raw HTTP response.  Returns code, body, contentLength, headerBlock.
local function ParseHttpResponse(raw)
  if not raw or raw == "" then return nil end
  local head, body = raw:match("^(.-)\r\n\r\n(.*)$")
  if not head then return nil end
  local code = tonumber(head:match("^HTTP/%d%.%d%s+(%d+)"))
  local clen = tonumber(head:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
  return code, body, clen, head
end

local function HttpApiFinish(ok, body, why)
  local req = gInFlight
  gInFlight = nil
  if gReqTimer then pcall(function() gReqTimer:Cancel() end); gReqTimer = nil end
  -- We always asked for "Connection: close", so the socket is spent either way.
  pcall(function() C4:NetDisconnect(SSL_BINDING, HTTPAPI_PORT) end)
  gSslOnline = false
  if req then
    if ok then
      LogDebug("httpapi '%s' OK (%s, %d byte body)", req.command, tostring(why), #(body or ""))
    else
      LogWarning("httpapi '%s' FAILED: %s", req.command, tostring(why or "unknown"))
    end
    if req.cb then pcall(req.cb, ok, body) end
  end
  if PumpQueue then PumpQueue() end
end

local function SendHttpApiRequest()
  local req = gInFlight
  if not req then return end
  local addr = DeviceAddress()
  if not addr then HttpApiFinish(false, nil, "IP Address property is empty"); return end
  local path = "/httpapi.asp?command=" .. UrlEncode(req.command)
  local wire = table.concat({
    "GET " .. path .. " HTTP/1.1",
    "Host: " .. addr,
    "User-Agent: Control4/DriverWorks",
    "Accept: */*",
    "Connection: close",
    "", "",
  }, "\r\n")
  req.sent = true
  req.rx   = ""
  LogDebug("httpapi TX -> %s:%d %s", addr, HTTPAPI_PORT, path)
  local ok, err = pcall(function() C4:SendToNetwork(SSL_BINDING, HTTPAPI_PORT, wire) end)
  if not ok then HttpApiFinish(false, nil, "SendToNetwork threw: " .. tostring(err)) end
end

-- Bind the declared SSL connection to the address from the IP Address property, so the
-- dealer never types the IP twice.  This is the documented pattern for a static SSL
-- <connection>: CreateNetworkConnection -> (NetPortOptions) -> NetConnect.
local function EnsureSslConnection()
  local addr = DeviceAddress()
  if not addr then return false end
  if gSslCreated and gSslAddr == addr then return true end
  local ok, err = pcall(function() C4:CreateNetworkConnection(SSL_BINDING, addr, "SSL") end)
  if not ok then
    LogError("CreateNetworkConnection(%d, %s, SSL) threw: %s", SSL_BINDING, addr, tostring(err))
    return false
  end
  -- Belt-and-braces: the XML already declares these, but re-asserting them costs nothing
  -- and makes the intent explicit if the XML port block is ever edited.
  pcall(function()
    C4:NetPortOptions(SSL_BINDING, HTTPAPI_PORT, "SSL", {
      AUTO_CONNECT = false, KEEP_CONNECTION = false, MONITOR_CONNECTION = false,
    })
  end)
  gSslCreated, gSslAddr = true, addr
  LogInfo("httpapi SSL connection bound to %s:%d", addr, HTTPAPI_PORT)
  return true
end

PumpQueue = function()
  if gInFlight then return end
  local req = table.remove(gQueue, 1)
  if not req then return end
  gInFlight = req
  gReqTimer = C4:SetTimer(HTTPAPI_TIMEOUT_MS, function()
    gReqTimer = nil
    HttpApiFinish(false, nil, string.format("timeout after %dms", HTTPAPI_TIMEOUT_MS))
  end, false)
  if not EnsureSslConnection() then
    HttpApiFinish(false, nil, "could not bind the SSL connection")
    return
  end
  if gSslOnline then
    SendHttpApiRequest()
  else
    LogDebug("httpapi: connecting %s:%d (mutual-TLS handshake) ...", tostring(gSslAddr), HTTPAPI_PORT)
    local ok, err = pcall(function() C4:NetConnect(SSL_BINDING, HTTPAPI_PORT) end)
    if not ok then HttpApiFinish(false, nil, "NetConnect threw: " .. tostring(err)) end
  end
end

local function HttpApiGet(command, cb)
  if not gOwnerOK then
    LogWarning("httpapi blocked: Owner Approved = No (power/input over IP disabled)")
    if cb then cb(false) end; return
  end
  if not DeviceAddress() then
    LogWarning("httpapi '%s': no device address (IP Address property empty)", tostring(command))
    if cb then cb(false) end; return
  end
  -- NO per-request cert check.  Lua cannot see inside the .c4z (both C4:ReadFile and
  -- C4:FileExists fail on bundles whose handshake then succeeds), so any such line is
  -- noise at best and misleading at worst.  The handshake decides.
  gQueue[#gQueue + 1] = { command = command, cb = cb }
  LogTrace("httpapi queued '%s' (depth %d)", tostring(command), #gQueue)
  PumpQueue()
end

-------------------------------------------------
-- SETTERS
-------------------------------------------------
local function xmlval(body, tag) return body and body:match("<" .. tag .. ">(.-)</" .. tag .. ">") end

local function SetVolumeLevel(level)
  if not level then return end
  if level < 0 then level = 0 elseif level > 100 then level = 100 end
  gYxcVolume = level
  UpdateProp("Current Volume", tostring(level))
  NotifyVolume(level)
  Soap(RC_CTRL, RC, "SetVolume",
    "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>" .. level .. "</DesiredVolume>")
end

local function VolStep(dir)
  local base = gYxcVolume or 20
  SetVolumeLevel(base + (dir == "up" and 3 or -3))
end

local function SetMute(m)
  gMute = m
  UpdateProp("Muted", tostring(m))
  NotifyMute(m)
  Soap(RC_CTRL, RC, "SetMute",
    "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredMute>" .. (m and "1" or "0") .. "</DesiredMute>")
end

local function SetPower(on)
  gPower = on
  UpdateProp("Power State", on and "On" or "Standby")
  NotifyPower(on)
  -- Power over IP is httpapi (mutual-TLS), gated by Owner Approved.
  HttpApiGet('YAMAHA_DATA_SET:{"power saving":"' .. (on and "1" or "0") .. '"}')
end

local function SelectInputByConn(connId)
  local sw = INPUT_MAP[connId]
  if not sw then LogWarning("unknown input connection id %s", tostring(connId)); return end
  gInputSw = sw
  UpdateProp("Current Input", sw)
  NotifyInput(connId)
  HttpApiGet("setPlayerCmd:switchmode:" .. sw)
end

local function CycleInput()
  local cur = gInputSw and SWITCH_TO_CONN[gInputSw] or nil
  local idx = 1
  for i, id in ipairs(INPUT_ORDER) do if id == cur then idx = i; break end end
  SelectInputByConn(INPUT_ORDER[(idx % #INPUT_ORDER) + 1])
end

local function Transport(action)
  Soap(AV_CTRL, AV, action, "<InstanceID>0</InstanceID>" .. (action == "Play" and "<Speed>1</Speed>" or ""))
end

local function ConnIdFromParams(t)
  if type(t) ~= "table" then return nil end
  for _, k in ipairs({ "InputBindingID", "INPUT", "idBinding", "BindingID", "IDBINDING" }) do
    local v = tonumber(t[k]); if v and INPUT_MAP[v] then return v end
  end
  for _, v in pairs(t) do local n = tonumber(v); if n and INPUT_MAP[n] then return n end end
  return nil
end

-------------------------------------------------
-- POLLING (UPnP volume/mute; no cert needed)
-------------------------------------------------
local function Poll()
  Soap(RC_CTRL, RC, "GetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel>", function(ok, body)
    if not ok or not body then
      gPollFails = gPollFails + 1
      if gPollFails >= 3 then SetConnected(false) end
      return
    end
    gPollFails = 0; SetConnected(true)
    local v = tonumber(xmlval(body, "CurrentVolume"))
    if v and v ~= gYxcVolume then
      gYxcVolume = v; UpdateProp("Current Volume", tostring(v)); NotifyVolume(v)
    end
  end)
  Soap(RC_CTRL, RC, "GetMute", "<InstanceID>0</InstanceID><Channel>Master</Channel>", function(ok, body)
    if not ok or not body then return end
    local m = xmlval(body, "CurrentMute")
    if m then
      local mb = (m == "1" or m == "true")
      if mb ~= gMute then gMute = mb; UpdateProp("Muted", tostring(mb)); NotifyMute(mb) end
    end
  end)
end

local function StopPoll() if gPollTimer then gPollTimer:Cancel(); gPollTimer = nil end end
local function StartPoll()
  StopPoll()
  if gCtrlMethod ~= "IP" then return end
  Poll()
  gPollTimer = C4:SetTimer(gPollSecs * 1000, function(timer)
    Poll()
    if timer and timer.Reset then timer:Reset() end
  end, false)
end

-------------------------------------------------
-- STATE FEEDBACK (power / input, read back over httpapi)
--
-- Separate and MUCH slower than the UPnP poll above on purpose.  UPnP is cheap plaintext
-- SOAP; every httpapi read is a full mutual-TLS handshake, because each request is one
-- connect with "Connection: close".  Polling this at the volume/mute cadence would mean a
-- TLS handshake every few seconds, forever.
--
-- These apply state WITHOUT re-sending commands -- they reflect what the bar reports, so
-- the UI stays right when someone uses the Yamaha remote or the front panel.
-------------------------------------------------
local gPowerKeyWarned = false

local function pesc(s) return (tostring(s):gsub("(%W)", "%%%1")) end
local function jsonstr(body, key)
  if not body then return nil end
  return body:match('"' .. pesc(key) .. '"%s*:%s*"([^"]*)"')
end

local function ApplyPowerState(on)
  if on == gPower then return end
  gPower = on
  UpdateProp("Power State", on and "On" or "Standby")
  NotifyPower(on)
  LogInfo("power changed at the bar -> %s", on and "On" or "Standby")
end

local function ApplyInputState(connId)
  local sw = INPUT_MAP[connId]
  if not sw or gInputSw == sw then return end
  gInputSw = sw
  UpdateProp("Current Input", sw)
  NotifyInput(connId)
  LogInfo("input changed at the bar -> %s (connection %d)", sw, connId)
end

local function PollHttpApiState()
  if gCtrlMethod ~= "IP" or not gOwnerOK or gStatePollSecs <= 0 then return end

  HttpApiGet("getPlayerStatus", function(ok, body)
    if not ok or not body then return end
    LogDebug("getPlayerStatus raw: %s", body)
    local mode = jsonstr(body, "mode")
    if not mode then return end
    local conn = MODE_TO_CONN[mode]
    if conn then
      ApplyInputState(conn)
    elseif not gUnknownModes[mode] then
      -- Warn once per distinct value, not every poll.
      gUnknownModes[mode] = true
      LogWarning("getPlayerStatus mode='%s' is not in MODE_TO_CONN -- note which input is " ..
        "physically selected right now and add it to that table in driver.lua", mode)
    end
  end)

  HttpApiGet("YAMAHA_DATA_GET", function(ok, body)
    if not ok or not body then return end
    LogDebug("YAMAHA_DATA_GET raw: %s", body)
    local ps = jsonstr(body, "power saving")
    if ps == "1" then ApplyPowerState(true)
    elseif ps == "0" then ApplyPowerState(false)
    elseif not gPowerKeyWarned then
      gPowerKeyWarned = true
      LogWarning("YAMAHA_DATA_GET returned no \"power saving\" field, so power feedback is " ..
        "unavailable until the right key is identified. Run the 'Probe Yamaha Settings' Action " ..
        "and read the raw payload.")
    end
  end)
end

local function StopStatePoll()
  if gStatePollTimer then gStatePollTimer:Cancel(); gStatePollTimer = nil end
end

local function StartStatePoll()
  StopStatePoll()
  if gCtrlMethod ~= "IP" or not gOwnerOK or gStatePollSecs <= 0 then
    LogDebug("state feedback off (method=%s ownerOK=%s interval=%s)",
      tostring(gCtrlMethod), tostring(gOwnerOK), tostring(gStatePollSecs))
    return
  end
  -- Deliberately NO immediate poll: OnDriverLateInit walks every property, so firing here
  -- would touch off a burst of TLS handshakes on load.  First read happens one interval in.
  gStatePollTimer = C4:SetTimer(gStatePollSecs * 1000, function(timer)
    PollHttpApiState()
    if timer and timer.Reset then timer:Reset() end
  end, false)
  LogInfo("state feedback on: power/input read back every %ds", gStatePollSecs)
end

-- On-demand capability discovery.  Dumps the raw payloads of every read command we know,
-- which is how the surround/EQ field names and the input mode codes get pinned down.
local function ProbeSettings()
  if not gOwnerOK then
    LogWarning("Probe Yamaha Settings needs Owner Approved = Yes (it uses httpapi)")
    return
  end
  LogInfo("---- Yamaha settings probe ----")
  LogInfo("Run this once per state you care about (each surround mode, each EQ preset, each")
  LogInfo("input) and diff the payloads -- the fields that move are the ones to drive.")
  for _, cmd in ipairs({ "YAMAHA_DATA_GET", "getPlayerStatus", "getStatusEx" }) do
    HttpApiGet(cmd, function(ok, body)
      if ok then LogInfo("[probe] %s ->\n%s", cmd, tostring(body))
      else LogWarning("[probe] %s FAILED", cmd) end
    end)
  end
end

-------------------------------------------------
-- LEARN INPUT MODE CODES (closes MODE_TO_CONN without guesswork)
--
-- The SEND side (setPlayerCmd:switchmode:<string>) is confirmed working, and the READ side
-- (getPlayerStatus "mode") returns a NUMBER.  Knowing the string works tells us nothing
-- about the number -- but driving a KNOWN input and then reading the mode back does, because
-- ground truth is whatever we just selected.  This walks every input doing exactly that and
-- prints a paste-ready table, then restores the input it started on.
--
-- Physically cycles the bar's inputs.  Deliberate, operator-triggered, ~4 inputs x settle.
-------------------------------------------------
local LEARN_SETTLE_MS = 3000
local gLearn = nil

local function LearnFinish()
  LogInfo("---- learned input mode codes ----")
  local any = false
  for _, r in ipairs(gLearn.results) do
    LogInfo("  connection %d (%s) -> mode %s", r.conn, r.sw, r.mode and ('"' .. r.mode .. '"') or "NO READING")
    if r.mode then any = true end
  end
  if any then
    LogInfo("Paste into MODE_TO_CONN in driver.lua:")
    for _, r in ipairs(gLearn.results) do
      if r.mode then LogInfo('    ["%s"] = %d,  -- %s', r.mode, r.conn, r.sw) end
    end
  else
    LogWarning("no mode readings at all -- getPlayerStatus may not carry a 'mode' field on " ..
      "this firmware. Run 'Probe Yamaha Settings' and read its raw payload.")
  end
  local restore = gLearn.restore
  gLearn = nil
  if restore then
    LogInfo("[learn] restoring the input that was selected before the sweep (%s)", INPUT_MAP[restore])
    HttpApiGet("setPlayerCmd:switchmode:" .. INPUT_MAP[restore])
  end
  LogInfo("----------------------------------")
end

local function LearnStep()
  if not gLearn then return end
  local connId = INPUT_ORDER[gLearn.idx]
  if not connId then LearnFinish(); return end
  local sw = INPUT_MAP[connId]
  LogInfo("[learn] %d/%d selecting %s (connection %d) ...", gLearn.idx, #INPUT_ORDER, sw, connId)
  HttpApiGet("setPlayerCmd:switchmode:" .. sw, function(okSet)
    if not okSet then LogWarning("[learn] switchmode %s FAILED -- reading anyway", sw) end
    C4:SetTimer(LEARN_SETTLE_MS, function()
      HttpApiGet("getPlayerStatus", function(okGet, body)
        local mode = okGet and jsonstr(body, "mode") or nil
        if okGet then LogDebug("[learn] raw: %s", tostring(body)) end
        gLearn.results[#gLearn.results + 1] = { conn = connId, sw = sw, mode = mode }
        LogInfo("[learn] %s -> mode=%s", sw, tostring(mode))
        gLearn.idx = gLearn.idx + 1
        LearnStep()
      end)
    end, false)
  end)
end

local function LearnInputCodes()
  if not gOwnerOK then
    LogWarning("Learn Input Codes needs Owner Approved = Yes (it uses httpapi)")
    return
  end
  if gLearn then LogWarning("a learn sweep is already running"); return end
  local restore = gInputSw and SWITCH_TO_CONN[gInputSw] or nil
  gLearn = { idx = 1, results = {}, restore = restore }
  LogInfo("---- learning input mode codes: this WILL cycle the bar through every input ----")
  LearnStep()
end

-------------------------------------------------
-- RECEIVER PROXY COMMANDS (5001)
-------------------------------------------------
local ReceiverCommands = {}
function ReceiverCommands.ON()  SetPower(true)  end
function ReceiverCommands.OFF() SetPower(false) end
function ReceiverCommands.SET_VOLUME_LEVEL(p) SetVolumeLevel(tonumber(p and p.LEVEL)) end
function ReceiverCommands.PULSE_VOL_UP()   VolStep("up")   end
function ReceiverCommands.PULSE_VOL_DOWN() VolStep("down") end
function ReceiverCommands.MUTE_ON()     SetMute(true)  end
function ReceiverCommands.MUTE_OFF()    SetMute(false) end
function ReceiverCommands.MUTE_TOGGLE() SetMute(not gMute) end
function ReceiverCommands.SET_INPUT(p)  local id = ConnIdFromParams(p); if id then SelectInputByConn(id) end end
function ReceiverCommands.PULSE_INPUT() CycleInput() end

-------------------------------------------------
-- CLIENT CERT (bundled; gray-area material, gitignored from repo)
--
-- Director itself reads linkplay_client.pem out of the .c4z for the SSL handshake (the
-- paths are in driver.xml).  This check is purely a bringup aid: it tells the log what
-- the bundle actually contains, and never gates a request.
-------------------------------------------------
local function CheckCert()
  -- HISTORY, so nobody re-introduces this: the first version called C4:ReadFile(), which
  -- DOES NOT EXIST in DriverWorks (0 hits across Control4's published API -- same trap as
  -- C4:Log).  Wrapped in pcall, it failed silently and reported "cert not readable" on a
  -- bundle that was in fact perfect, on the very run where the handshake SUCCEEDED.
  -- C4:FileExists is the real API.  Do NOT probe with C4:FileOpen: it CREATES the file
  -- when missing, which would manufacture a false pass.
  -- SECOND FINDING (2026-07-27, on hardware): C4:FileExists ALSO returns false for a
  -- .c4z-bundled file, on the very runs whose handshake succeeded.  Lua simply cannot see
  -- inside the archive -- only Director can, and it reads the PEM itself using the paths in
  -- driver.xml.  So there is NO Lua-side probe that can tell us anything true here, and a
  -- "missing cert" line would be a lie.  Report the state of knowledge honestly instead.
  gCertPresent, gCertInfo = false, nil
  local ok, exists = pcall(function() return C4:FileExists("linkplay_client.pem") end)
  gCertPresent = (ok and exists) and true or false
  if gCertPresent then
    gCertInfo = "linkplay_client.pem visible to Lua"
  else
    gCertInfo = "not visible to Lua (expected -- .c4z contents are Director's to read)"
  end
  LogInfo("client bundle: %s; the TLS handshake is the only real test", gCertInfo)
end

local function HttpApiDiag()
  LogInfo("---- httpapi (SSL) diagnostics ----")
  LogInfo("Control Method    : %s", tostring(gCtrlMethod))
  LogInfo("Owner Approved    : %s", gOwnerOK and "Yes (httpapi ENABLED)" or "No (httpapi blocked)")
  LogInfo("IP Address        : '%s'", tostring(gAddress))
  LogInfo("Client bundle     : %s", tostring(gCertInfo or "not checked"))
  LogInfo("                    (Lua cannot read .c4z contents; not-visible is NORMAL)")
  LogInfo("SSL binding %d    : created=%s addr=%s online=%s",
    SSL_BINDING, tostring(gSslCreated), tostring(gSslAddr), tostring(gSslOnline))
  LogInfo("Queue depth       : %d, in flight: %s",
    #gQueue, gInFlight and tostring(gInFlight.command) or "none")
  LogInfo("----------------------------------")
end

-- Called by Director ONLY when driver.xml marks <private_key protected="True">.
function GetPrivateKeyPassword(Binding, Port)
  LogInfo("GetPrivateKeyPassword(%s, %s) -> supplying bundled key passphrase",
    tostring(Binding), tostring(Port))
  return HTTPAPI_KEY_PASSWORD
end

-------------------------------------------------
-- ACTIONS / COMMANDS
-------------------------------------------------
function ExecuteCommand(strCommand, tParams)
  -- Composer Actions arrive as "LUA_ACTION" with the real action name in tParams.ACTION.
  if strCommand == "LUA_ACTION" then
    if type(tParams) == "table" and tParams["ACTION"] then
      strCommand = tParams["ACTION"]
    else
      local keys = {}
      if type(tParams) == "table" then for k, v in pairs(tParams) do keys[#keys+1] = tostring(k) .. "=" .. tostring(v) end end
      LogInfo("LUA_ACTION params (need the action key): %s", table.concat(keys, ", "))
    end
  end
  LogTrace("ExecuteCommand: %s", tostring(strCommand))
  if     strCommand == "RefreshNow"        then Poll()
  elseif strCommand == "PowerOn"           then SetPower(true)
  elseif strCommand == "PowerOff"          then SetPower(false)
  elseif strCommand == "TransportPlay"     then Transport("Play")
  elseif strCommand == "TransportPause"    then Transport("Pause")
  elseif strCommand == "TransportStop"     then Transport("Stop")
  elseif strCommand == "TransportNext"     then Transport("Next")
  elseif strCommand == "TransportPrevious" then Transport("Previous")
  elseif strCommand == "QueryDeviceInfo"   then
    -- Identity/capabilities only.  Proven on hardware: five captures at five different
    -- inputs differed ONLY in the clock, and there is no mode/source/input field at all.
    HttpApiGet("getStatusEx", function(ok, body)
      if ok and body then
        LogInfo("getStatusEx: %s", tostring(body))
        LogInfo("(identity/capabilities only -- this command NEVER reflects input or " ..
          "playback state. Use 'Probe Yamaha Settings' for that.)")
      end
    end)
  elseif strCommand == "HttpApiDiag"       then HttpApiDiag()
  elseif strCommand == "ProbeSettings"     then ProbeSettings()
  elseif strCommand == "LearnInputCodes"   then LearnInputCodes()
  elseif strCommand == "TestHttpApi"       then
    -- Hardware-bringup probe: the single most informative thing to run first.
    HttpApiDiag()
    LogInfo("httpapi test: sending getStatusEx over the SSL socket ...")
    HttpApiGet("getStatusEx", function(ok, body)
      if ok then
        LogInfo("httpapi TEST PASSED -- the bar answered over mutual TLS. Body: %s", tostring(body))
      else
        LogWarning("httpapi TEST FAILED -- see the preceding lines for the failure point.")
      end
    end)
  else LogTrace("Unhandled command: %s", tostring(strCommand)) end
end

-------------------------------------------------
-- CONTROL4 LIFECYCLE
-------------------------------------------------
function OnDriverInit()  LogInfo("OnDriverInit") end

function OnDriverLateInit()
  LogInfo("Yamaha Soundbar driver loaded (build 2026-07-27-a; UPnP validated on hardware, httpapi now on a raw SSL socket)")
  UpdateProp("Driver Version", "2.1.0")
  for k, _ in pairs(Properties or {}) do OnPropertyChanged(k) end
  CheckCert()
  StartPoll()
  StartStatePoll()
end

function OnDriverDestroyed()
  LogInfo("OnDriverDestroyed")
  StopPoll()
  StopStatePoll()
  if gReqTimer then pcall(function() gReqTimer:Cancel() end); gReqTimer = nil end
  if gSslCreated then pcall(function() C4:NetDisconnect(SSL_BINDING, HTTPAPI_PORT) end) end
end

function OnPropertyChanged(sProperty)
  local value = Properties and Properties[sProperty]
  LogTrace("OnPropertyChanged: %s = %s", tostring(sProperty), tostring(value))
  if sProperty == "Log Level" then
    gLogLevel = tonumber(string.match(value or "", "^(%d+)")) or LOG_LEVEL.WARNING
  elseif sProperty == "Log Mode" then
    gLogMode = value or "Off"
  elseif sProperty == "Control Method" then
    gCtrlMethod = value or "IP"
    StartPoll()
    StartStatePoll()
  elseif sProperty == "IP Address" then
    local newAddr = trim(value)
    if newAddr ~= gAddress then
      -- Force the SSL binding to be re-bound to the new address on the next request.
      if gSslCreated then pcall(function() C4:NetDisconnect(SSL_BINDING, HTTPAPI_PORT) end) end
      gSslCreated, gSslAddr, gSslOnline = false, nil, false
    end
    gAddress = newAddr
    if gAddress ~= "" then StartPoll() end
  elseif sProperty == "Owner Approved" then
    gOwnerOK = (value == "Yes")
    LogInfo("Owner Approved = %s (httpapi power/input %s)", tostring(value), gOwnerOK and "ENABLED" or "disabled")
    StartStatePoll()   -- state feedback rides on httpapi, so it follows this gate
  elseif sProperty == "Poll Interval Seconds" then
    gPollSecs = tonumber(value) or 3
    if gPollTimer then StartPoll() end
  elseif sProperty == "State Poll Seconds" then
    gStatePollSecs = tonumber(value) or 30
    StartStatePoll()
  end
end

function OnConnectionStatusChanged(nBinding, nPort, sStatus)
  LogTrace("OnConnectionStatusChanged: binding=%s port=%s status=%s",
    tostring(nBinding), tostring(nPort), tostring(sStatus))

  if nBinding == NETWORK_BINDING then
    if sStatus == "ONLINE" then SetConnected(true) end
    return
  end

  if nBinding ~= SSL_BINDING then return end

  if sStatus == "ONLINE" then
    gSslOnline = true
    LogInfo("httpapi SSL socket ONLINE -- mutual-TLS handshake SUCCEEDED (client cert accepted)")
    if gInFlight and not gInFlight.sent then SendHttpApiRequest() end
    return
  end

  gSslOnline = false
  LogDebug("httpapi SSL socket %s", tostring(sStatus))
  if not (gInFlight and gInFlight.sent) then
    -- Went down before we sent anything: a handshake rejection looks exactly like this.
    if gInFlight then
      HttpApiFinish(false, nil, "socket went " .. tostring(sStatus) ..
        " before the request was sent (handshake rejected? check the client cert)")
    end
    return
  end
  -- We asked for "Connection: close", so a close AFTER the request is the normal
  -- end-of-response, not a failure -- provided we actually received something.
  local raw = gInFlight.rx or ""
  if #raw > 0 then
    local code, body = ParseHttpResponse(raw)
    if code then HttpApiFinish(code < 400, body, "HTTP " .. code)
    else HttpApiFinish(false, raw, "unparseable response (" .. #raw .. " bytes)") end
  else
    HttpApiFinish(false, nil, "socket closed with no response at all (status=" .. tostring(sStatus) .. ")")
  end
end

function ReceivedFromNetwork(nBinding, nPort, sData)
  if nBinding ~= SSL_BINDING then return end
  if not gInFlight then
    LogTrace("httpapi RX with no request in flight (%d bytes discarded)", #(sData or ""))
    return
  end
  gInFlight.rx = (gInFlight.rx or "") .. (sData or "")
  LogTrace("httpapi RX %d bytes (%d buffered)", #(sData or ""), #gInFlight.rx)
  -- Complete early when Content-Length says we have the whole body; otherwise wait for
  -- the close (handled in OnConnectionStatusChanged).
  local code, body, clen = ParseHttpResponse(gInFlight.rx)
  if code and clen and body and #body >= clen then
    HttpApiFinish(code < 400, body, "HTTP " .. code)
  end
end

function ReceivedFromProxy(idBinding, sCommand, tParams)
  LogTrace("ReceivedFromProxy: binding=%s cmd=%s", tostring(idBinding), tostring(sCommand))
  if idBinding == RECEIVER_BINDING then
    local h = ReceiverCommands[sCommand]
    if h then h(tParams) else LogWarning("Unhandled receiver command: %s", tostring(sCommand)) end
  else
    LogWarning("ReceivedFromProxy: unknown binding %s", tostring(idBinding))
  end
end

LogInfo("driver.lua loaded (Yamaha Soundbar / Linkplay IP)")
