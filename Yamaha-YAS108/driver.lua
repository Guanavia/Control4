--[[
    Yamaha YAS-108 soundbar - Control4 DriverWorks driver.

    IR ONLY, and that is a hardware fact rather than a limitation of this driver: the YAS-108 has
    no network interface of any kind. There is no wifi, no ethernet, no local API and therefore no
    feedback path. Everything below follows from that single constraint:

      * The driver can only ever know what it last SENT. Nothing confirms it.
      * Power and mute have TOGGLE-ONLY codes on the remote (the discrete on/off codes in the
        capture came back empty), so discrete commands are synthesised from an assumed state.
      * <capabilities> deliberately does NOT declare discrete volume or discrete mute, because
        nothing could ever correct an estimate. See driver.xml.

    All IR codes were captured from the genuine YAS-108 remote, renumbered into this driver's own
    id range - the capture's ids collide semantically with the YAS-209 driver's.

    Lessons carried over from the YAS-209 driver, all of which cost a hardware session there:
      * C4:Log does not exist; C4:ErrorLog does.
      * Composer Actions arrive via ExecuteCommand as strCommand="LUA_ACTION" with the real name
        in tParams.ACTION.
      * The IR connection must be id 2 with class IR_OUT in a lua_gen driver.
      * Never resolve a toggle against cached state where a device-side toggle exists.
      * Never surface a protocol token in a user-visible property.
      * Diagnostics that report a misconfiguration must not be silenceable by a log level.
]]

-------------------------------------------------
-- CONSTANTS
-------------------------------------------------
local IR_BINDING       = 2
local RECEIVER_BINDING = 5001
local OUTPUT_BINDING   = 7000

-- Captured from the real remote, renumbered for this driver. MUST match <irsection>.
local IR = {
  POWER_TOGGLE = 101, VOLUME_UP = 106, VOLUME_DOWN = 107, MUTE_TOGGLE = 139, INFO = 120,
  TV_INPUT = 201, HDMI = 202, ANALOG = 203, BLUETOOTH = 204,
  SURROUND = 301, STEREO = 302,
  SURROUND_3D = 401, CLEAR_VOICE = 402, BASS_EXTENSION = 403,
  BLUETOOTH_STANDBY = 404, DIMMER = 405,
  BASS_UP = 143, BASS_DOWN = 144,
}

-- Control4 input connection id -> IR code and display name. Every input on this bar has its own
-- discrete key, so input select is exact rather than a cycle.
local INPUT_IR   = { [3000] = IR.TV_INPUT, [3001] = IR.HDMI, [3002] = IR.ANALOG, [3003] = IR.BLUETOOTH }
-- MUST match the <connectionname> values in driver.xml. The property shows these, never a code.
local INPUT_NAME = { [3000] = "TV (ARC / Optical)", [3001] = "HDMI In",
                     [3002] = "Analog In (3.5mm)",  [3003] = "Bluetooth" }
local INPUT_ORDER = { 3000, 3001, 3002, 3003 }

-- Surround ids MUST match <surround_modes> in driver.xml.
local SURROUND_IR   = { [1] = IR.SURROUND, [2] = IR.STEREO }
local SURROUND_NAME = { [1] = "Surround",  [2] = "Stereo" }

-- Toggle-only settings: property name -> IR code.
local TOGGLE_PROPS = {
  ["DTS Virtual:X (3D Surround)"] = "SURROUND_3D",
  ["Clear Voice"]                 = "CLEAR_VOICE",
  ["Bass Extension"]              = "BASS_EXTENSION",
  ["Bluetooth Standby"]           = "BLUETOOTH_STANDBY",
}

local SUB_MIN, SUB_MAX = -4, 4
local VOL_STEP_PCT     = 2    -- assumed change per volume pulse
local VOL_MAX_PULSE    = 20   -- never machine-gun the emitter on a large jump

local LOG_LEVEL = { ALERT = 0, ERROR = 1, WARNING = 2, INFO = 3, TRACE = 4, DEBUG = 5 }

