--[[
  NVIDIA SHIELD TV Driver (DMW Dev Build)
  Based on original NVIDIA driver v105
  Protocol: Proprietary SSL/TCP on port 8988

  Proxy bindings:
    5001 = media_player  (SHIELD TV)
    5002 = avswitch      (SHIELD App Switcher)
  Network binding:
    6001 = SSL connection to SHIELD on port 8988
]]

-------------------------------------------------
-- CONSTANTS
-------------------------------------------------
local NETWORK_BINDING_ID = 6001
local MEDIA_PLAYER_BINDING_ID = 5001
local AVSWITCH_BINDING_ID = 5002

local LOG_LEVEL = {
  ALERT   = 0,
  ERROR   = 1,
  WARNING = 2,
  INFO    = 3,
  TRACE   = 4,
  DEBUG   = 5,
}

-------------------------------------------------
-- STATE
-------------------------------------------------
local gLogLevel     = LOG_LEVEL.WARNING
local gLogMode      = "Off"   -- Off | Print | Log | Print and Log
local gConnected    = false
local gCmdDelayMs   = 150
local gKeepAliveInterval = 30
local gVolRampDelayMs    = 150
local gMenuButton   = "Home"
local gCancelButton = "Back"
local gInfoButton   = "Settings"
local gKeepAliveTimer = nil
local gReceiveBuffer  = ""

-------------------------------------------------
-- LOGGING
-------------------------------------------------
local function Log(level, msg, ...)
  if gLogMode == "Off" then return end
  if level > gLogLevel then return end

  local formatted = string.format(msg, ...)
  local prefix = string.format("[SHIELD-DMW][%s] ", os.date("%H:%M:%S"))
  local line = prefix .. formatted

  if gLogMode == "Print" or gLogMode == "Print and Log" then
    print(line)
  end
  if gLogMode == "Log" or gLogMode == "Print and Log" then
    C4:Log(line)
  end
end

local function LogDebug(msg, ...)   Log(LOG_LEVEL.DEBUG,   msg, ...) end
local function LogTrace(msg, ...)   Log(LOG_LEVEL.TRACE,   msg, ...) end
local function LogInfo(msg, ...)    Log(LOG_LEVEL.INFO,    msg, ...) end
local function LogWarning(msg, ...) Log(LOG_LEVEL.WARNING, msg, ...) end
local function LogError(msg, ...)   Log(LOG_LEVEL.ERROR,   msg, ...) end

-------------------------------------------------
-- NETWORK HELPERS
-------------------------------------------------
local function SendToShield(data)
  if not gConnected then
    LogWarning("SendToShield: not connected, dropping data")
    return
  end
  LogDebug("TX: %s", C4:LToH(data or ""))
  C4:SendToNetwork(NETWORK_BINDING_ID, 1, data)
end

-- TODO: Build the actual command bytes/protobuf for the SHIELD protocol.
-- Replace these placeholder functions with real message construction.
local function BuildCommand(cmdName, params)
  LogTrace("BuildCommand: %s", cmdName)
  -- Placeholder — return nil until protocol is known
  return nil
end

local function SendCommand(cmdName, params)
  local data = BuildCommand(cmdName, params)
  if data then
    SendToShield(data)
  else
    LogTrace("SendCommand: no data built for '%s' (not yet implemented)", cmdName)
  end
end

-------------------------------------------------
-- KEEP-ALIVE
-------------------------------------------------
local function StopKeepAlive()
  if gKeepAliveTimer then
    gKeepAliveTimer:Cancel()
    gKeepAliveTimer = nil
  end
end

local function StartKeepAlive()
  StopKeepAlive()
  gKeepAliveTimer = C4:SetTimer(gKeepAliveInterval * 1000, function(timer)
    if gConnected then
      LogTrace("Keep-alive tick")
      SendCommand("KEEP_ALIVE")
    end
    timer:Reset()
  end, false)
end

