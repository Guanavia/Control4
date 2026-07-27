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
                   (binding 6002) with the PLAIN key; getStatusEx returned HTTP 200.
                   C4:url() was abandoned because it cannot present a client certificate.
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

-- Control4 input connection id -> Linkplay switchmode value
local INPUT_MAP = {
  [3000] = "optical",    -- TV (ARC/optical)
  [3001] = "HDMI",       -- HDMI In
  [3002] = "optical",    -- Optical In
  [3003] = "bluetooth",  -- Bluetooth
  [3004] = "wifi",       -- Network / streaming
}
local INPUT_ORDER = { 3000, 3001, 3003, 3004 }
local SWITCH_TO_CONN = { optical = 3000, HDMI = 3001, bluetooth = 3003, wifi = 3004 }

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
  -- Cert probe is advisory ONLY and must never gate a request: Director reads the PEM out
  -- of the .c4z itself.  A failed probe has already been observed on a run whose handshake
  -- then succeeded, so this is a debug note, not a warning.
  if not gCertPresent then
    LogDebug("httpapi '%s': cert probe inconclusive (%s) - proceeding, the handshake decides",
      tostring(command), tostring(gCertInfo))
  end
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
  gCertPresent, gCertInfo = false, nil
  local ok, exists = pcall(function() return C4:FileExists("linkplay_client.pem") end)
  if not ok then
    gCertInfo = "could not probe the bundle (C4:FileExists unavailable)"
  elseif exists then
    gCertPresent = true
    gCertInfo = "linkplay_client.pem present in the .c4z"
  else
    gCertInfo = "linkplay_client.pem not confirmed present (path may not resolve here)"
  end
  -- Deliberately non-authoritative in BOTH directions: Director reads the PEM out of the
  -- .c4z itself for the handshake, so this probe can be wrong either way.  The TLS
  -- handshake in OnConnectionStatusChanged is the only real test.
  LogInfo("client bundle probe: %s (advisory only -- the TLS handshake is the real test)", gCertInfo)
end

local function HttpApiDiag()
  LogInfo("---- httpapi (SSL) diagnostics ----")
  LogInfo("Control Method    : %s", tostring(gCtrlMethod))
  LogInfo("Owner Approved    : %s", gOwnerOK and "Yes (httpapi ENABLED)" or "No (httpapi blocked)")
  LogInfo("IP Address        : '%s'", tostring(gAddress))
  LogInfo("Client bundle     : %s", tostring(gCertInfo or "not checked"))
  LogInfo("                    (advisory -- a failed probe does NOT mean the cert is bad)")
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
    HttpApiGet("getStatusEx", function(ok, body)
      if ok and body then LogInfo("getStatusEx: %s", tostring(body)) end
    end)
  elseif strCommand == "HttpApiDiag"       then HttpApiDiag()
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
end

function OnDriverDestroyed()
  LogInfo("OnDriverDestroyed")
  StopPoll()
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
  elseif sProperty == "Poll Interval Seconds" then
    gPollSecs = tonumber(value) or 3
    if gPollTimer then StartPoll() end
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