-------------------------------------------------
-- STATE  (all of it ASSUMED - nothing here is ever confirmed by the bar)
-------------------------------------------------
local gLogLevel = LOG_LEVEL.WARNING
local gLogMode  = "Off"

-- Assumed OFF at load. A Control4 room starts off and the first thing programming does is turn
-- things on, so this is right in the common case. When it is wrong, the first power command
-- inverts - which is why "Resync" actions exist and why this is stated in the documentation.
local gPower    = false
local gMute     = false
local gVolume   = 20     -- percent, estimated; nothing corrects it
local gInput    = nil    -- connection id
local gSurround = nil    -- surround mode id
local gSub      = 0
local gSettings = {}     -- toggle property -> assumed "On"/"Off"
local gInitDone = false

local gBindings, gBindingClass = {}, {}
local gUnhandledProxyCmds = {}

-------------------------------------------------
-- LOGGING
-------------------------------------------------
local function Log(level, msg, ...)
  if gLogMode == "Off" then return end
  if level > gLogLevel then return end
  local ok, s = pcall(string.format, msg, ...)
  if not ok then s = tostring(msg) end
  local line = string.format("[YAS108][%s] %s", os.date("%H:%M:%S"), s)
  if gLogMode == "Print" or gLogMode == "Print and Log" then print(line) end
  if gLogMode == "Log" or gLogMode == "Print and Log" then
    pcall(function() C4:ErrorLog(line) end)
  end
end

-- Bypasses the Log Mode gate entirely. Log Mode defaults to Off, so anything a dealer MUST see -
-- a misconfiguration, or the output of a diagnostic they deliberately ran - has to go here or it
-- reaches nobody.
local function LogCritical(msg, ...)
  local ok, s = pcall(string.format, msg, ...)
  if not ok then s = tostring(msg) end
  pcall(function() C4:ErrorLog("[YAS108] " .. s) end)
  print("[YAS108][CRITICAL] " .. s)
end

local function LogDebug(m, ...)   Log(LOG_LEVEL.DEBUG, m, ...)   end
local function LogTrace(m, ...)   Log(LOG_LEVEL.TRACE, m, ...)   end
local function LogInfo(m, ...)    Log(LOG_LEVEL.INFO, m, ...)    end
local function LogWarning(m, ...) Log(LOG_LEVEL.WARNING, m, ...) end

-------------------------------------------------
-- HELPERS
-------------------------------------------------
local function UpdateProp(name, value)
  pcall(function() C4:UpdateProperty(name, tostring(value)) end)
end

local function Notify(cmd, params)
  pcall(function() C4:SendToProxy(RECEIVER_BINDING, cmd, params or {}, "NOTIFY") end)
end

-------------------------------------------------
-- IR
-------------------------------------------------
local gIrLoud = false

local function SendIR(code, label)
  if not code then return false end
  local name = tostring(label or "?")
  local ok, err = pcall(function() C4:SendIR(IR_BINDING, code) end)
  if ok then
    LogDebug("IR -> %s (code %d)", name, code)
    if gIrLoud then
      LogCritical("IR fired: %s (code %d) on binding %d. C4:SendIR did not error -- if the " ..
        "emitter did not blink, the problem is the binding, the emitter or the controller's IR " ..
        "port, NOT this code.", name, code, IR_BINDING)
    end
  else
    -- A throw means the API call itself is wrong, i.e. IR cannot work at all. Never silenceable.
    LogCritical("C4:SendIR(%d, %s) THREW: %s -- IR output is not functional.",
      IR_BINDING, tostring(code), tostring(err))
  end
  return ok
end

