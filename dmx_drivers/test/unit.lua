-- unit.lua -- off-controller unit tests for the pure modules.
-- Run from dmx_drivers/:  luajit test/unit.lua
-- (LuaJIT because Director runs driver.lua with jit="1": same 5.1 semantics as the controller.)

package.path = "common/?.lua;artnet_node/?.lua;dmx_mover/?.lua;test/?.lua;" .. package.path

local T = require "testlib"
local U = require "util"
local A = require "artnet"
local L = require "layouts"
local C = require "color"

-- A light layout from a channel map, the way a light is configured since 2026-10-10. The maps are
-- exactly the old generic/par built-ins, so the color checks below test the same layouts.
local function lay(map, type_id)
  return assert(L.compile({ channels = assert(L.parse_map(map)) }, type_id))
end
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
  T.eq(L.display_label({ label = "Generic", generic = true }), "Generic", "generic has no suffix")

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
  _, err = L.compile({ channels = { { role = "pan" } } }, "rgbw")
  T.like(err, "not available for Fixture Type RGBW", "pan refused on a par")
  _, err = L.compile({ channels = { { role = "red" }, { role = "red" } } }, "rgbw")
  T.like(err, "already on channel 1", "duplicate role refused")
  _, err = L.compile({ channels = { { role = "dimmer_fine" } } }, "dimmer")
  T.like(err, "needs a 'Dimmer' channel", "fine without coarse refused")
  local fx = L.compile({ channels = { { role = "fixed", default = 1 }, { role = "fixed", default = 2 }, { role = "red" } } }, "rgbw")
  T.ok(fx, "fixed may repeat")
  _, err = L.compile({ channels = { { role = "red" } } }, "mover_wash")
  T.like(err, "needs at least a Pan or Tilt", "mover without pan/tilt refused")

  T.ok(L.check_start(497, 16), "497 + 16 fits exactly")
  local ok, why = L.check_start(498, 16)
  T.ok(not ok, "498 + 16 overflows")
  T.like(why, "would end at 513", "overflow explained")
  T.eq(L.footprint_text(17, 16), "DMX 17-32 (16 ch)", "footprint text")

  local par4 = lay("red,green,blue,white", "rgbw")
  T.ok(not par4.has_dimmer, "4ch par has no dimmer (virtual dimmer applies)")
  T.eq(#par4.extras, 0, "4ch par has no Extras")
  local par8 = lay("dimmer,red,green,blue,white,strobe,program,macro_speed", "rgbw")
  T.eq(#par8.extras, 3, "8ch par extras: strobe, program, speed")
  T.ok(par8.supports_color and par8.supports_cct, "par supports color + CCT")
  local dim = lay("dimmer", "dimmer")
  T.ok(not dim.supports_color and not dim.supports_cct, "dimmer type has no color")
  T.eq(L.types_for_driver("mover")[1].id, "mover_wash", "mover types filtered")
  T.eq(#L.types_for_driver("light"), 7, "light types")
  -- Type fit: what keeps a map across a type change.
  T.ok(L.map_fits(L.type_by_id("rgbw"), L.parse_map("dimmer,red,green,blue,white,strobe")), "RGBW map fits RGBW")
  T.ok(not L.map_fits(L.type_by_id("rgb_tw"), L.parse_map("warm_white,cool_white")), "white-only map does not fit RGB + TW")
  T.ok(not L.map_fits(L.type_by_id("rgb"), L.parse_map("red,green,blue,white")), "white channel not allowed on RGB")
  T.ok(L.map_fits(L.type_by_id("tunable_white"), L.parse_map("dimmer,cct")), "dimmer + CCT channel is Tunable White")
  T.eq(L.legacy_type("Color Par / Wash", L.parse_map("red,green,blue")).id, "rgb", "legacy color par without white -> RGB")
  T.eq(L.legacy_type("Color Par / Wash", L.parse_map("red,green,blue,warm_white,cool_white")).id, "rgb_tw", "legacy -> RGB + TW")
  T.eq(L.legacy_type("Strobe / Effect", nil).id, "rgbw", "legacy strobe/effect with no map -> RGBW")
  T.eq(L.legacy_type("RGBW", nil), nil, "current labels are not legacy")
end

---------------------------------------------------------------------------------------------
T.section("color")
do
  local rgbw = lay("red,green,blue,white", "rgbw")
  local drgbw = lay("dimmer,red,green,blue,white", "rgbw")
  -- sRGB primaries land on their own emitter.
  local r = C.mix(rgbw, { level = 100, x = 0.64, y = 0.33, mode = C.MODE_FULL })
  T.near(r.red, 1, 0.02, "red primary -> red"); T.near(r.green, 0, 0.02, "red primary: no green")
  T.near(r.blue, 0, 0.02, "red primary: no blue"); T.near(r.white, 0, 0.02, "red primary: no white")
  local g = C.mix(rgbw, { level = 100, x = 0.30, y = 0.60, mode = C.MODE_FULL })
  T.near(g.green, 1, 0.02, "green primary -> green")
  local b = C.mix(rgbw, { level = 100, x = 0.15, y = 0.06, mode = C.MODE_FULL })
  T.near(b.blue, 1, 0.02, "blue primary -> blue")
  -- Max Brightness OFF = the original accurate mix: D65 white is all white emitter after extraction.
  local ACC = { max_brightness = false }
  local w = C.mix(rgbw, { level = 100, x = 0.3127, y = 0.3290, mode = C.MODE_FULL }, ACC)
  T.near(w.white, 1, 0.03, "Off: D65 -> white emitter"); T.near(w.red, 0, 0.03, "Off: D65 red extracted")
  -- Max Brightness ON (default): pure white runs all four emitters at full.
  local wb = C.mix(rgbw, { level = 100, x = 0.3127, y = 0.3290, mode = C.MODE_FULL })
  T.ok(wb.white > 0.99 and wb.red > 0.99 and wb.green > 0.99 and wb.blue > 0.99, "On: D65 -> R, G, B and W all full")
  -- ON preserves chromaticity (W counts as R=G=B white), never exceeds full, never dims, and
  -- leaves saturated colours byte-identical. Sweep the gamut.
  local worst_hue, dimmer, over, changed_sat = 0, 0, 0, 0
  for _, pt in ipairs({ {0.64,0.33}, {0.30,0.60}, {0.15,0.06}, {0.3127,0.3290}, {0.25,0.25}, {0.40,0.40},
      {0.35,0.30}, {0.28,0.33}, {0.45,0.41}, {0.20,0.30}, {0.33,0.45}, {0.50,0.35}, {0.30,0.32} }) do
    local st = { level = 100, x = pt[1], y = pt[2], mode = C.MODE_FULL }
    local on, acc = C.mix(rgbw, st), C.mix(rgbw, st, ACC)
    local r0, g0, b0 = C.xy_to_rgb(pt[1], pt[2])
    local er, eg, eb = on.red + on.white, on.green + on.white, on.blue + on.white
    local m = math.max(er, eg, eb)
    worst_hue = math.max(worst_hue, math.abs(er / m - r0), math.abs(eg / m - g0), math.abs(eb / m - b0))
    for _, v in pairs(on) do if v > 1 + 1e-9 then over = over + 1 end end
    local lum = function(t) return t.red + t.green + t.blue + 3 * t.white end
    if lum(on) < lum(acc) - 1e-9 then dimmer = dimmer + 1 end
    if math.min(r0, g0, b0) < 0.02 then
      for k, v in pairs(acc) do if math.abs(on[k] - v) > 0.004 then changed_sat = changed_sat + 1 end end
    end
  end
  T.ok(worst_hue < 1e-6, "On keeps every colour's chromaticity (worst error " .. worst_hue .. ")")
  T.eq(over, 0, "On never drives an emitter past full")
  T.eq(dimmer, 0, "On is never dimmer than Off")
  T.eq(changed_sat, 0, "On leaves saturated colours unchanged")
  local half = C.mix(rgbw, { level = 50, x = 0.3127, y = 0.3290, mode = C.MODE_FULL }, { gamma = 1 })
  T.near(half.white, 0.5, 0.02, "virtual dimmer scales emitters (gamma 1)")
  local halfg = C.mix(rgbw, { level = 50, x = 0.3127, y = 0.3290, mode = C.MODE_FULL })
  T.near(halfg.white, 0.5 ^ 2.2, 0.02, "virtual dimmer default gamma 2.2")
  local wm = C.mix(rgbw, { level = 100, x = 0.3127, y = 0.3290, mode = C.MODE_FULL }, { white_mix = 0, max_brightness = false })
  T.near(wm.white, 0, 0.001, "White Mix 0 disables extraction")
  local d = C.mix(drgbw, { level = 40, x = 0.64, y = 0.33, mode = C.MODE_FULL })
  T.near(d.dimmer, 0.4, 0.001, "real dimmer carries brightness (gamma 1 auto)")
  T.near(d.red, 1, 0.02, "real dimmer: emitters at full chroma")
  local off = C.mix(rgbw, { level = 0, x = 0.64, y = 0.33, mode = C.MODE_FULL })
  T.near(off.red, 0, 0, "level 0 -> dark")

  local tw = lay("warm_white,cool_white", "tunable_white")
  local warm = C.mix(tw, { level = 100, x = select(1, C.kelvin_to_xy(2700)), y = select(2, C.kelvin_to_xy(2700)), mode = C.MODE_CCT })
  T.near(warm.warm_white, 1, 0.03, "2700K -> all warm"); T.near(warm.cool_white, 0, 0.03, "2700K -> no cool")
  local cx, cy = C.kelvin_to_xy(6500)
  local cool = C.mix(tw, { level = 100, x = cx, y = cy, mode = C.MODE_CCT })
  T.near(cool.cool_white, 1, 0.03, "6500K -> all cool")
  local mx, my = C.kelvin_to_xy(4000)
  local mid = C.mix(tw, { level = 100, x = mx, y = my, mode = C.MODE_CCT }, { max_brightness = false })
  T.near(mid.warm_white + mid.cool_white, 1, 0.001, "Off: constant-sum WW/CW")
  local midb = C.mix(tw, { level = 100, x = mx, y = my, mode = C.MODE_CCT })
  T.near(math.max(midb.warm_white, midb.cool_white), 1, 0.001, "On: WW/CW mid-range runs the stronger LED at full")
  T.near(midb.warm_white / midb.cool_white, mid.warm_white / mid.cool_white, 1e-9, "On: same warm/cool ratio (same temperature)")
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
  v.test = { [300] = 77, [301] = 5 }
  T.eq(v:compose():byte(300), 77, "test channel")
  T.eq(v:compose():byte(301), 5, "second test channel")
  v:tick(60000)
  T.eq(v:compose():byte(300), 77, "test channel holds")
  v.test = nil
  T.eq(v:compose():byte(300), 0, "test channel released")

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

---------------------------------------------------------------------------------------------
T.section("pixels: map text, compile, expansion")
do
  local function px(map, type_id)
    local c, p = L.parse_map(map)
    assert(c, p)
    return assert(L.compile({ channels = c, pixels = p }, type_id or "rgbw")), c, p
  end
  -- The Alcon 11260 3ft: 18 RGBW pixels, nothing else.
  local alcon, c, p = px("18x(red,green,blue,white)")
  T.eq({ #c, p.count, p.at, #p.channels }, { 0, 18, 0, 4 }, "18x(rgbw) parses to 0 fixture channels + 18 x 4")
  T.eq(alcon.count, 72, "footprint is 72 channels")
  T.eq({ alcon.pixel_count, alcon.pixel_size, alcon.pixel_at }, { 18, 4, 0 }, "pixel shape recorded")
  T.eq(alcon.channels[5].role, "red", "ch 5 is pixel 2's red")
  T.eq(alcon.channels[5].pixel, 2, "ch 5 belongs to pixel 2")
  T.eq(alcon.channels[72].role, "white", "ch 72 is the last pixel's white")
  T.eq(#alcon.offsets.red, 18, "red occupies 18 offsets")
  T.eq(alcon.roles.red, 0, "first occurrence is pixel 1")
  T.ok(alcon.has_rgb and alcon.has_white and alcon.supports_color, "capabilities from the pixel group")
  T.eq(#alcon.extras, 0, "no Extras on a plain RGBW pixel bar")
  T.eq(L.format_map(c, p), "18x(red,green,blue,white)", "format round-trip")
  T.eq(L.footprint_text(1, 72, 18), "DMX 1-72 (72 ch, 18 pixels)", "footprint names the pixels")
  T.eq(L.summary(alcon), "Ch 1-72 18 pixels x 4 ch: Red, Green, Blue, White", "summary")

  -- Master channels around the pixels, defaults inside and outside the group.
  local bar, c2, p2 = px("dimmer,strobe,4x(red,green,blue,fixed:7),program", "rgb")
  T.eq(p2.at, 2, "two fixture channels before the pixels")
  T.eq(bar.count, 19, "2 + 4x4 + 1")
  T.eq({ bar.channels[1].role, bar.channels[2].role, bar.channels[3].role, bar.channels[19].role },
    { "dimmer", "strobe", "red", "program" }, "wire order: masters, pixels, tail")
  T.eq(bar.channels[18].default, 7, "a fixed value repeats in every pixel")
  T.eq(L.format_map(c2, p2), "dimmer,strobe,4x(red,green,blue,fixed:7),program", "format keeps position + defaults")
  T.eq(L.summary(bar), "Ch 1 Dimmer | Ch 2 Strobe/Shutter | Ch 3-18 4 pixels x 4 ch: Red, Green, Blue, Fixed 7 | Ch 19 Program/Auto", "summary numbers the tail after the pixels")
  T.eq(#bar.extras, 2, "strobe + program are Extras/Set Control once, not per pixel")

  -- Spellings a dealer might type.
  local s1 = L.format_map(L.parse_map(" Dimmer , 6 X ( Red , Green , Blue ) "))
  T.eq(s1, "dimmer,6x(red,green,blue)", "spaces, labels and an upper-case X accepted")
  T.eq(L.format_map(L.parse_map("6*(red,green,blue)")), "6x(red,green,blue)", "6*(...) accepted")
  -- One pixel is no pixels: inlined, and the original text format comes back.
  local c1, p1 = L.parse_map("dimmer,1x(red,green,blue,white),strobe")
  T.eq(p1, nil, "1x(...) means no pixels")
  T.eq(L.format_map(c1), "dimmer,red,green,blue,white,strobe", "1x(...) inlined in place")

  -- 16-bit dimmer per pixel: one node fade pair per pixel.
  local fine = px("10x(dimmer,dimmer_fine)", "dimmer")
  T.eq(#fine.pairs, 10, "one coarse/fine pair per pixel")
  T.eq({ fine.pairs[3].coarse, fine.pairs[3].fine }, { 4, 5 }, "pair 3 at offsets 4/5")

  -- Refusals, each explained.
  local function refuses(map, pattern, label, type_id)
    local c3, p3 = L.parse_map(map)
    local e3 = p3
    if c3 then
      local ok3
      ok3, e3 = L.compile({ channels = c3, pixels = p3 }, type_id or "rgbw")
      if ok3 then e3 = nil end
    end
    T.like(e3 or "(accepted)", pattern, label)
  end
  refuses("130x(red,green,blue,white)", "520 channels, more than a DMX universe", "over 512 refused with the arithmetic")
  refuses("2x(red,green),3x(blue)", "only one pixel group", "two groups refused")
  refuses("dimmer18x(red)", "separate the pixel group", "missing comma refused")
  refuses("4x()", "pixel group has no channels", "empty group refused")
  refuses("4x(red,green", "pixel group not understood", "unclosed group refused")
  refuses("dimmer,2x(red,green,blue,white,dimmer)", "pixel channel 5: 'Dimmer' is already on channel 1", "a role in both places refused")
  refuses("dimmer,4x(red,green,blue,white,dimmer_fine)", "must both be pixel channels or both fixture", "split coarse/fine refused")
  refuses("2x(red,green,blue,white,pan)", "pixel channel 5: 'Pan' is not available", "type rules apply inside the group")
  refuses("4x(red,green,blue)", "not available for Fixture Type", "RGB pixels need an RGB type, not Single Color", "dimmer")
  local _, merr = L.compile({ channels = {}, pixels = { count = 2, at = 0, channels = { { role = "red" } } } }, "mover_wash")
  T.like(merr, "moving head cannot have pixels", "movers refuse pixels")
  -- The NEEDS rule sees the pixel group: an RGBW type is satisfied by RGBW pixels.
  T.ok(L.map_fits(L.type_by_id("rgbw"), {}, { channels = L.parse_map("red,green,blue,white") }), "pixel group satisfies the type")
  T.ok(not L.map_fits(L.type_by_id("rgbw"), {}, { channels = L.parse_map("red,green,blue") }), "a missing white still fails RGBW")
end

T.section("pixels: turning pixels on guesses the repeating group")
do
  local function split(map, type_id)
    local f, p = L.split_for_pixels(assert(L.parse_map(map)), L.type_by_id(type_id or "rgbw"))
    p.count = 6
    return L.format_map(f, p)
  end
  T.eq(split("red,green,blue,white"), "6x(red,green,blue,white)", "a 4ch par map becomes 6 RGBW pixels")
  T.eq(split("dimmer,red,green,blue,white,strobe,program,macro_speed"),
    "dimmer,6x(red,green,blue,white),strobe,program,macro_speed", "masters stay put around the color run")
  T.eq(split("red,green,blue,amber,uv", "rgb"), "6x(red,green,blue,amber,uv)", "Amber/UV count as pixel color")
  T.eq(split("dimmer,dimmer_fine,strobe", "dimmer"), "6x(dimmer,dimmer_fine),strobe", "single color: the dimmer repeats, with its fine")
  T.eq(split("dimmer,strobe"), "dimmer,strobe,6x(red,green,blue,white)", "no color run: the type's starting map becomes the pixel")
  -- And back: flatten undoes the split exactly.
  local f, p = L.split_for_pixels(L.parse_map("dimmer,red,green,blue,white,strobe"), L.type_by_id("rgbw"))
  T.eq(L.format_map(L.flatten(f, p)), "dimmer,red,green,blue,white,strobe", "flatten restores the original order")
end

T.finish()
