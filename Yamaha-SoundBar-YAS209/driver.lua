--[[
  Yamaha YAS-209 Sound Bar - Control4 DriverWorks driver
  Protocol : Yamaha Extended Control (YXC) v1 over HTTP (port 80)
  Proxy    : receiver (binding 5001)

  See research/DESIGN.md for the full protocol map and Control4 mapping.

  Bindings:
    5001        = receiver proxy
    6001        = network connection (IP + online monitoring, port 80)
    7000        = audio/video output end-point (to room)
    3000..3004  = input source connections (InputBindingID carried by SET_INPUT)
    6002        = runtime UDP listener for optional push events
]]

-------------------------------------------------
-- CONSTANTS
-------------------------------------------------
local RECEIVER_BINDING = 5001
local NETWORK_BINDING  = 6001
local OUTPUT_BINDING   = 7000
local EVENT_BINDING    = 6002

-- Control4 input connection id -> YXC input id.
-- Authoritative IDs come from system/getFeatures (Actions -> Query Features);
-- this table is the single place to adjust if a unit reports different IDs.
local INPUT_MAP = {
  [3000] = "tv",
  [3001] = "hdmi1",
  [3002] = "optical",
  [3003] = "bluetooth",
  [3004] = "server",
}
-- Order used by PULSE_INPUT cycling
local INPUT_ORDER = { 3000, 3001, 3002, 3003, 3004 }
-- Reverse map: YXC input id -> connection id (built at load)
local YXC_TO_CONN = {}
for connId, yxc in pairs(INPUT_MAP) do YXC_TO_CONN[yxc] = connId end

local LOG_LEVEL = { ALERT = 0, ERROR = 1, WARNING = 2, INFO = 3, TRACE = 4, DEBUG = 5 }

-------------------------------------------------
-- STATE
-------------------------------------------------
local gLogLevel  = LOG_LEVEL.WARNING
local gLogMode   = "Off"
local gAddress   = ""       -- resolved device IP
local gPollSecs  = 3
local gUsePush   = false
local gEventPort = 41100
local gRampStep  = 2
local gVolMax    = 100      -- YXC absolute max volume (from getFeatures)

local gConnected = false
local gPollFails = 0
local gPollTimer = nil
local gRampTimer = nil

-- last-known device state (for change detection / notifications)
local gPower     = nil      -- boolean
local gYxcVolume = nil      -- integer (device units)
local gC4Volume  = nil      -- 0..100
local gMute      = nil      -- boolean
local gInputYxc  = nil      -- string

-------------------------------------------------
-- LOGGING
-------------------------------------------------
local function Log(level, msg, ...)
  if gLogMode == "Off" then return end
  if level > gLogLevel then return end
  local ok, formatted = pcall(string.format, msg, ...)
  if not ok then formatted = tostring(msg) end
  local line = string.format("[YAS209][%s] %s", os.date("%H:%M:%S"), formatted)
  if gLogMode == "Print" or gLogMode == "Print and Log" then print(line) end
  if gLogMode == "Log"   or gLogMode == "Print and Log" then C4:Log(line) end
end
local function LogDebug(m, ...)   Log(LOG_LEVEL.DEBUG,   m, ...) end
local function LogTrace(m, ...)   Log(LOG_LEVEL.TRACE,   m, ...) end
local function LogInfo(m, ...)    Log(LOG_LEVEL.INFO,    m, ...) end
local function LogWarning(m, ...) Log(LOG_LEVEL.WARNING, m, ...) end
local function LogError(m, ...)   Log(LOG_LEVEL.ERROR,   m, ...) end

-------------------------------------------------
-- SMALL HELPERS
-------------------------------------------------
local function trim(s) return (tostring(s or "")):gsub("^%s*(.-)%s*$", "%1") end

local function UpdateProp(name, value)
  pcall(function() C4:UpdateProperty(name, tostring(value)) end)
end

-- Flat-JSON field extractors (YXC responses are flat; no JSON lib needed).
local function jstr(blob, key)  return blob and blob:match('"' .. key .. '"%s*:%s*"([^"]*)"') end
local function jint(blob, key)  local v = blob and blob:match('"' .. key .. '"%s*:%s*(%-?%d+)'); return v and tonumber(v) end
local function jbool(blob, key) return blob ~= nil and (blob:match('"' .. key .. '"%s*:%s*(%a+)') == "true") end
local function jobj(blob, key)  return blob and blob:match('"' .. key .. '"%s*:%s*(%b{})') end

