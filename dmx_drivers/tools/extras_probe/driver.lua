-- extras_probe -- DIAGNOSTIC ONLY (dmx_drivers, 2026-10-10).
--
-- Question: can ANY light_v2 driver show an Extras tab on this system? dmx_light sends a
-- well-formed setup, the proxy holds has_extras=True (static and dynamic), and still no Navigator
-- (app or T4) shows the tab, nor ever asks the driver for it. This driver strips everything else
-- away: a bare dimmer that declares Extras and sends ONE object. Add it, look, delete it.
--
-- Every message from the proxy/UI is logged, because whether Navigator ever asks for Extras
-- (GET_EXTRAS_SETUP) is as informative as whether the tab appears.
-- Shapes are written from published samples (Snap One's thermostat Extras sample; Control4's Hue
-- driver), not copied code.

local PROXY = 5001
local level = 0

local function log(fmt, ...)
  local msg = "[extras_probe] " .. string.format(fmt, ...)
  print(msg)
  C4:ErrorLog(msg)
end

local function notify(cmd, params)
  C4:SendToProxy(PROXY, cmd, params or {}, "NOTIFY")
end

local SETUPS = {
  -- Snap One sample: a checkbox in one section.
  SEND_CHECKBOX = '<extras_setup><extra><section label="Probe">'
    .. '<object type="checkbox" id="p_check" label="Probe Checkbox" command="PROBE_CMD" value="false"/>'
    .. '</section></extra></extras_setup>',
  -- Control4 Hue driver shape: a switch with explicit hidden="false".
  SEND_SWITCH = '<extras_setup><extra><section label="Probe">'
    .. '<object type="switch" id="p_switch" label="Probe Switch" hidden="false" value="false" command="PROBE_CMD"/>'
    .. '</section></extra></extras_setup>',
  -- List: the shape used by several shipping drivers.
  SEND_LIST = '<extras_setup><extra><section label="Probe">'
    .. '<object type="list" id="p_list" label="Probe List" command="PROBE_CMD" value="1">'
    .. '<list maxselections="1" minselections="1"><item text="One" value="1"/><item text="Two" value="2"/></list>'
    .. '</object></section></extra></extras_setup>',
}

local current = "SEND_CHECKBOX"

local function status(text)
  C4:UpdateProperty("Probe Status", text)
end

local function send_extras(which)
  current = which
  notify("DYNAMIC_CAPABILITIES_CHANGED", { has_extras = true })
  notify("EXTRAS_SETUP_CHANGED", { XML = SETUPS[which] })
  log("sent Extras setup %s: %s", which, SETUPS[which])
  status("Sent " .. which .. ". Now open this light on a Navigator and look for Extras.")
end

local function set_level(l)
  level = math.max(0, math.min(100, math.floor((tonumber(l) or 0) + 0.5)))
  notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = tostring(level) })
end

function OnDriverInit() end

function OnDriverLateInit()
  log("loaded (probe v1). Static has_extras=True; sending a checkbox setup now.")
  notify("ONLINE_CHANGED", { STATE = true })
  set_level(0)
  send_extras("SEND_CHECKBOX")
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  tParams = tParams or {}
  local parts = {}
  for k, v in pairs(tParams) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
  log("from proxy (binding %s): %s %s", tostring(idBinding), tostring(strCommand), table.concat(parts, " "))
  if strCommand == "ON" then set_level(100)
  elseif strCommand == "OFF" then set_level(0)
  elseif strCommand == "TOGGLE" then set_level(level > 0 and 0 or 100)
  elseif strCommand == "SET_LEVEL" or strCommand == "RAMP_TO_LEVEL" then set_level(tParams.LEVEL)
  elseif strCommand == "SET_BRIGHTNESS_TARGET" then set_level(tParams.LIGHT_BRIGHTNESS_TARGET or tParams.LEVEL)
  elseif strCommand == "GET_EXTRAS_SETUP" or strCommand == "GET_EXTRAS_STATE" then
    log("*** a UI ASKED for Extras (%s) ***", strCommand)
    send_extras(current)
  elseif strCommand == "PROBE_CMD" then
    log("*** Extras WORK: Navigator sent %s = %s ***", tostring(tParams.id), tostring(tParams.value))
    status("Extras WORK: received " .. tostring(tParams.id) .. " = " .. tostring(tParams.value))
    notify("EXTRAS_STATE_CHANGED", { XML = '<extras_state><extra><object id="' .. tostring(tParams.id)
      .. '" value="' .. tostring(tParams.value) .. '"/></extra></extras_state>' })
  end
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "LUA_ACTION" and SETUPS[tParams.ACTION] then
    send_extras(tParams.ACTION)
  elseif strCommand ~= "GET_COMMANDS" and strCommand ~= "GET_CONDITIONALS" then
    log("ExecuteCommand %s", tostring(strCommand))
  end
end
