-- scenarios.lua -- the BUILT drivers running together under c4sim (no controller, no node).
-- Run from dmx_drivers/ after ./build.sh:  luajit test/scenarios.lua
--
-- Every check reads the Art-Net bytes the node actually put on the wire, not driver internals,
-- wherever that is possible.

package.path = "common/?.lua;test/?.lua;" .. package.path

local T = require "testlib"
local Sim = require "c4sim"
local C = require "color"

local IP = "192.168.1.50"
local PAR4 = "DazzlingStage Mini Par RGBW (4ch) (unverified)"
local PAR8 = "DazzlingStage Mini Par RGBW (8ch) (unverified)"
local CK16 = "ColorKey MiniWash Quad 4 MKII (16ch) (unverified)"
local CK14 = "ColorKey MiniWash Quad 4 MKII (14ch) (unverified)"

local function rig(opts)
  opts = opts or {}
  local sim = Sim.new({ persist = opts.persist })
  local node = sim:load("artnet_node", 100, "Stage Node", { ["Node IP Address"] = IP })
  local par1 = sim:load("dmx_light", 201, "Par Left", { ["Layout"] = PAR4, ["Start Address"] = "1" })
  local par2 = sim:load("dmx_light", 202, "Par Right", { ["Layout"] = PAR8, ["Start Address"] = "5" })
  local mover = sim:load("dmx_mover", 301, "Mover", { ["Layout"] = CK16, ["Start Address"] = "20" })
  if opts.props then for dev, p in pairs(opts.props) do for k, v in pairs(p) do ({ par1 = par1, par2 = par2, mover = mover, node = node })[dev].env.Properties[k] = v end end end
  -- Bindings already exist when the project loads: OnBindingChanged does NOT fire for them.
  for _, f in ipairs({ par1, par2, mover }) do sim:bind(f, 1, node, 1, true) end
  if opts.node_first then
    sim:init(node); sim:init(par1); sim:init(par2); sim:init(mover)
  else
    sim:init(par1); sim:init(par2); sim:init(mover); sim:init(node)
  end
  sim:advance(100)
  return sim, node, par1, par2, mover
end

local function status(dev) return dev.env.Properties["Status"] end

