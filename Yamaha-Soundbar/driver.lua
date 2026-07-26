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

  ON-DEVICE VALIDATION POINT: the mutual-TLS httpapi transport (HttpApiGet) uses C4:url()
  client-cert options whose exact form can vary by OS version — it is isolated in ONE
  function so it can be adjusted in one place when first run on a controller.

  Bindings: 5001 receiver proxy | 6001 network (monitor) | 7000 room end-point
            2000 HDMI out | 3000..3004 input sources
]]

-------------------------------------------------
-- CONSTANTS
-------------------------------------------------
local RECEIVER_BINDING = 5001
local NETWORK_BINDING  = 6001
local OUTPUT_BINDING   = 7000
local UPNP_PORT        = 49152

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

local gClientCertPem = nil   -- bundled Linkplay client cert (PEM), loaded at init
local gClientKeyPem  = nil

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

-- cb(ok, body)
local function Soap(ctrlPath, service, action, innerXml, cb)
  local addr = DeviceAddress()
  if not addr then if cb then cb(false) end return end
  local url = "http://" .. addr .. ":" .. UPNP_PORT .. ctrlPath
  local body = SoapEnvelope(service, action, innerXml)
  local headers = {
    ["Content-Type"] = 'text/xml; charset="utf-8"',
    ["SOAPACTION"]   = '"' .. service .. '#' .. action .. '"',
  }
  local ok, req = pcall(function() return C4:url() end)
  if not ok or not req then LogError("C4:url() unavailable"); if cb then cb(false) end return end
  req:OnDone(function(transfer, responses, errCode, errMsg)
    local rbody
    if type(responses) == "table" then
      local r = responses[#responses] or responses
      if type(r) == "table" then rbody = r.body or r.data end
    elseif type(responses) == "string" then rbody = responses end
    if cb then cb((errCode == 0 or errCode == nil) and rbody ~= nil, rbody) end
  end)
  pcall(function() req:SetOptions({ headers = headers, timeout = 6, connect_timeout = 4 }) end)
  req:Post(url, body)
end

-------------------------------------------------
-- httpapi LAYER (:443 mutual-TLS, bundled client cert) - power/input
-- GATED by Owner Approved.  *** ON-DEVICE VALIDATION POINT ***
-------------------------------------------------
local function HttpApiGet(command, cb)
  if not gOwnerOK then
    LogWarning("httpapi blocked: Owner Approved = No (power/input over IP disabled)")
    if cb then cb(false) end; return
  end
  local addr = DeviceAddress()
  if not addr then if cb then cb(false) end return end
  if not gClientCertPem then LogError("client cert not loaded; cannot use httpapi"); if cb then cb(false) end return end
  local url = "https://" .. addr .. "/httpapi.asp?command=" .. UrlEncode(command)
  LogDebug("httpapi GET %s", url)
  local ok, req = pcall(function() return C4:url() end)
  if not ok or not req then if cb then cb(false) end return end
  req:OnDone(function(transfer, responses, errCode, errMsg)
    local rbody
    if type(responses) == "table" then
      local r = responses[#responses] or responses
      if type(r) == "table" then rbody = r.body or r.data end
    elseif type(responses) == "string" then rbody = responses end
    local good = (errCode == 0 or errCode == nil) and rbody ~= nil
    if not good then LogWarning("httpapi failed for '%s' (err=%s)", command, tostring(errMsg or errCode)) end
    if cb then cb(good, rbody) end
  end)
  -- Present the bundled Linkplay client cert for the device's mutual-TLS + accept its
  -- self-signed server cert. Option names may need tuning per OS version (isolated here).
  pcall(function() req:SetOptions({
    client_certificate = gClientCertPem,
    client_key         = gClientKeyPem,
    ssl_verify_host    = false,
    ssl_verify_peer    = false,
    timeout            = 8,
    connect_timeout    = 5,
  }) end)
  req:Get(url)
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
-------------------------------------------------
local function LoadCert()
  gClientCertPem, gClientKeyPem = nil, nil
  local pem
  local ok = pcall(function() pem = C4:ReadFile("linkplay_client.pem") end)
  if not ok or not pem or pem == "" then
    LogWarning("linkplay_client.pem not bundled; httpapi power/input unavailable (UPnP still works)")
    return
  end
  gClientCertPem = pem:match("(%-%-%-%-%-BEGIN CERTIFICATE%-%-%-%-%-.-%-%-%-%-%-END CERTIFICATE%-%-%-%-%-)")
  gClientKeyPem  = pem:match("(%-%-%-%-%-BEGIN [%u ]*PRIVATE KEY%-%-%-%-%-.-%-%-%-%-%-END [%u ]*PRIVATE KEY%-%-%-%-%-)")
  if gClientCertPem and gClientKeyPem then LogInfo("Linkplay client cert loaded")
  else LogWarning("client cert/key parse failed") end
end

-------------------------------------------------
-- ACTIONS / COMMANDS
-------------------------------------------------
function ExecuteCommand(strCommand, tParams)
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
  else LogTrace("Unhandled command: %s", tostring(strCommand)) end
end

-------------------------------------------------
-- CONTROL4 LIFECYCLE
-------------------------------------------------
function OnDriverInit()  LogInfo("OnDriverInit") end

function OnDriverLateInit()
  LogInfo("OnDriverLateInit")
  UpdateProp("Driver Version", "2.0.0")
  for k, _ in pairs(Properties or {}) do OnPropertyChanged(k) end
  LoadCert()
  StartPoll()
end

function OnDriverDestroyed() LogInfo("OnDriverDestroyed"); StopPoll() end

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
    gAddress = trim(value)
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
  if nBinding == NETWORK_BINDING and sStatus == "ONLINE" then SetConnected(true) end
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