-- Volume scaling between Control4 (0..100) and YXC (0..gVolMax)
local function ToC4(yxc)
  if not yxc then return nil end
  local m = (gVolMax and gVolMax > 0) and gVolMax or 100
  local lvl = math.floor((yxc / m) * 100 + 0.5)
  if lvl < 0 then lvl = 0 elseif lvl > 100 then lvl = 100 end
  return lvl
end
local function ToYxc(level)
  local m = (gVolMax and gVolMax > 0) and gVolMax or 100
  local v = math.floor((level / 100) * m + 0.5)
  if v < 0 then v = 0 elseif v > m then v = m end
  return v
end

local function DeviceAddress()
  if gAddress and gAddress ~= "" then return gAddress end
  return nil
end

local function SetConnected(c)
  if gConnected == c then return end
  gConnected = c
  UpdateProp("Connected", tostring(c))
  LogInfo("Connected = %s", tostring(c))
end

-------------------------------------------------
-- PROXY NOTIFICATIONS (report state to the receiver proxy / UI)
-------------------------------------------------
local function NotifyPower(on)
  C4:SendToProxy(RECEIVER_BINDING, on and "ON" or "OFF", {}, "NOTIFY")
end
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
-- HTTP (YXC) LAYER
-- Isolated so the exact C4:url() signature/header method can be tuned in one
-- place if a firmware / OS version differs (see DESIGN.md open items).
-------------------------------------------------
local function OnHttpResult(path, cb, transportErr, body, httpCode)
  local ok = (transportErr == 0 or transportErr == nil) and body ~= nil and body ~= ""
  if ok and httpCode ~= nil and httpCode ~= 200 then ok = false end
  if not ok then
    LogTrace("HTTP fail for %s (err=%s code=%s)", path, tostring(transportErr), tostring(httpCode))
  end
  if cb then cb(ok, body) end
end

