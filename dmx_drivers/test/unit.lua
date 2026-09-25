-- unit.lua -- off-controller unit tests for the pure modules.
-- Run from dmx_drivers/:  luajit test/unit.lua
-- (LuaJIT because Director runs driver.lua with jit="1": same 5.1 semantics as the controller.)

package.path = "common/?.lua;artnet_node/?.lua;dmx_mover/?.lua;test/?.lua;" .. package.path

local T = require "testlib"
local U = require "util"
local A = require "artnet"
local L = require "layouts"
local C = require "color"
local Universe = require "universe"

---------------------------------------------------------------------------------------------
T.section("artnet")
do
  local slots = {}
  for i = 1, 512 do slots[i] = (i * 7) % 256 end
  local data = A.slots_to_string(slots)
  local pkt = A.pack_dmx(1, 2, 3, 200, data)
  T.eq(#pkt, 530, "ArtDmx is 18 header bytes + 512")
  T.eq(pkt:sub(1, 8), "Art-Net\0", "ID")
  T.eq({ pkt:byte(9, 10) }, { 0x00, 0x50 }, "OpCode 0x5000 little-endian")
  T.eq({ pkt:byte(11, 12) }, { 0x00, 0x0E }, "ProtVer 14")
  T.eq(pkt:byte(13), 200, "sequence")
  T.eq(pkt:byte(14), 0, "physical")
  T.eq(pkt:byte(15), 2 * 16 + 3, "SubUni = subnet<<4 | universe")
  T.eq(pkt:byte(16), 1, "Net")
  T.eq({ pkt:byte(17, 18) }, { 0x02, 0x00 }, "length 512 big-endian")
  T.eq(pkt:byte(19), 7, "slot 1")
  T.eq(pkt:byte(530), (512 * 7) % 256, "slot 512")
  local p = A.parse(pkt)
  T.eq(p.opcode, A.OP_DMX, "parse opcode")
  T.eq({ p.net, p.subnet, p.universe, p.sequence, p.length }, { 1, 2, 3, 200, 512 }, "parse fields")
  T.eq(A.slot(p, 2), 14, "parse slot 2")
  T.eq(A.next_sequence(255), 1, "sequence rolls 255 -> 1, never 0 (0 disables sequencing)")
  T.eq(A.next_sequence(1), 2, "sequence increments")
  T.ok(not pcall(A.pack_dmx, 128, 0, 0, 1, data), "Net 128 rejected")
  T.ok(not pcall(A.pack_dmx, 0, 16, 0, 1, data), "SubNet 16 rejected")
  T.eq(A.port_address(0, 0, 0), 0, "port address 0/0/0")
  T.eq(A.port_address(127, 15, 15), 32767, "port address max")
  local clamp = A.slots_to_string({ -5, 300, 12.6 })
  T.eq({ clamp:byte(1, 3) }, { 0, 255, 13 }, "slot values clamped and rounded")
end

---------------------------------------------------------------------------------------------
T.section("layouts")
do
  local ck16 = L.compile(L.BUILTIN.colorkey_miniwash_quad4_mk2_16)
  T.ok(ck16, "ColorKey 16ch compiles")
  T.eq(ck16.count, 16, "16 channels")
  T.eq(ck16.roles.pan, 0, "pan at offset 0")
  T.eq(ck16.roles.reset, 15, "reset at offset 15")
  T.eq(#ck16.pairs, 2, "pan and tilt pairs")
  T.ok(ck16.has_dimmer and ck16.has_rgb and ck16.has_white, "dimmer + RGBW")
  T.eq(ck16.driver, "mover", "mover driver")
  T.ok(not ck16.verified, "unverified until bench-tested")
  T.eq(L.display_label(L.BUILTIN.colorkey_miniwash_quad4_mk2_16), "ColorKey MiniWash Quad 4 MKII (16ch) (unverified)", "unverified label")
  T.eq(L.display_label(L.BUILTIN.generic_rgb_3), "Generic RGB (3ch)", "generic has no suffix")

  local ck14 = L.compile(L.BUILTIN.colorkey_miniwash_quad4_mk2_14)
  T.eq(ck14.count, 14, "14ch")
  T.eq(#ck14.pairs, 0, "14ch has no fine channels")

  -- A Custom map compiles to exactly the same shape as the built-in it describes.
  local map = L.format_map(L.BUILTIN.colorkey_miniwash_quad4_mk2_16.channels)
  local chans = assert(L.parse_map(map))
  local custom = L.compile({ channels = chans }, "mover_wash")
  T.eq(custom.count, ck16.count, "custom count matches built-in")
  for role, off in pairs(ck16.roles) do T.eq(custom.roles[role], off, "custom role offset " .. role) end
  T.eq(#custom.extras, #ck16.extras, "same extras")

  local parsed = assert(L.parse_map("Red, green ,blue,strobe:8,fixed:255"))
  T.eq(parsed[1].role, "red", "labels accepted")
  T.eq(parsed[4].default, 8, "role:default parsed")
  T.eq(L.format_map(parsed), "red,green,blue,strobe:8,fixed:255", "format round-trip")

  local _, err = L.parse_map("red,bogus")
  T.like(err, "unknown function 'bogus'", "unknown role reported")
  _, err = L.parse_map("red,strobe:300")
  T.like(err, "not 0%-255", "bad default reported")
  _, err = L.compile({ channels = { { role = "pan" } } }, "color")
  T.like(err, "not available for a Color Par", "pan refused on a par")
  _, err = L.compile({ channels = { { role = "red" }, { role = "red" } } }, "color")
  T.like(err, "already on channel 1", "duplicate role refused")
  _, err = L.compile({ channels = { { role = "dimmer_fine" } } }, "dimmer")
  T.like(err, "needs a 'Dimmer' channel", "fine without coarse refused")
  local fx = L.compile({ channels = { { role = "fixed", default = 1 }, { role = "fixed", default = 2 }, { role = "red" } } }, "color")
  T.ok(fx, "fixed may repeat")
  _, err = L.compile({ channels = { { role = "red" } } }, "mover_wash")
  T.like(err, "needs at least a Pan or Tilt", "mover without pan/tilt refused")

  T.ok(L.check_start(497, 16), "497 + 16 fits exactly")
  local ok, why = L.check_start(498, 16)
  T.ok(not ok, "498 + 16 overflows")
  T.like(why, "would end at 513", "overflow explained")
  T.eq(L.footprint_text(17, 16), "DMX 17-32 (16 ch)", "footprint text")

  local par4 = L.compile(L.BUILTIN.dazzlingstage_rgbw_4)
  T.ok(not par4.has_dimmer, "4ch par has no dimmer (virtual dimmer applies)")
  T.eq(#par4.extras, 0, "4ch par has no Extras")
  local par8 = L.compile(L.BUILTIN.dazzlingstage_rgbw_8)
  T.eq(#par8.extras, 3, "8ch par extras: strobe, program, speed")
  T.ok(par8.supports_color and par8.supports_cct, "par supports color + CCT")
  local dim = L.compile(L.BUILTIN.generic_dimmer_8)
  T.ok(not dim.supports_color and not dim.supports_cct, "dimmer type has no color")
  T.eq(L.types_for_driver("mover")[1].id, "mover_wash", "mover types filtered")
  T.eq(#L.types_for_driver("light"), 4, "light types")
end

---------------------------------------------------------------------------------------------
T.section("color")
do
  local rgbw = L.compile(L.BUILTIN.generic_rgbw_4)
  local drgbw = L.compile(L.BUILTIN.generic_drgbw_5)
  -- sRGB primaries land on their own emitter.
  local r = C.mix(rgbw, { level = 100, x = 0.64, y = 0.33, mode = C.MODE_FULL })
  T.near(r.red, 1, 0.02, "red primary -> red"); T.near(r.green, 0, 0.02, "red primary: no green")
  T.near(r.blue, 0, 0.02, "red primary: no blue"); T.near(r.white, 0, 0.02, "red primary: no white")
  local g = C.mix(rgbw, { level = 100, x = 0.30, y = 0.60, mode = C.MODE_FULL })
  T.near(g.green, 1, 0.02, "green primary -> green")
  local b = C.mix(rgbw, { level = 100, x = 0.15, y = 0.06, mode = C.MODE_FULL })
  T.near(b.blue, 1, 0.02, "blue primary -> blue")
  -- D65 white is all white emitter after extraction.
  local w = C.mix(rgbw, { level = 100, x = 0.3127, y = 0.3290, mode = C.MODE_FULL })
  T.near(w.white, 1, 0.03, "D65 -> white emitter"); T.near(w.red, 0, 0.03, "D65: red extracted")
  local half = C.mix(rgbw, { level = 50, x = 0.3127, y = 0.3290, mode = C.MODE_FULL }, { gamma = 1 })
  T.near(half.white, 0.5, 0.02, "virtual dimmer scales emitters (gamma 1)")
  local halfg = C.mix(rgbw, { level = 50, x = 0.3127, y = 0.3290, mode = C.MODE_FULL })
  T.near(halfg.white, 0.5 ^ 2.2, 0.02, "virtual dimmer default gamma 2.2")
  local wm = C.mix(rgbw, { level = 100, x = 0.3127, y = 0.3290, mode = C.MODE_FULL }, { white_mix = 0 })
  T.near(wm.white, 0, 0.001, "White Mix 0 disables extraction")
  local d = C.mix(drgbw, { level = 40, x = 0.64, y = 0.33, mode = C.MODE_FULL })
  T.near(d.dimmer, 0.4, 0.001, "real dimmer carries brightness (gamma 1 auto)")
  T.near(d.red, 1, 0.02, "real dimmer: emitters at full chroma")
  local off = C.mix(rgbw, { level = 0, x = 0.64, y = 0.33, mode = C.MODE_FULL })
  T.near(off.red, 0, 0, "level 0 -> dark")

  local tw = L.compile(L.BUILTIN.generic_tw_2)
  local warm = C.mix(tw, { level = 100, x = select(1, C.kelvin_to_xy(2700)), y = select(2, C.kelvin_to_xy(2700)), mode = C.MODE_CCT })
  T.near(warm.warm_white, 1, 0.03, "2700K -> all warm"); T.near(warm.cool_white, 0, 0.03, "2700K -> no cool")
  local cx, cy = C.kelvin_to_xy(6500)
  local cool = C.mix(tw, { level = 100, x = cx, y = cy, mode = C.MODE_CCT })
  T.near(cool.cool_white, 1, 0.03, "6500K -> all cool")
  local mx, my = C.kelvin_to_xy(4000)
  local mid = C.mix(tw, { level = 100, x = mx, y = my, mode = C.MODE_CCT })
  T.near(mid.warm_white + mid.cool_white, 1, 0.001, "constant-sum WW/CW")
  T.near(C.xy_to_kelvin(C.kelvin_to_xy(3000)), 3000, 60, "Kelvin round trip 3000")
  T.near(C.xy_to_kelvin(C.kelvin_to_xy(5600)), 5600, 80, "Kelvin round trip 5600")
  T.eq({ C.to_16(1) }, { 255, 255 }, "16-bit full")
  T.eq({ C.to_16(0.5) }, { 128, 0 }, "16-bit half")
end

---------------------------------------------------------------------------------------------
T.section("universe")
do
  local u = Universe.new()
  u:register(10, { name = "Par A", start = 1, count = 4, kind = "light", layout = "RGBW" })
  u:register(11, { name = "Par B", start = 1, count = 4, kind = "light", layout = "RGBW" })
  T.ok(u:is_accepted(10) and u:is_accepted(11), "two pars may share channels")
  T.like(u:conflict_text(10), "shares channels with 'Par B'", "both sides told (A)")
  T.like(u:conflict_text(11), "shares channels with 'Par A'", "both sides told (B)")
  u:update(10, { 0, 1 }, { 100, 20 }, 0, nil, 0)
  u:update(11, { 0, 1 }, { 50, 200 }, 0, nil, 0)
  local data = u:compose()
  T.eq({ data:byte(1, 2) }, { 100, 200 }, "HTP merge of shared slots")

  u:register(12, { name = "Par C", start = 3, count = 4, kind = "light", layout = "RGBW" })
  T.like(u:conflict_text(12), "WARNING: different address", "partial overlap warned")

  u:register(20, { name = "Mover", start = 4, count = 16, kind = "mover", layout = "CK16" })
  T.ok(not u:is_accepted(20), "mover overlapping a par is refused")
  T.like(u:conflict_text(20), "REFUSED: overlaps fixture 'Par A'", "refusal names the incumbent")
  u:update(20, { 0 }, { 255 }, 0, nil, 0)
  data = u:compose()
  T.eq(data:byte(19), 0, "refused mover outputs nothing")

  u:register(20, { name = "Mover", start = 101, count = 16, kind = "mover", layout = "CK16" })
  T.ok(u:is_accepted(20), "moved mover accepted")
  u:register(21, { name = "Mover 2", start = 110, count = 16, kind = "mover", layout = "CK16" })
  T.ok(not u:is_accepted(21), "second mover overlapping first is refused")
  u:register(22, { name = "Par D", start = 116, count = 4, kind = "light", layout = "RGBW" })
  T.ok(not u:is_accepted(22), "par overlapping a mover is refused")
  local changed = u:unregister(20)
  T.ok(u:is_accepted(21), "removing the incumbent frees the refused mover")
  T.ok(#changed >= 1, "unregister reports status changes")

  -- Re-registering keeps the place in line: the incumbent is never displaced by a re-register.
  u:register(21, { name = "Mover 2", start = 110, count = 16, kind = "mover", layout = "CK16" })
  u:register(23, { name = "Mover 3", start = 110, count = 16, kind = "mover", layout = "CK16" })
  u:register(21, { name = "Mover 2", start = 110, count = 16, kind = "mover", layout = "CK16" })
  T.ok(u:is_accepted(21) and not u:is_accepted(23), "re-register keeps incumbency")

  -- Fades.
  local v = Universe.new()
  v:register(1, { name = "F", start = 1, count = 3, kind = "light" })
  v:update(1, { 0 }, { 200 }, 1000, nil, 0)
  v:tick(500)
  T.eq(v:compose():byte(1), 100, "8-bit fade halfway")
  T.ok(not v:tick(1000), "fade done at its end")
  T.eq(v:compose():byte(1), 200, "8-bit fade end")

  -- 16-bit pair fade: coarse must not jump ahead of fine.
  v:register(2, { name = "M", start = 10, count = 2, kind = "mover" })
  v:update(2, { 0, 1 }, { 0, 0 }, 0, { { coarse = 0, fine = 1 } }, 0)
  v:update(2, { 0, 1 }, { 255, 255 }, 1000, { { coarse = 0, fine = 1 } }, 0)
  v:tick(500)
  local mid = v:compose()
  local v16 = mid:byte(10) * 256 + mid:byte(11)
  T.near(v16, 32768, 2, "16-bit pair fade is linear in 16 bits")
  v:tick(1000)
  local fin = v:compose()
  T.eq({ fin:byte(10, 11) }, { 255, 255 }, "16-bit fade end")

  -- Blackout ends on the next update.
  v.blackout = true
  T.eq(v:compose():byte(1), 0, "blackout")
  v:update(1, { 0 }, { 50 }, 0, nil, 2000)
  T.eq(v:compose():byte(1), 50, "any update ends blackout")

  -- Test channel override.
  v.test = { slot = 300, value = 77, until_ms = 7000 }
  T.eq(v:compose():byte(300), 77, "test channel")
  v:tick(7000)
  T.eq(v:compose():byte(300), 0, "test channel expires")

  local _, ch = v:compose()
  T.ok(not ch, "unchanged frame reports no change")
  T.like(u:patch_text(), "REFUSED", "patch text shows refusals")
end

---------------------------------------------------------------------------------------------
T.section("util")
do
  T.eq(U.int(3.0), "3", "int formatting has no .0")
  T.eq(U.split("a,,b", ","), { "a", "", "b" }, "split keeps empties")
  local j = U.json_encode({ slots = { { name = "Home \"x\"", values = { pan = 32768 } } }, n = 1.5 })
  local back = U.json_decode(j)
  T.eq(back.slots[1].name, 'Home "x"', "json string round trip")
  T.eq(back.slots[1].values.pan, 32768, "json number round trip")
  T.eq(back.n, 1.5, "json float")
  local bad, err = U.json_decode("{nope")
  T.ok(bad == nil and err, "bad json reports an error")
end

T.finish()