-- Drivers pcall their handlers and log failures critically, so a thrown error never crashes a
-- test on its own. Every section ends by asserting nothing was logged as failed.
local SIMS = {}
local _new = Sim.new
Sim.new = function(...) local s = _new(...); SIMS[#SIMS + 1] = s; return s end
local function no_failures()
  local bad = {}
  for _, sim in ipairs(SIMS) do
    for _, d in pairs(sim.devices) do
      for _, line in ipairs(d.errorlog) do
        if line:find(" failed: ") then bad[#bad + 1] = d.name .. ": " .. line end
      end
    end
  end
  T.eq(bad, {}, "no command/property handler threw")
  SIMS = {}
end
local _section = T.section
T.section = function(name)
  if T.current then no_failures() end
  _section(name)
end
local _finish = T.finish
T.finish = function() no_failures(); _finish() end

---------------------------------------------------------------------------------------------
T.section("boot: fixtures load before the node")
do
  local sim, node, par1, par2, mover = rig()
  T.like(status(par1), "^OK: DMX 1%-4", "par1 registered")
  T.like(status(par2), "^OK: DMX 5%-12", "par2 registered")
  T.like(status(mover), "^OK: DMX 20%-35", "mover registered")
  T.like(status(node), "3 fixture%(s%)", "node counts 3 fixtures")
  T.like(node.env.Properties["Patch"], "DMX 20%-35  Mover", "patch lists the mover")
  local online = sim:last_notify(par1, "ONLINE_CHANGED")
  T.ok(online and online.params.STATE == true, "light_v2 told ONLINE")
  local f = sim:frame()
  T.ok(f ~= nil, "a frame was sent")
  T.eq({ f.net, f.subnet, f.universe }, { 0, 0, 0 }, "frame port address 0/0/0")
  T.eq(sim.packets[#sim.packets].ip, IP, "unicast to the node IP")
  T.eq(sim.packets[#sim.packets].kind, "UDP", "over UDP")
  T.eq(sim.packets[#sim.packets].port, 6454, "port 6454")
  T.eq(sim:slots(20, 35)[16], 0, "mover reset channel at its default")
  T.like(par1.errorlog[1], "loaded v0%.1%.0 %(build %d+, %x+%)", "build stamp logged unsilenceably")
end

T.section("boot: node loads first")
do
  local sim, node, par1, _, mover = rig({ node_first = true })
  T.like(status(par1), "^OK", "par1 registered")
  T.like(status(mover), "^OK", "mover registered")
end

---------------------------------------------------------------------------------------------
T.section("par: color and brightness reach the wire")
do
  local sim, node, par1 = rig()
  -- Color chosen while off is remembered and used when the light comes on.
  sim:proxy(par1, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.64, LIGHT_COLOR_TARGET_Y = 0.33, LIGHT_COLOR_TARGET_MODE = 0 })
  sim:advance(50)
  T.eq(sim:slots(1, 4), { 0, 0, 0, 0 }, "still dark while off")
  T.ok(sim:last_notify(par1, "LIGHT_COLOR_CHANGED") ~= nil, "color change notified while off")
  sim:proxy(par1, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 0 })
  sim:advance(50)
  T.eq(sim:slots(1, 4), { 255, 0, 0, 0 }, "full red on a 4ch par (virtual dimmer)")
  -- D65 white goes to the white emitter.
  sim:proxy(par1, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.3127, LIGHT_COLOR_TARGET_Y = 0.3290, LIGHT_COLOR_TARGET_MODE = 0 })
  sim:advance(50)
  local s = sim:slots(1, 4)
  T.ok(s[4] >= 250 and s[1] <= 6 and s[2] <= 6 and s[3] <= 6, "white point -> white emitter " .. T.show(s))
  -- 50% on a virtual dimmer applies the 2.2 curve.
  sim:proxy(par1, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 0 })
  sim:advance(50)
  T.near(sim:slots(4, 4)[1], math.floor(255 * 0.5 ^ 2.2 + 0.5), 2, "virtual dimmer gamma 2.2 at 50%")
  -- OFF
  sim:proxy(par1, "OFF", {})
  sim:advance(50)
  T.eq(sim:slots(1, 4), { 0, 0, 0, 0 }, "OFF -> dark")
  local changed = sim:last_notify(par1, "LIGHT_BRIGHTNESS_CHANGED")
  T.eq(changed.params.LIGHT_BRIGHTNESS_CURRENT, 0, "OFF notified")
end

T.section("par: fades run on the node, notifies bracket them")
do
  local sim, node, par1 = rig()
  sim:proxy(par1, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.3127, LIGHT_COLOR_TARGET_Y = 0.3290, LIGHT_COLOR_TARGET_MODE = 0 })
  sim:set_property(par1, "Dimming Curve", "1.0 (linear)")
  sim:clear(par1)
  local t0 = sim.clock
  sim:proxy(par1, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
  local changing = sim:notifies(par1, "LIGHT_BRIGHTNESS_CHANGING")
  T.eq(#changing, 1, "one CHANGING at the start")
  T.eq(changing[1].params.RATE, 2000, "CHANGING carries the rate")
  sim:advance(1000)
  local mid = sim:slots(4, 4)[1]
  T.near(mid, 128, 12, "halfway through a 2 s fade")
  T.eq(#sim:notifies(par1, "LIGHT_BRIGHTNESS_CHANGED"), 0, "no CHANGED mid-fade (no level streaming)")
  sim:advance(1100)
  T.eq(sim:slots(4, 4)[1], 255, "fade complete")
  T.eq(#sim:notifies(par1, "LIGHT_BRIGHTNESS_CHANGED"), 1, "exactly one CHANGED at the end")
  -- Frame-rate cap: a 2 s fade at 30 fps is at most ~61 frames, plus keepalives.
  local frames = sim:packets_between(t0, t0 + 2000)
  T.ok(frames <= 64, "frame rate capped during the fade (" .. frames .. " frames in 2 s)")
  T.ok(frames >= 40, "fade actually streamed frames (" .. frames .. ")")
end

T.section("par: hold-to-ramp from a keypad button link")
do
  local sim, node, par1 = rig()
  sim:proxy(par1, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.3127, LIGHT_COLOR_TARGET_Y = 0.3290, LIGHT_COLOR_TARGET_MODE = 0 })
  sim:clear(par1)
  sim:proxy(par1, "BUTTON_ACTION", { BUTTON_ID = 0, ACTION = 1 })  -- press TOP
  T.eq(sim:last_notify(par1, "BUTTON_ACTION").params.ACTION, 1, "press echoed to the proxy")
  sim:advance(250 + 2500)                                          -- debounce, then half a 5 s hold
  sim:proxy(par1, "BUTTON_ACTION", { BUTTON_ID = 0, ACTION = 0 })  -- release (hold)
  local lvl = sim:last_notify(par1, "LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT
  T.ok(lvl >= 40 and lvl <= 60, "hold stopped midway (" .. tostring(lvl) .. "%)")
  sim:advance(3000)
  T.eq(sim:last_notify(par1, "LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT, lvl, "stays where it stopped")
  -- A click on BOTTOM turns it off.
  sim:proxy(par1, "BUTTON_ACTION", { BUTTON_ID = 1, ACTION = 1 })
  sim:advance(100)
  sim:proxy(par1, "BUTTON_ACTION", { BUTTON_ID = 1, ACTION = 2 })
  sim:advance(1000)
  T.eq(sim:slots(1, 4), { 0, 0, 0, 0 }, "click BOTTOM -> off")
end

T.section("par: 8ch layout, Extras and the real dimmer channel")
do
  local sim, node, _, par2 = rig()
  sim:proxy(par2, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.15, LIGHT_COLOR_TARGET_Y = 0.06, LIGHT_COLOR_TARGET_MODE = 0 })
  sim:proxy(par2, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 0 })
  sim:advance(50)
  local s = sim:slots(5, 12)
  T.eq(s[1], 102, "dimmer channel carries brightness (40% linear)")
  T.ok(s[4] >= 250 and s[2] <= 4, "blue at full chroma behind the dimmer")
  local setup = sim:last_notify(par2, "EXTRAS_SETUP_CHANGED")
  T.ok(setup ~= nil, "Extras setup sent")
  T.like(setup.params.XML, 'id="r_strobe"', "strobe slider on the Extras tab")
  T.like(setup.params.XML, 'id="r_program"', "program list on the Extras tab")
  local caps = sim:last_notify(par2, "DYNAMIC_CAPABILITIES_CHANGED").params
  T.eq(caps.has_extras, true, "has_extras set from the layout")
  T.eq(caps.supports_color, true, "color capability")
  sim:proxy(par2, "EXTRA_r_strobe", { value = "200" })
  sim:advance(50)
  T.eq(sim:slots(10, 10)[1], 200, "Extras strobe slider reaches channel 6")
  T.like(sim:last_notify(par2, "EXTRAS_STATE_CHANGED").params.XML, 'id="r_strobe" value="200"', "Extras change echoed (UI reverts after 10 s otherwise)")
  sim:command(par2, "Restore Control Defaults", {})
  sim:advance(50)
  T.eq(sim:slots(10, 10)[1], 0, "Restore Control Defaults")
  sim:command(par2, "Set Control", { Control = "Strobe/Shutter", Value = 77 })
  sim:advance(50)
  T.eq(sim:slots(10, 10)[1], 77, "Set Control programming command")
  -- 4ch par: no Extras at all.
  local _, _, par1 = rig()
end

---------------------------------------------------------------------------------------------
T.section("configuration errors: refused, reverted, explained")
do
  local sim, node, par1, par2 = rig()
  sim:set_property(par2, "Start Address", "510")
  T.eq(par2.env.Properties["Start Address"], "5", "overflowing start address reverted")
  T.like(status(par2), "Start Address 510 refused: .*would end at 517", "status explains the overflow")
  T.like(par2.errorlog[#par2.errorlog], "Start Address 510 refused", "logged through the unsilenceable path")
  T.like(status(par2), "still running the previous layout", "still outputting")

  sim:set_property(par1, "Channel Map", "dimmer,red,green,bogus")
  T.like(status(par1), "unknown function 'bogus'", "bad channel map explained")
  T.eq(par1.env.Properties["Layout"], PAR4, "layout untouched by a bad map")

  sim:set_property(par1, "Channel Map", "dimmer,red,green,blue,white")
  T.eq(par1.env.Properties["Layout"], "Custom", "editing the map switches to Custom")
  T.eq(par1.env.Properties["Channel Count"], "5", "custom channel count written")
  T.eq(par1.env.Properties["Channel 5 Function"], "White", "custom channel 5 written")
  T.eq(par1.env.Properties["Footprint"], "DMX 1-5 (5 ch)", "footprint updated")
  T.like(node.env.Properties["Patch"], "DMX 1%-5  Par Left", "node re-registered the new footprint")
  T.like(status(par1), "^OK", "custom layout running")

  -- Switching a built-in to Custom starts from the built-in.
  sim:set_property(par2, "Layout", "Custom")
  T.eq(par2.env.Properties["Channel Map"], "dimmer,red,green,blue,white,strobe,program,macro_speed", "Custom seeded from the built-in")
  T.eq(par2.env.Properties["Channel 6 Function"], "Strobe/Shutter", "per-channel property seeded")
  T.ok(not par2.hidden["Channel 8 Function"] and par2.hidden["Channel 9 Function"], "only the used channel properties are shown")

  -- Editing one channel updates the map mirror.
  sim:set_property(par2, "Channel 8 Function", "Unused")
  T.eq(par2.env.Properties["Channel Map"], "dimmer,red,green,blue,white,strobe,program,unused", "map mirrors a channel edit")

  -- A pan channel is not available on a par; the running layout stays.
  sim:set_property(par2, "Channel Map", "dimmer,pan")
  T.like(status(par2), "'Pan' is not available for a Color Par", "type restrictions enforced")

  -- No node bound.
  local sim2 = Sim.new()
  local lonely = sim2:load("dmx_light", 400, "Lonely Par", { ["Layout"] = PAR4 })
  sim2:init(lonely)
  T.like(status(lonely), "no Art%-Net node bound", "unbound fixture says so")
  T.like(lonely.errorlog[#lonely.errorlog], "no Art%-Net node bound", "...unsilenceably")
  local claimed = false
  for _, n in ipairs(sim2:notifies(lonely, "ONLINE_CHANGED")) do if n.params.STATE == true then claimed = true end end
  T.ok(not claimed, "never claimed online")
end

---------------------------------------------------------------------------------------------
T.section("overlap policy")
do
  local sim, node, par1, par2, mover = rig()
  local par3 = sim:load("dmx_light", 203, "Par Twin", { ["Layout"] = PAR4, ["Start Address"] = "1" })
  sim:init(par3)
  sim:bind(par3, 1, node, 1)
  sim:advance(50)
  T.like(status(par3), "^OK.*shares channels with 'Par Left'", "twin par shares, and is told")
  T.like(status(par1), "shares channels with 'Par Twin'", "the incumbent is told too")
  sim:proxy(par1, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.64, LIGHT_COLOR_TARGET_Y = 0.33, LIGHT_COLOR_TARGET_MODE = 0 })
  sim:proxy(par1, "ON", {})
  sim:proxy(par3, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.15, LIGHT_COLOR_TARGET_Y = 0.06, LIGHT_COLOR_TARGET_MODE = 0 })
  sim:proxy(par3, "ON", {})
  sim:advance(50)
  local s = sim:slots(1, 4)
  T.ok(s[1] == 255 and s[3] == 255, "HTP merge: red from one, blue from the other " .. T.show(s))

  local mover2 = sim:load("dmx_mover", 302, "Mover Two", { ["Layout"] = CK16, ["Start Address"] = "30" })
  sim:init(mover2)
  sim:bind(mover2, 1, node, 1)
  sim:advance(50)
  T.like(status(mover2), "NOT OUTPUTTING: REFUSED: overlaps moving fixture 'Mover'", "overlapping mover refused")
  T.like(status(mover), "^OK", "the incumbent keeps running")
  local off = sim:last_notify(mover2, "ONLINE_CHANGED")
  T.ok(off == nil or off.params.STATE == false, "refused mover's load is not online")
  sim:proxy(mover2, "ON", {})
  sim:advance(50)
  T.eq(sim:slots(36, 45), { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, "refused mover outputs nothing past the incumbent")
  T.like(node.env.Properties["Status"], "1 REFUSED", "node status counts the refusal")

  -- A par that lands on the mover is refused too.
  local par4 = sim:load("dmx_light", 204, "Stray Par", { ["Layout"] = PAR4, ["Start Address"] = "22" })
  sim:init(par4)
  sim:bind(par4, 1, node, 1)
  sim:advance(50)
  T.like(status(par4), "REFUSED: overlaps moving fixture 'Mover'", "par on a mover's channels refused")

  -- Move the incumbent away: the refused mover takes over.
  sim:set_property(mover, "Start Address", "100")
  sim:advance(50)
  T.like(status(mover2), "^OK: DMX 30%-45", "refused mover accepted once the conflict is gone")
end

---------------------------------------------------------------------------------------------
T.section("mover: position")
do
  local sim, node, _, _, mover = rig()
  local base = 20
  sim:proxy(mover, "EXTRA_p_pan", { value = "25" })
  sim:advance(300)
  local s = sim:slots(base, base + 3)
  local pan16 = s[1] * 256 + s[2]
  T.near(pan16, 0.25 * 65535, 1, "pan 25% as 16-bit coarse+fine")
  T.like(sim:last_notify(mover, "EXTRAS_STATE_CHANGED").params.XML, 'id="p_pan" value="25"', "pan slider echoed")
  sim:proxy(mover, "EXTRA_p_tilt", { value = "80" })
  sim:advance(300)
  s = sim:slots(base, base + 3)
  T.near(s[3] * 256 + s[4], 0.80 * 65535, 1, "tilt 80%")

  -- Nudge (default Medium 2%).
  sim:proxy(mover, "EXTRA_a_right", { value = "" })
  sim:advance(300)
  s = sim:slots(base, base + 3)
  T.near(s[1] * 256 + s[2], 0.27 * 65535, 2, "nudge right 2%")

  -- Soft limits clamp everything, including what is already set.
  sim:set_property(mover, "Pan Min (%)", "40")
  sim:advance(600)
  s = sim:slots(base, base + 3)
  T.near(s[1] * 256 + s[2], 0.40 * 65535, 2, "soft limit pulls pan to 40%")
  sim:command(mover, "Set Position", { ["Pan %"] = 10, ["Tilt %"] = 50, ["Fade (s)"] = 0 })
  sim:advance(50)
  s = sim:slots(base, base + 3)
  T.near(s[1] * 256 + s[2], 0.40 * 65535, 2, "programming cannot pass the soft limit")

  sim:command(mover, "Home Position", {})
  sim:advance(1000)
  s = sim:slots(base, base + 3)
  T.near(s[1] * 256 + s[2], 0.70 * 65535, 2, "Home = centre of the 40-100 window")

  -- Invert
  sim:set_property(mover, "Invert Tilt", "Yes")
  sim:advance(600)
  s = sim:slots(base, base + 3)
  T.near(s[3] * 256 + s[4], 0.50 * 65535, 2, "inverted tilt at 50% is still 50%")
  sim:command(mover, "Set Position", { ["Pan %"] = 70, ["Tilt %"] = 20, ["Fade (s)"] = 0 })
  sim:advance(50)
  s = sim:slots(base, base + 3)
  T.near(s[3] * 256 + s[4], 0.80 * 65535, 2, "inverted tilt 20% -> 80% on the wire")

  -- 16-bit fade: coarse never leads fine.
  sim:set_property(mover, "Invert Tilt", "No")
  sim:command(mover, "Set Position", { ["Pan %"] = 40, ["Tilt %"] = 0, ["Fade (s)"] = 0 })
  sim:advance(50)
  sim:command(mover, "Set Position", { ["Pan %"] = 100, ["Tilt %"] = 0, ["Fade (s)"] = 2 })
  sim:advance(1000)
  s = sim:slots(base, base + 1)
  T.near(s[1] * 256 + s[2], 0.70 * 65535, 400, "pan fade halfway is halfway in 16 bits")
end

T.section("mover: color on the native light, speed and reset")
do
  local sim, node, _, _, mover = rig()
  local base = 20
  sim:proxy(mover, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.30, LIGHT_COLOR_TARGET_Y = 0.60, LIGHT_COLOR_TARGET_MODE = 0 })
  sim:proxy(mover, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 0 })
  sim:advance(50)
  local s = sim:slots(base, base + 15)
  T.eq(s[6], 255, "mover dimmer (ch 6) at full")
  T.ok(s[9] >= 250 and s[8] <= 5 and s[10] <= 5, "green on ch 9 " .. T.show(s))
  local setup = sim:last_notify(mover, "EXTRAS_SETUP_CHANGED").params.XML
  T.like(setup, '<section label="Position">.*id="p_pan".*id="r_pt_speed"', "Position section: sliders then speed")
  T.like(setup, '<section label="Presets">', "Presets section")
  T.like(setup, 'id="r_movement_macro".-<item text="Auto %(fast%)"', "stepped role shown as named steps")
  sim:proxy(mover, "EXTRA_r_movement_macro", { value = "2" })
  sim:advance(50)
  T.eq(sim:slots(base + 11, base + 11)[1], 16, "named step sends the low end of its range")
  sim:clear(mover)
  sim:action(mover, "RESET_MOTORS")
  sim:advance(50)
  T.eq(sim:slots(base + 15, base + 15)[1], 255, "reset value while resetting")
  T.eq(mover.events[1], "Reset Started", "Reset Started event")
  sim:advance(5100)
  T.eq(sim:slots(base + 15, base + 15)[1], 0, "reset channel back to default after the hold")
  T.eq(mover.events[2], "Reset Finished", "Reset Finished event")
end

---------------------------------------------------------------------------------------------
T.section("mover: presets")
do
  local sim, node, _, _, mover = rig()
  local base = 20
  local M = mover.env.DMX_MOVER
  sim:command(mover, "Set Position", { ["Pan %"] = 30, ["Tilt %"] = 60, ["Fade (s)"] = 0 })
  sim:proxy(mover, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.64, LIGHT_COLOR_TARGET_Y = 0.33, LIGHT_COLOR_TARGET_MODE = 0 })
  sim:proxy(mover, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 0 })
  sim:proxy(mover, "EXTRA_r_strobe", { value = "33" })
  sim:advance(50)
  local saved = sim:slots(base, base + 15)
  -- Save from the Extras tab: slot 1, a name, Everything.
  sim:proxy(mover, "EXTRA_ps_slot", { value = "1" })
  sim:proxy(mover, "EXTRA_ps_name", { value = "Stage Left" })
  sim:proxy(mover, "EXTRA_ps_mode", { value = "3" })
  sim:proxy(mover, "EXTRA_a_save", { value = "" })
  T.eq(M.presets:get(1).name, "Stage Left", "preset saved with its name")
  T.like(mover.env.Properties["Selected Preset"], "^1: Stage Left", "Composer preset list refreshed")

  -- Change everything, then recall.
  sim:command(mover, "Set Position", { ["Pan %"] = 90, ["Tilt %"] = 10, ["Fade (s)"] = 0 })
  sim:proxy(mover, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.15, LIGHT_COLOR_TARGET_Y = 0.06, LIGHT_COLOR_TARGET_MODE = 0 })
  sim:proxy(mover, "OFF", {})
  sim:proxy(mover, "EXTRA_r_strobe", { value = "0" })
  sim:advance(50)
  sim:clear(mover)
  sim:command(mover, "Recall Preset", { Preset = "1: Stage Left", ["Fade (s)"] = 0 })
  sim:advance(50)
  T.eq(sim:slots(base, base + 15), saved, "recall restores every channel exactly")
  T.eq(mover.events[1], "Preset Recalled", "Preset Recalled event")
  T.eq(mover.variables.CURRENT_PRESET, "1", "CURRENT_PRESET variable")
  T.eq(mover.variables.CURRENT_PRESET_NAME, "Stage Left", "CURRENT_PRESET_NAME variable")
  T.eq(sim:last_notify(mover, "LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT, 80, "the light load reflects the recalled level")

  -- Position-only preset leaves color alone.
  sim:command(mover, "Set Position", { ["Pan %"] = 10, ["Tilt %"] = 10, ["Fade (s)"] = 0 })
  sim:proxy(mover, "EXTRA_ps_slot", { value = "2" })
  sim:proxy(mover, "EXTRA_ps_mode", { value = "1" })
  sim:proxy(mover, "EXTRA_a_save", { value = "" })
  sim:proxy(mover, "OFF", {})
  sim:command(mover, "Recall Preset", { Preset = "2: Preset 2", ["Fade (s)"] = 0 })
  sim:advance(50)
  T.eq(sim:slots(base + 5, base + 5)[1], 0, "position-only preset did not turn the light on")

  -- Recall on a different layout: the fine channels are skipped, the rest applies.
  sim:set_property(mover, "Layout", CK14)
  sim:advance(50)
  sim:command(mover, "Recall Preset", { Preset = "1: Stage Left", ["Fade (s)"] = 0 })
  sim:advance(50)
  local s14 = sim:slots(base, base + 13)
  T.near(s14[1], saved[1], 1, "pan coarse on the 14ch layout")
  T.eq(s14[5], 33, "strobe (ch 5 on 14ch) restored")

  -- Export / import round trip.
  sim:action(mover, "EXPORT_PRESETS")
  local json = mover.env.Properties["Presets Export/Import"]
  T.like(json, '"Stage Left"', "export writes JSON")
  sim:action(mover, "DELETE_PRESET")          -- deletes the selected slot (1)
  T.eq(M.presets:get(1), nil, "deleted")
  sim:set_property(mover, "Presets Export/Import", json)
  T.eq(M.presets:get(1).name, "Stage Left", "import restores")
  T.eq(mover.env.Properties["Presets Export/Import"], "", "import field cleared after use")
  sim:set_property(mover, "Presets Export/Import", "{broken")
  T.like(mover.errorlog[#mover.errorlog], "Presets Import: not valid JSON", "bad import explained, presets kept")
  T.eq(M.presets:get(1).name, "Stage Left", "bad import changed nothing")
end

T.section("mover: a position preset linked to a lighting scene (full ALS)")
do
  local sim, node, _, _, mover = rig()
  local base = 20
  local M = mover.env.DMX_MOVER
  local cx, cy = C.kelvin_to_xy(3000)
  local elements = string.format("<element><delay>0</delay><rate>0</rate><level>70</level><brightnessEnabled>True</brightnessEnabled><colorEnabled>True</colorEnabled><colorRate>0</colorRate><colorX>%.4f</colorX><colorY>%.4f</colorY><colorMode>1</colorMode></element>", cx, cy)
  sim:proxy(mover, "PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = elements, FLASH = "False", IGNORE_RAMP = "False" })
  sim:command(mover, "Set Position", { ["Pan %"] = 20, ["Tilt %"] = 30, ["Fade (s)"] = 0 })
  sim:proxy(mover, "EXTRA_ps_slot", { value = "5" })
  sim:proxy(mover, "EXTRA_ps_mode", { value = "3" })
  sim:proxy(mover, "EXTRA_a_save", { value = "" })
  -- Fire the scene, then link.
  sim:proxy(mover, "ACTIVATE_SCENE", { SCENE_ID = 7 })
  sim:advance(50)
  T.eq(sim:last_notify(mover, "LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT, 70, "scene element applied")
  sim:proxy(mover, "EXTRA_a_link", { value = "" })
  T.eq(M.presets.links[7], 5, "preset 5 linked to scene 7")
  T.like(mover.env.Properties["Scene Links"], "scene 7 %-> 5", "Scene Links property")
  -- Move away and change color, then fire the scene again.
  sim:command(mover, "Set Position", { ["Pan %"] = 90, ["Tilt %"] = 90, ["Fade (s)"] = 0 })
  sim:advance(50)
  sim:proxy(mover, "ACTIVATE_SCENE", { SCENE_ID = 7 })
  sim:advance(50)
  local s = sim:slots(base, base + 3)
  T.near(s[1] * 256 + s[2], 0.20 * 65535, 2, "linked scene moves pan back")
  T.near(s[3] * 256 + s[4], 0.30 * 65535, 2, "linked scene moves tilt back")
  T.eq(sim:slots(base + 5, base + 5)[1], math.floor(0.70 * 255 + 0.5), "scene, not preset, owns intensity")
  -- An unlinked scene does not move the head.
  sim:proxy(mover, "PUSH_SCENE", { SCENE_ID = 8, ELEMENTS = "<element><delay>0</delay><rate>0</rate><level>10</level></element>" })
  sim:command(mover, "Set Position", { ["Pan %"] = 90, ["Tilt %"] = 90, ["Fade (s)"] = 0 })
  sim:proxy(mover, "ACTIVATE_SCENE", { SCENE_ID = 8 })
  sim:advance(50)
  s = sim:slots(base, base + 1)
  T.near(s[1] * 256 + s[2], 0.90 * 65535, 2, "unlinked scene leaves position alone")
  -- Unlink
  sim:proxy(mover, "ACTIVATE_SCENE", { SCENE_ID = 7 })
  sim:proxy(mover, "EXTRA_a_unlink", { value = "" })
  T.eq(M.presets.links[7], nil, "unlinked")
end

---------------------------------------------------------------------------------------------
T.section("node: keepalive, blackout, test channel, health")
do
  local sim, node = rig()
  sim:advance(2000)
  local t0 = sim.clock
  sim:advance(10000)
  local n = sim:packets_between(t0, sim.clock)
  T.ok(n >= 9 and n <= 11, "idle keepalive about 1 Hz (" .. n .. " frames in 10 s)")

  sim:action(node, "BLACKOUT")
  T.like(node.env.Properties["Status"], "BLACKOUT", "blackout shown in status")
  -- Channel Test: a fixture with master on 300 and RGBW on 301-304, driven live.
  T.ok(node.hidden["Test Ch 1"] and node.hidden["Test Start Channel"], "test sliders hidden while Off")
  sim:set_property(node, "Test Start Channel", "300")
  sim:set_property(node, "Test Ch 1", "255")
  sim:set_property(node, "Test Ch 4", "40")
  T.eq(sim:slots(300, 300)[1], 0, "nothing driven while Test Channels is Off")
  sim:set_property(node, "Test Channels", "5")
  sim:advance(50)
  T.ok(not node.hidden["Test Ch 5"] and node.hidden["Test Ch 6"], "exactly 5 sliders shown")
  T.eq(table.concat(sim:slots(300, 305), ","), "255,0,0,40,0,0", "5 test channels on the wire, 305 untouched")
  T.like(node.env.Properties["Status"], "CHANNEL TEST ACTIVE on DMX 300%-304", "test shown in status")
  T.like(node.env.Properties["Test Addresses"], "Ch 5 = DMX 304", "address map shown")
  sim:set_property(node, "Test Ch 2", "128")
  sim:advance(50)
  T.eq(sim:slots(301, 301)[1], 128, "slider takes effect as it moves")
  sim:advance(10000)
  T.eq(sim:slots(300, 300)[1], 255, "test holds (no 5 s expiry)")
  sim:set_property(node, "Test Channels", "Off")
  sim:advance(50)
  T.eq(table.concat(sim:slots(300, 304), ","), "0,0,0,0,0", "Off releases every test channel")
  T.ok(node.hidden["Test Ch 1"], "sliders hidden again")
  T.ok(not tostring(node.env.Properties["Status"]):find("TEST ACTIVE"), "status clears")
  sim:set_property(node, "Test Start Channel", "510")
  sim:set_property(node, "Test Channels", "4")
  sim:advance(50)
  T.like(node.env.Properties["Test Addresses"], "Ch 4 = past 512, ignored", "channels past 512 are refused, not wrapped")
  sim:set_property(node, "Test Channels", "Off")

  sim.ping_ok[IP] = false
  sim:advance(30100)
  T.like(node.env.Properties["Status"], "NODE NOT REACHABLE", "failed ping reported")
  local par1 = sim.devices[201]
  T.like(status(par1), "node reports its Art%-Net device is not reachable", "fixtures told")
  sim.ping_ok[IP] = true
  sim:advance(30100)
  T.like(node.env.Properties["Status"], "node answers ping", "recovery reported")

  sim:set_property(node, "Node IP Address", "")
  T.like(node.env.Properties["Status"], "NOT SENDING: set Node IP Address", "missing IP explained")
  sim:set_property(node, "Node IP Address", "192.168.1.255")
  T.like(node.env.Properties["Status"], "NOT SENDING", "broadcast address refused")
  sim:set_property(node, "Node IP Address", IP)
  sim:set_property(node, "Art-Net Universe", "3")
  sim:advance(100)
  T.eq(sim:frame().universe, 3, "universe change reaches the wire")
end

T.section("node: duplicate drivers for the same node")
do
  local sim, node = rig()
  local node2 = sim:load("artnet_node", 101, "Second Node", { ["Node IP Address"] = IP })
  sim:init(node2)
  T.like(node2.env.Properties["Status"], "WARNING: 'Stage Node' also sends to", "new node warned")
  T.like(node.env.Properties["Status"], "WARNING: 'Second Node' also sends to", "existing node warned")
  sim:set_property(node2, "Art-Net Universe", "1")
  T.ok(not node2.env.Properties["Status"]:find("WARNING"), "different universe is fine")
end

---------------------------------------------------------------------------------------------
T.section("restart: the node reloads while fixtures run")
do
  local sim, node, par1 = rig()
  sim:proxy(par1, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.64, LIGHT_COLOR_TARGET_Y = 0.33, LIGHT_COLOR_TARGET_MODE = 0 })
  sim:proxy(par1, "ON", {})
  sim:advance(100)
  local before = sim:slots(1, 40)
  -- Replace the node driver with a fresh instance (driver update / Director restart of the node).
  local node2 = sim:load("artnet_node", 100, "Stage Node", { ["Node IP Address"] = IP })
  sim:init(node2)
  sim:advance(100)
  T.eq(sim:slots(1, 40), before, "fresh node rebuilt the same frame from the fixtures")
  T.like(node2.env.Properties["Patch"], "Par Left", "fresh node has the patch")
end

T.section("restart: controller reboot restores the rig without jumps")
do
  local store = {}
  local sim, node, par1, par2, mover = rig({ persist = store })
  sim:proxy(par1, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.15, LIGHT_COLOR_TARGET_Y = 0.06, LIGHT_COLOR_TARGET_MODE = 0 })
  sim:proxy(par1, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 0 })
  sim:command(mover, "Set Position", { ["Pan %"] = 33, ["Tilt %"] = 66, ["Fade (s)"] = 0 })
  sim:proxy(mover, "ON", {})
  sim:advance(6000)                       -- past the 5 s persistence debounce
  local before = sim:slots(1, 40)
  -- Reboot: every driver reloads from persisted state + properties.
  local props = {}
  for id, d in pairs(sim.devices) do props[id] = d.env.Properties end
  local sim2 = Sim.new({ persist = store })
  local n2 = sim2:load("artnet_node", 100, "Stage Node", props[100])
  local p1 = sim2:load("dmx_light", 201, "Par Left", props[201])
  local p2 = sim2:load("dmx_light", 202, "Par Right", props[202])
  local m2 = sim2:load("dmx_mover", 301, "Mover", props[301])
  for _, f in ipairs({ p1, p2, m2 }) do sim2:bind(f, 1, n2, 1, true) end
  sim2:init(p1); sim2:init(p2); sim2:init(m2); sim2:init(n2)
  sim2:advance(100)
  -- Every frame the node sent after the reboot must equal the pre-reboot look: no jump through
  -- black or through defaults.
  local jumps = 0
  for _, p in ipairs(sim2.packets) do
    local f = require("artnet").parse(p.data)
    for n = 1, 40 do if require("artnet").slot(f, n) ~= before[n] then jumps = jumps + 1; break end end
  end
  T.eq(sim2:slots(1, 40), before, "same look after reboot")
  T.eq(jumps, 0, "no frame after the reboot differed from the restored look")
  T.eq(sim2:last_notify(p1, "LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT, 60, "light load announces its restored level")
end

---------------------------------------------------------------------------------------------
T.section("negative controls: the checks above can fail")
do
  -- If the frame decoder or the slot helper were broken, every "reaches the wire" check would be
  -- meaningless. Poke a known value in and read it back.
  local sim, node = rig()
  sim:set_property(node, "Test Start Channel", "17")
  sim:set_property(node, "Test Ch 1", "201")
  sim:set_property(node, "Test Channels", "1")
  sim:advance(50)
  T.eq(sim:slots(17, 17)[1], 201, "decoder reads a known injected value")
  -- A one-shot timer must fire exactly once in the stub (a stub that repeated it would hide the
  -- YAS209 one-shot-poll bug class).
  local count = 0
  node.env.C4:SetTimer(10, function() count = count + 1 end)
  sim:advance(1000)
  T.eq(count, 1, "one-shot timers fire once")
  local ok = pcall(function() return node.env.C4:ReadFile("x") end)
  T.ok(not ok, "an undocumented C4 call raises instead of silently passing")
end

T.finish()