local function YxcGet(path, cb)
  local addr = DeviceAddress()
  if not addr then
    LogWarning("No IP Address set; cannot send '%s'. Set the IP Address property.", path)
    if cb then cb(false, nil) end
    return
  end
  local url = "http://" .. addr .. "/YamahaExtendedControl/v1/" .. path
  LogDebug("GET %s", url)

  local headers = {}
  if gUsePush then
    headers["X-AppName"] = "MusicCast/1.0(Control4)"
    headers["X-AppPort"] = tostring(gEventPort)
  end

  local ok, req = pcall(function() return C4:url() end)
  if not ok or not req then
    LogError("C4:url() unavailable: %s", tostring(req))
    if cb then cb(false, nil) end
    return
  end

  req:OnDone(function(transfer, responses, errCode, errMsg)
    local body, code
    if type(responses) == "table" then
      local r = responses[#responses] or responses
      if type(r) == "table" then body = r.body or r.data; code = r.code end
    elseif type(responses) == "string" then
      -- alternate signature (ticketId, strData, code, headers)
      body = responses
    end
    OnHttpResult(path, cb, errCode, body, code)
  end)
  pcall(function() req:SetOptions({ headers = headers, timeout = 8, connect_timeout = 5 }) end)
  req:Get(url)
end

-------------------------------------------------
-- APPLY DEVICE STATE (from getStatus body OR an event's "main" object)
-------------------------------------------------
local function ApplyMain(blob)
  if not blob then return end

  local p = jstr(blob, "power")
  if p ~= nil then
    local on = (p == "on")
    if on ~= gPower then
      gPower = on
      UpdateProp("Power State", on and "On" or "Standby")
      NotifyPower(on)
    end
  end

  local v = jint(blob, "volume")
  if v ~= nil and v ~= gYxcVolume then
    gYxcVolume = v
    local lvl = ToC4(v)
    gC4Volume = lvl
    UpdateProp("Current Volume", string.format("%d%% (yxc %d)", lvl, v))
    NotifyVolume(lvl)
  end

  local mv = blob:match('"mute"%s*:%s*(%a+)')
  if mv ~= nil then
    local m = (mv == "true")
    if m ~= gMute then
      gMute = m
      UpdateProp("Muted", tostring(m))
      NotifyMute(m)
    end
  end

  local inp = jstr(blob, "input")
  if inp ~= nil and inp ~= "" and inp ~= gInputYxc then
    gInputYxc = inp
    UpdateProp("Current Input", inp)
    local connId = YXC_TO_CONN[inp]
    if connId then NotifyInput(connId) end
  end
end

local function ApplyStatusBody(ok, body)
  if not ok or not body then
    gPollFails = gPollFails + 1
    if gPollFails >= 3 then SetConnected(false) end
    return
  end
  local rc = jint(body, "response_code")
  if rc ~= nil and rc ~= 0 then LogWarning("getStatus response_code=%d", rc) end
  gPollFails = 0
  SetConnected(true)
  ApplyMain(body)   -- for main/getStatus the fields are at the JSON root
end

local function Poll()
  YxcGet("main/getStatus", ApplyStatusBody)
end

local function StopPoll() if gPollTimer then gPollTimer:Cancel(); gPollTimer = nil end end
local function StartPoll()
  StopPoll()
  Poll()
  gPollTimer = C4:SetTimer(gPollSecs * 1000, function(timer)
    Poll()
    if timer and timer.Reset then timer:Reset() end
  end, false)
end

-------------------------------------------------
-- SETTERS (optimistic UI update, then reconcile on next poll)
-------------------------------------------------
local function SetPower(on)
  gPower = on
  UpdateProp("Power State", on and "On" or "Standby")
  NotifyPower(on)
  YxcGet("main/setPower?power=" .. (on and "on" or "standby"))
end

local function SetVolumeLevel(level)
  if not level then return end
  if level < 0 then level = 0 elseif level > 100 then level = 100 end
  local yxc = ToYxc(level)
  gC4Volume, gYxcVolume = level, yxc
  UpdateProp("Current Volume", string.format("%d%% (yxc %d)", level, yxc))
  NotifyVolume(level)
  YxcGet("main/setVolume?volume=" .. yxc)
end

local function VolStep(dir)   -- dir = "up" | "down"
  YxcGet("main/setVolume?volume=" .. dir .. "&step=" .. gRampStep)
end

local function SetMute(m)
  gMute = m
  UpdateProp("Muted", tostring(m))
  NotifyMute(m)
  YxcGet("main/setMute?enable=" .. (m and "true" or "false"))
end

local function SelectInputByConn(connId)
  local yxc = INPUT_MAP[connId]
  if not yxc then LogWarning("Unknown input connection id %s", tostring(connId)); return end
  gInputYxc = yxc
  UpdateProp("Current Input", yxc)
  NotifyInput(connId)
  YxcGet("main/setInput?input=" .. yxc)
end

local function CycleInput()
  local curConn = gInputYxc and YXC_TO_CONN[gInputYxc] or nil
  local idx = 1
  for i, id in ipairs(INPUT_ORDER) do if id == curConn then idx = i; break end end
  SelectInputByConn(INPUT_ORDER[(idx % #INPUT_ORDER) + 1])
end

local function StopRamp() if gRampTimer then gRampTimer:Cancel(); gRampTimer = nil end end
local function StartRamp(dir)
  StopRamp()
  VolStep(dir)
  gRampTimer = C4:SetTimer(250, function(timer)
    VolStep(dir)
    if timer and timer.Reset then timer:Reset() end
  end, false)
end

-- Pull the input connection id out of a proxy command's params (defensive:
-- the exact key name for SET_INPUT can vary, so also fall back to any value
-- that matches a known input connection id).
local function ConnIdFromParams(tParams)
  if type(tParams) ~= "table" then return nil end
  local keys = { "InputBindingID", "INPUT", "idBinding", "BindingID",
                 "IDBINDING", "Input Binding ID", "INPUTBINDINGID" }
  for _, k in ipairs(keys) do
    local v = tonumber(tParams[k]); if v and INPUT_MAP[v] then return v end
  end
  for _, v in pairs(tParams) do
    local n = tonumber(v); if n and INPUT_MAP[n] then return n end
  end
  return nil
end

-------------------------------------------------
-- RECEIVER PROXY COMMANDS (binding 5001)
-------------------------------------------------
local ReceiverCommands = {}
function ReceiverCommands.ON()  SetPower(true)  end
function ReceiverCommands.OFF() SetPower(false) end
function ReceiverCommands.SET_VOLUME_LEVEL(p) SetVolumeLevel(tonumber(p and p.LEVEL)) end
function ReceiverCommands.PULSE_VOL_UP()   VolStep("up")   end
function ReceiverCommands.PULSE_VOL_DOWN() VolStep("down") end
function ReceiverCommands.START_VOL_UP()   StartRamp("up")   end
function ReceiverCommands.START_VOL_DOWN() StartRamp("down") end
function ReceiverCommands.STOP_VOL_UP()    StopRamp() end
function ReceiverCommands.STOP_VOL_DOWN()  StopRamp() end
function ReceiverCommands.MUTE_ON()     SetMute(true)  end
function ReceiverCommands.MUTE_OFF()    SetMute(false) end
function ReceiverCommands.MUTE_TOGGLE() SetMute(not gMute) end
function ReceiverCommands.SET_INPUT(p)  local id = ConnIdFromParams(p); if id then SelectInputByConn(id) end end
function ReceiverCommands.PULSE_INPUT() CycleInput() end

-------------------------------------------------
-- DEVICE INFO / FEATURES (discovery + logging)
-------------------------------------------------
local function QueryDeviceInfo()
  YxcGet("system/getDeviceInfo", function(ok, body)
    if not ok or not body then return end
    local model = jstr(body, "model_name")
    local devid = jstr(body, "device_id")
    local ver   = jstr(body, "system_version")
    local api   = jstr(body, "api_version")
    if model then UpdateProp("Model", model) end
    if devid then UpdateProp("Device ID", devid) end
    if ver then
      UpdateProp("Firmware Version", tostring(ver) .. (api and (" (api " .. tostring(api) .. ")") or ""))
    end
    LogInfo("Device: model=%s id=%s fw=%s api=%s",
      tostring(model), tostring(devid), tostring(ver), tostring(api))
  end)
end

local function QueryFeatures()
  YxcGet("system/getFeatures", function(ok, body)
    if not ok or not body then return end
    -- Absolute volume max: range_step entry with id "volume"
    local vmax = body:match('"id"%s*:%s*"volume".-"max"%s*:%s*(%d+)')
    if vmax then gVolMax = tonumber(vmax); LogInfo("Volume max (YXC) = %d", gVolMax) end
    -- Device-reported input ids
    local inputs = {}
    for list in body:gmatch('"input_list"%s*:%s*%[(.-)%]') do
      for id in list:gmatch('"id"%s*:%s*"([^"]*)"') do inputs[#inputs + 1] = id end
    end
    if #inputs > 0 then LogInfo("Inputs reported by device: %s", table.concat(inputs, ", ")) end
    -- Device-reported sound programs
    local progs = {}
    for list in body:gmatch('"sound_program_list"%s*:%s*%[(.-)%]') do
      for p in list:gmatch('"([^"]*)"') do progs[#progs + 1] = p end
    end
    if #progs > 0 then LogInfo("Sound programs: %s", table.concat(progs, ", ")) end
  end)
end

-------------------------------------------------
-- OPTIONAL PUSH EVENTS (UDP) - experimental; gated by Use Push Events
-------------------------------------------------
local function StopEventListener()
  pcall(function() C4:DestroyNetworkConnection(EVENT_BINDING) end)
end
local function StartEventListener()
  if not gUsePush then return end
  local ok, err = pcall(function()
    C4:CreateNetworkConnection(EVENT_BINDING, "0.0.0.0", gEventPort, true, "UDP")
  end)
  if not ok then LogWarning("Could not start UDP event listener: %s", tostring(err)) end
end

-------------------------------------------------
-- ACTIONS / COMMANDS (Composer Actions tab + programming commands)
-------------------------------------------------
function ExecuteCommand(strCommand, tParams)
  LogTrace("ExecuteCommand: %s", tostring(strCommand))
  if     strCommand == "RefreshNow"       then Poll()
  elseif strCommand == "QueryDeviceInfo"  then QueryDeviceInfo()
  elseif strCommand == "QueryFeatures"    then QueryFeatures()
  elseif strCommand == "BassExtensionOn"  then YxcGet("main/setBassExtension?enable=true")
  elseif strCommand == "BassExtensionOff" then YxcGet("main/setBassExtension?enable=false")
  elseif strCommand == "ClearVoiceOn"     then YxcGet("main/setClearVoice?enable=true")
  elseif strCommand == "ClearVoiceOff"    then YxcGet("main/setClearVoice?enable=false")
  elseif strCommand == "Surround3DOn"     then YxcGet("main/set3dSurround?enable=true")
  elseif strCommand == "Surround3DOff"    then YxcGet("main/set3dSurround?enable=false")
  elseif strCommand == "TransportPlay"     then YxcGet("netusb/setPlayback?playback=play")
  elseif strCommand == "TransportPause"    then YxcGet("netusb/setPlayback?playback=pause")
  elseif strCommand == "TransportStop"     then YxcGet("netusb/setPlayback?playback=stop")
  elseif strCommand == "TransportNext"     then YxcGet("netusb/setPlayback?playback=next")
  elseif strCommand == "TransportPrevious" then YxcGet("netusb/setPlayback?playback=previous")
  elseif strCommand == "SetSleep" then
    local mins = tParams and (tParams.Minutes or tParams.MINUTES) or "0"
    YxcGet("main/setSleep?sleep=" .. tostring(mins))
  elseif strCommand == "SetSubwooferVolume" then
    local lvl = tParams and (tParams.Level or tParams.LEVEL) or "0"
    YxcGet("main/setSubwooferVolume?volume=" .. tostring(lvl))
  else
    LogTrace("Unhandled command: %s", tostring(strCommand))
  end
end

-------------------------------------------------
-- CONTROL4 DRIVER LIFECYCLE CALLBACKS
-------------------------------------------------
function OnDriverInit()
  LogInfo("OnDriverInit")
end

function OnDriverLateInit()
  LogInfo("OnDriverLateInit")
  UpdateProp("Driver Version", "1.0.0")
  for k, _ in pairs(Properties or {}) do OnPropertyChanged(k) end
  QueryDeviceInfo()
  QueryFeatures()
  StartPoll()
  StartEventListener()
end

function OnDriverDestroyed()
  LogInfo("OnDriverDestroyed")
  StopPoll()
  StopRamp()
  StopEventListener()
end

function OnPropertyChanged(sProperty)
  local value = Properties and Properties[sProperty]
  LogTrace("OnPropertyChanged: %s = %s", tostring(sProperty), tostring(value))

  if sProperty == "Log Level" then
    gLogLevel = tonumber(string.match(value or "", "^(%d+)")) or LOG_LEVEL.WARNING
  elseif sProperty == "Log Mode" then
    gLogMode = value or "Off"
  elseif sProperty == "IP Address" then
    gAddress = trim(value)
    LogInfo("IP Address set to '%s'", gAddress)
    if gAddress ~= "" then Poll() end
  elseif sProperty == "Poll Interval Seconds" then
    gPollSecs = tonumber(value) or 3
    if gPollTimer then StartPoll() end
  elseif sProperty == "Use Push Events" then
    gUsePush = (value == "On")
    StopEventListener()
    StartEventListener()
  elseif sProperty == "Event Listen Port" then
    gEventPort = tonumber(value) or 41100
    if gUsePush then StopEventListener(); StartEventListener() end
  elseif sProperty == "Volume Ramp Step" then
    gRampStep = tonumber(value) or 2
  elseif sProperty == "Sound Program" then
    if value and value ~= "(no change)" and value ~= "" then
      YxcGet("main/setSoundProgram?program=" .. value)
    end
  end
end

-------------------------------------------------
-- NETWORK CALLBACKS
-------------------------------------------------
function OnConnectionStatusChanged(nBinding, nPort, sStatus)
  LogTrace("OnConnectionStatusChanged: binding=%s port=%s status=%s",
    tostring(nBinding), tostring(nPort), tostring(sStatus))
  -- The authoritative Connected state is derived from poll success/failure;
  -- an ONLINE hint from the monitor binding just confirms reachability early.
  if nBinding == NETWORK_BINDING and sStatus == "ONLINE" then
    SetConnected(true)
  end
end

function ReceivedFromNetwork(nBinding, nPort, sData)
  if nBinding == EVENT_BINDING and sData then
    LogDebug("UDP event: %s", sData)
    local main = jobj(sData, "main")
    if main then ApplyMain(main) end
    SetConnected(true)
  end
end

-------------------------------------------------
-- PROXY COMMAND DISPATCH
-------------------------------------------------
function ReceivedFromProxy(idBinding, sCommand, tParams)
  LogTrace("ReceivedFromProxy: binding=%s cmd=%s", tostring(idBinding), tostring(sCommand))
  if idBinding == RECEIVER_BINDING then
    local h = ReceiverCommands[sCommand]
    if h then h(tParams) else LogWarning("Unhandled receiver command: %s", tostring(sCommand)) end
  else
    LogWarning("ReceivedFromProxy: unknown binding %s cmd %s", tostring(idBinding), tostring(sCommand))
  end
end

LogInfo("driver.lua loaded (Yamaha YAS-209 YXC)")
