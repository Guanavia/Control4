-- dmx_light -- any DMX fixture that does not move (Dimmer, Tunable White, Color Par/Wash,
-- Strobe/Effect), exposed as ONE light_v2 load. Non-light channels go on the load's Extras tab.
--
-- All logic lives in the shared fixture engine (common/fixture.lua). Reduced ALS: the Advanced
-- Lighting agent drives scenes with SET_BRIGHTNESS_TARGET / SET_COLOR_TARGET.

local F = require "fixture"

F.install({ kind = "light", full_als = false, ext = {} })
