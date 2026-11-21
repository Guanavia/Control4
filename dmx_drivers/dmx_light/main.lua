-- dmx_light -- any DMX fixture that does not move (Dimmer, Tunable White, Color Par/Wash,
-- Strobe/Effect), exposed as ONE light_v2 load. Non-light channels go on the load's Extras tab.
--
-- All logic lives in the shared fixture engine (common/fixture.lua). Full ALS: the lighting agent
-- pushes scenes (PUSH_SCENE) and fires them (ACTIVATE_SCENE).

local F = require "fixture"

-- FULL ALS (bench, 2026-11-21): under reduced ALS the lighting agent computed a scene's OFF
-- itself and sent SET_BRIGHTNESS_TARGET 100, so scenes could turn the light on but never off.
-- Control4's own DMX Light uses full ALS: the agent pushes every scene (off side included) and the
-- light runs it.
F.install({ kind = "light", full_als = true, ext = {} })