-- What Director thinks is attached to the IR output, asked at the moment of use. Composer's
-- Connections view shows the project's INTENT; this is the runtime's state, and only the runtime
-- can transmit. On the YAS-209 a dead controller IR port looked identical to a wrong code set
-- until exactly this was added.
local function IrBindingReport()
  local myId = select(2, pcall(function() return C4:GetDeviceID() end))
  LogCritical("IR binding %d diagnostics (this driver's device id: %s):", IR_BINDING, tostring(myId))
  if gBindings[IR_BINDING] == nil then
    LogCritical("  OnBindingChanged: not seen this session (normal -- it only fires on a CHANGE, " ..
      "so a binding already bound at load never reports).")
  else
    LogCritical("  OnBindingChanged: last reported bIsBound = %s (class %s)",
      tostring(gBindings[IR_BINDING]), tostring(gBindingClass[IR_BINDING]))
  end
  local ok, prov = pcall(function() return C4:GetBoundProviderDevice(myId, IR_BINDING) end)
  if ok and prov and prov ~= 0 then
    LogCritical("  GetBoundProviderDevice -> %s   (BOUND: device %s is the IR output feeding us)",
      tostring(prov), tostring(prov))
  else
    LogCritical("  GetBoundProviderDevice -> %s   <-- NOTHING IS DRIVING THIS BINDING",
      ok and tostring(prov) or "unavailable")
  end
end

local function IrFireOne(codeName)
  local code = IR[codeName]
  if not code then LogCritical("IR test: no such code %s", tostring(codeName)); return end
  LogCritical("---- IR emitter test: %s (code %d) on binding %d ----", codeName, code, IR_BINDING)
  IrBindingReport()
  LogCritical("Watch the emitter LED.")
  gIrLoud = true
  SendIR(code, codeName)
  gIrLoud = false
end

-------------------------------------------------
-- CONTROL
-------------------------------------------------
local function ApplyPower(on)
  gPower = on
  UpdateProp("Assumed Power", on and "On" or "Standby")
  Notify(on and "ON" or "OFF")
end

-- The remote has POWER_TOGGLE only. A discrete request is therefore synthesised: send the toggle
-- only when the assumed state differs from what was asked. This is the best available on a
-- one-way bus, and it drifts whenever the bar is changed by its own remote - which is what the
-- Resync actions are for.
local function SetPower(on)
  if gPower == on then
    LogInfo("power already assumed %s -- no IR sent (toggle-only remote)", on and "On" or "Standby")
    Notify(on and "ON" or "OFF")
    return
  end
  SendIR(IR.POWER_TOGGLE, "POWER_TOGGLE")
  ApplyPower(on)
end

local function SetMuteToggle()
  -- The device-side toggle is state-independent: the BAR decides what to flip, so this is correct
  -- even with no readback. Resolving a toggle against a cached belief instead is what made the
  -- YAS-209's mute need two presses.
  SendIR(IR.MUTE_TOGGLE, "MUTE_TOGGLE")
  gMute = not gMute
  UpdateProp("Assumed Mute", tostring(gMute))
  Notify("MUTE_CHANGED", { STATE = gMute and "1" or "0" })
end

local function VolStep(dir)
  SendIR(dir == "up" and IR.VOLUME_UP or IR.VOLUME_DOWN, "VOLUME_" .. string.upper(dir))
  local v = gVolume + (dir == "up" and VOL_STEP_PCT or -VOL_STEP_PCT)
  if v < 0 then v = 0 elseif v > 100 then v = 100 end
  gVolume = v
  UpdateProp("Assumed Volume", tostring(v))
  Notify("VOLUME_LEVEL_CHANGED", { LEVEL = tostring(v), OUTPUT = tostring(OUTPUT_BINDING) })
end

local function SelectInput(connId)
  local code = INPUT_IR[connId]
  if not code then
    LogCritical("no IR code for input connection %s -- not sent.", tostring(connId))
    return
  end
  SendIR(code, "INPUT " .. (INPUT_NAME[connId] or tostring(connId)))
  gInput = connId
  UpdateProp("Assumed Input", INPUT_NAME[connId] or tostring(connId))
  Notify("INPUT_OUTPUT_CHANGED", { INPUT = tostring(connId), OUTPUT = tostring(OUTPUT_BINDING) })
end