-------------------------------------------------
-- CONNECTION STATE
-------------------------------------------------
local function SetConnected(connected)
  if gConnected == connected then return end
  gConnected = connected
  C4:SetPropertyAttribs("Connected To Network", 0)
  C4:UpdateProperty("Connected To Network", tostring(connected))
  LogInfo("Connection state: %s", tostring(connected))

  if connected then
    StartKeepAlive()
  else
    StopKeepAlive()
  end
end

-------------------------------------------------
-- RECEIVED DATA
-------------------------------------------------
-- TODO: Implement protocol parsing here once message format is known.
local function ParseAndDispatch(data)
  LogDebug("RX raw (%d bytes): %s", #data, C4:LToH(data))
  -- Placeholder: accumulate in buffer; parse when you know the framing
  gReceiveBuffer = gReceiveBuffer .. data
end

-------------------------------------------------
-- MEDIA PLAYER PROXY COMMANDS (binding 5001)
-------------------------------------------------
local MediaPlayerCommands = {}

function MediaPlayerCommands.PLAY()           SendCommand("PLAY") end
function MediaPlayerCommands.PAUSE()          SendCommand("PAUSE") end
function MediaPlayerCommands.STOP()           SendCommand("STOP") end
function MediaPlayerCommands.SKIP_FWD()       SendCommand("SKIP_FWD") end
function MediaPlayerCommands.SKIP_REV()       SendCommand("SKIP_REV") end
function MediaPlayerCommands.SCAN_FWD()       SendCommand("SCAN_FWD") end
function MediaPlayerCommands.SCAN_REV()       SendCommand("SCAN_REV") end
function MediaPlayerCommands.VOLUME_UP()      SendCommand("VOLUME_UP") end
function MediaPlayerCommands.VOLUME_DOWN()    SendCommand("VOLUME_DOWN") end
function MediaPlayerCommands.MUTE_ON()        SendCommand("MUTE_ON") end
function MediaPlayerCommands.MUTE_OFF()       SendCommand("MUTE_OFF") end
function MediaPlayerCommands.MUTE_TOGGLE()    SendCommand("MUTE_TOGGLE") end
function MediaPlayerCommands.NUMBER_0()       SendCommand("NUMBER_0") end
function MediaPlayerCommands.NUMBER_1()       SendCommand("NUMBER_1") end
function MediaPlayerCommands.NUMBER_2()       SendCommand("NUMBER_2") end
function MediaPlayerCommands.NUMBER_3()       SendCommand("NUMBER_3") end
function MediaPlayerCommands.NUMBER_4()       SendCommand("NUMBER_4") end
function MediaPlayerCommands.NUMBER_5()       SendCommand("NUMBER_5") end
function MediaPlayerCommands.NUMBER_6()       SendCommand("NUMBER_6") end
function MediaPlayerCommands.NUMBER_7()       SendCommand("NUMBER_7") end
function MediaPlayerCommands.NUMBER_8()       SendCommand("NUMBER_8") end
function MediaPlayerCommands.NUMBER_9()       SendCommand("NUMBER_9") end
function MediaPlayerCommands.UP()             SendCommand("UP") end
function MediaPlayerCommands.DOWN()           SendCommand("DOWN") end
function MediaPlayerCommands.LEFT()           SendCommand("LEFT") end
function MediaPlayerCommands.RIGHT()          SendCommand("RIGHT") end
function MediaPlayerCommands.ENTER()          SendCommand("ENTER") end
function MediaPlayerCommands.HOME()           SendCommand("HOME") end
function MediaPlayerCommands.BACK()           SendCommand("BACK") end
function MediaPlayerCommands.SETTINGS()       SendCommand("SETTINGS") end
function MediaPlayerCommands.SEARCH()         SendCommand("SEARCH") end
function MediaPlayerCommands.POWER_ON()       SendCommand("POWER_ON") end
function MediaPlayerCommands.POWER_OFF()      SendCommand("POWER_OFF") end
function MediaPlayerCommands.POWER_TOGGLE()   SendCommand("POWER_TOGGLE") end

function MediaPlayerCommands.MENU()
  SendCommand(gMenuButton:upper())
end

function MediaPlayerCommands.CANCEL()
  SendCommand(gCancelButton:upper())
end

function MediaPlayerCommands.INFO()
  SendCommand(gInfoButton:upper())
end

function MediaPlayerCommands.SELECT_INPUT(tParams)
  local input = tParams and tParams["INPUT"] or ""
  SendCommand("SELECT_INPUT", { input = input })
end

-------------------------------------------------
-- AVSWITCH PROXY COMMANDS (binding 5002)
-------------------------------------------------
local AVSwitchCommands = {}

function AVSwitchCommands.SELECT_INPUT(tParams)
  local input = tParams and tParams["INPUT"] or ""
  LogInfo("App switch to input: %s", tostring(input))
  SendCommand("APP_SELECT", { input = input })
end

-------------------------------------------------
-- C4 DRIVER CALLBACKS
-------------------------------------------------
function OnDriverInit()
  LogInfo("OnDriverInit called")
end

function OnDriverLateInit()
  LogInfo("OnDriverLateInit called")
  -- Apply all current property values
  for k, v in pairs(Properties) do
    OnPropertyChanged(k)
  end
end

function OnDriverDestroyed()
  LogInfo("OnDriverDestroyed called")
  StopKeepAlive()
end

function OnPropertyChanged(sProperty)
  local value = Properties[sProperty]
  LogTrace("OnPropertyChanged: %s = %s", tostring(sProperty), tostring(value))

  if sProperty == "Log Level" then
    local level = tonumber(string.match(value, "^(%d+)")) or LOG_LEVEL.WARNING
    gLogLevel = level
    LogInfo("Log level set to %d", gLogLevel)

  elseif sProperty == "Log Mode" then
    gLogMode = value
    LogInfo("Log mode set to %s", gLogMode)

  elseif sProperty == "Command Delay Milliseconds" then
    gCmdDelayMs = tonumber(value) or 150
    LogInfo("Command delay set to %dms", gCmdDelayMs)

  elseif sProperty == "Network Keep Alive Interval Seconds" then
    gKeepAliveInterval = tonumber(value) or 30
    if gConnected then StartKeepAlive() end
    LogInfo("Keep-alive interval set to %ds", gKeepAliveInterval)

  elseif sProperty == "Volume Ramp Delay Milliseconds" then
    gVolRampDelayMs = tonumber(value) or 150
    LogInfo("Volume ramp delay set to %dms", gVolRampDelayMs)

  elseif sProperty == "MENU Button" then
    gMenuButton = value
  elseif sProperty == "CANCEL Button" then
    gCancelButton = value
  elseif sProperty == "INFO Button" then
    gInfoButton = value
  end
end

-------------------------------------------------
-- NETWORK CALLBACKS
-------------------------------------------------
function OnConnectionStatusChanged(nBinding, nPort, sStatus)
  LogInfo("OnConnectionStatusChanged: binding=%d port=%d status=%s", nBinding, nPort, sStatus)
  if nBinding == NETWORK_BINDING_ID then
    if sStatus == "ONLINE" then
      SetConnected(true)
    else
      SetConnected(false)
      gReceiveBuffer = ""
    end
  end
end

function ReceivedFromNetwork(nBinding, nPort, sData)
  if nBinding == NETWORK_BINDING_ID then
    ParseAndDispatch(sData)
  end
end

-------------------------------------------------
-- PROXY COMMAND DISPATCH
-------------------------------------------------
function ReceivedFromProxy(idBinding, sCommand, tParams)
  LogTrace("ReceivedFromProxy: binding=%d cmd=%s", idBinding, sCommand)

  if idBinding == MEDIA_PLAYER_BINDING_ID then
    local handler = MediaPlayerCommands[sCommand]
    if handler then
      handler(tParams)
    else
      LogWarning("Unhandled media_player command: %s", sCommand)
    end

  elseif idBinding == AVSWITCH_BINDING_ID then
    local handler = AVSwitchCommands[sCommand]
    if handler then
      handler(tParams)
    else
      LogWarning("Unhandled avswitch command: %s", sCommand)
    end

  else
    LogWarning("ReceivedFromProxy: unknown binding %d, command %s", idBinding, sCommand)
  end
end

LogInfo("driver.lua loaded (DMW dev build)")