local function CycleInput()
  local idx = 1
  for i, id in ipairs(INPUT_ORDER) do if id == gInput then idx = i; break end end
  SelectInput(INPUT_ORDER[(idx % #INPUT_ORDER) + 1])
end

local function SetSurround(id)
  local code = SURROUND_IR[id]
  if not code then
    LogWarning("SET_SURROUND_MODE: unrecognised mode %s", tostring(id))
    return
  end
  SendIR(code, SURROUND_NAME[id])
  gSurround = id
  Notify("SURROUND_MODE_CHANGED", { SURROUND_MODE = tostring(id) })
  Notify("SURROUND_MODE_CHANGED", { SurroundMode = tostring(id) })
end

-- Subwoofer level is stepped from the last value the driver set. Nothing confirms it.
local function SetSubwoofer(target)
  local n = tonumber(target)
  if not n then return end
  if n < SUB_MIN then n = SUB_MIN elseif n > SUB_MAX then n = SUB_MAX end
  local delta = n - gSub
  if delta == 0 then return end
  local code = (delta > 0) and IR.BASS_UP or IR.BASS_DOWN
  local steps = math.abs(delta)
  LogDebug("subwoofer: %d -> %d = %d %s press(es)", gSub, n, steps, delta > 0 and "up" or "down")
  for _ = 1, steps do SendIR(code, delta > 0 and "BASS_UP" or "BASS_DOWN") end
  gSub = n
end

-------------------------------------------------
-- PROXY COMMANDS (receiver, binding 5001)
-------------------------------------------------
local Cmd = {}
function Cmd.ON()  SetPower(true)  end
function Cmd.OFF() SetPower(false) end
function Cmd.PULSE_VOL_UP()   VolStep("up")   end
function Cmd.PULSE_VOL_DOWN() VolStep("down") end
function Cmd.MUTE_TOGGLE()    SetMuteToggle() end
-- Declared capabilities ask for toggle mute only, but the proxy may still send these; map both
-- onto the toggle rather than pretending a discrete code exists.
function Cmd.MUTE_ON()  if not gMute then SetMuteToggle() end end
function Cmd.MUTE_OFF() if gMute     then SetMuteToggle() end end
function Cmd.PULSE_INPUT() CycleInput() end

function Cmd.SET_INPUT(p)
  local id = tonumber(p and (p.INPUT or p.input or p.INPUT_ID))
  if id then SelectInput(id) end
end

function Cmd.SET_SURROUND_MODE(p)
  local raw = p and (p.SurroundMode or p.SURROUND_MODE or p["SURROUND MODE"] or p.MODE)
  SetSurround(tonumber(raw))
end

-------------------------------------------------
-- DRIVER ENTRY POINTS
-------------------------------------------------
function OnDriverInit()
  gInitDone = false
end

function OnDriverLateInit()
  for name, _ in pairs(Properties or {}) do OnPropertyChanged(name) end
  gInitDone = true
  UpdateProp("Assumed Power",  gPower and "On" or "Standby")
  UpdateProp("Assumed Mute",   tostring(gMute))
  UpdateProp("Assumed Volume", tostring(gVolume))
  UpdateProp("Assumed Input",  gInput and (INPUT_NAME[gInput] or gInput) or "unknown")
  LogCritical("driver.lua loaded: Yamaha YAS-108 @BUILD@")
end

function OnDriverDestroyed() end

function OnPropertyChanged(sProperty)
  local value = Properties and Properties[sProperty]
  LogTrace("OnPropertyChanged: %s = %s", tostring(sProperty), tostring(value))

  if sProperty == "Log Level" then
    gLogLevel = tonumber(string.match(value or "", "^(%d+)")) or LOG_LEVEL.WARNING
    return
  elseif sProperty == "Log Mode" then
    gLogMode = value or "Off"
    return
  end

  -- Composer walks every property at load. Without this guard the driver would fire IR for its
  -- own defaults on every single load - the echo-loop trap from the YAS-209 driver.
  if not gInitDone then
    if TOGGLE_PROPS[sProperty] then gSettings[sProperty] = value end
    if sProperty == "Subwoofer Level" then gSub = tonumber(value) or 0 end
    return
  end

  local toggle = TOGGLE_PROPS[sProperty]
  if toggle then
    if gSettings[sProperty] == value then return end
    gSettings[sProperty] = value
    SendIR(IR[toggle], toggle)
    LogCritical("'%s': the remote has only a TOGGLE for this, so the driver flipped it rather " ..
      "than setting it to '%s'. There is no readback on this model to correct against.",
      sProperty, tostring(value))
  elseif sProperty == "Subwoofer Level" then
    SetSubwoofer(value)
  end
end

function OnBindingChanged(idBinding, class, bIsBound)
  gBindings[idBinding] = bIsBound
  gBindingClass[idBinding] = class
  LogDebug("OnBindingChanged: binding=%s class=%s bound=%s",
    tostring(idBinding), tostring(class), tostring(bIsBound))
  if idBinding == IR_BINDING then
    LogCritical("IR binding %s is now %s (class %s).", tostring(idBinding),
      bIsBound and "BOUND" or "UNBOUND", tostring(class))
  end
end

function ReceivedFromProxy(idBinding, sCommand, tParams)
  LogTrace("ReceivedFromProxy: binding=%s cmd=%s", tostring(idBinding), tostring(sCommand))
  if idBinding ~= RECEIVER_BINDING then
    LogWarning("ReceivedFromProxy: unknown binding %s", tostring(idBinding))
    return
  end
  local h = Cmd[sCommand]
  if h then
    h(tParams)
  elseif not gUnhandledProxyCmds[sCommand] then
    -- Unsilenceable, once per command name per load. "The button did nothing" and "the driver
    -- never implemented that button" are the same experience from outside.
    gUnhandledProxyCmds[sCommand] = true
    LogCritical("Receiver proxy sent '%s', which this driver does not implement -- that button " ..
      "will do nothing. (Reported once per driver load.)", tostring(sCommand))
  end
end

-- Everything the driver believes, stated as belief. This model has no feedback path at all, so
-- there is nothing to "read"; the value of this action is making the assumptions inspectable
-- when they have drifted.
local function ShowAssumedState()
  LogCritical("---- assumed state (NOTHING here is confirmed by the bar) ----")
  LogCritical("The YAS-108 has no network interface, so the driver cannot read anything back.")
  LogCritical("These are the values it last COMMANDED. If the bar was changed with its own")
  LogCritical("remote they will be wrong -- use the Resync actions to correct power.")
  local function show(k, v) LogCritical("  %-16s %s", k, (v == nil or v == "") and "unknown" or tostring(v)) end
  show("Power",     gPower and "On" or "Standby")
  show("Mute",      tostring(gMute))
  show("Volume",    gVolume .. "% (estimated, " .. VOL_STEP_PCT .. "%/press)")
  show("Input",     gInput and (INPUT_NAME[gInput] or gInput) or nil)
  show("Surround",  gSurround and SURROUND_NAME[gSurround] or nil)
  show("Subwoofer", gSub)
  for prop, _ in pairs(TOGGLE_PROPS) do show(prop, gSettings[prop]) end
  LogCritical("-------------------------------------------------------------")
end

function ExecuteCommand(strCommand, tParams)
  -- Composer Actions arrive as "LUA_ACTION" with the real action name in tParams.ACTION.
  if strCommand == "LUA_ACTION" and type(tParams) == "table" and tParams["ACTION"] then
    strCommand = tParams["ACTION"]
  end
  LogTrace("ExecuteCommand: %s", tostring(strCommand))

  if strCommand == "TestIrEmitter" then
    IrFireOne("POWER_TOGGLE")
  elseif strCommand == "ShowAssumedState" then
    ShowAssumedState()
  elseif strCommand == "ResyncPowerOn" then
    ApplyPower(true)
    LogCritical("Assumed power corrected to ON. No IR was sent.")
  elseif strCommand == "ResyncPowerOff" then
    ApplyPower(false)
    LogCritical("Assumed power corrected to STANDBY. No IR was sent.")
  elseif strCommand:match("^IrFire_") then
    IrFireOne(strCommand:match("^IrFire_(.+)$"))
  else
    LogTrace("Unhandled command: %s", tostring(strCommand))
  end
end
