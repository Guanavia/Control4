-- presets.lua -- mover presets ("looks") and their links to lighting scenes. Pure Lua; the driver
-- persists the table this returns via C4:PersistSetValue.
--
-- A preset records, by SCOPE:
--   position : pan/tilt (absolute fractions) and Pan/Tilt Speed
--   color    : light level and color intent (x, y, mode) -- replayed through the light_v2 path
--              so the load's state and notifies stay correct
--   beam     : zoom, strobe, focus, gobo, prism...
--   effects  : macros, programs, sound
-- Reset is never stored.

local U = require "util"
local L = require "layouts"

local Presets = {}
Presets.__index = Presets

Presets.MAX = 32
Presets.SCOPES = { "position", "color", "beam", "effects" }
Presets.SAVE_MODES = {
  { label = "Position only",     scope = { position = true } },
  { label = "Position + Color",  scope = { position = true, color = true } },
  { label = "Everything",        scope = { position = true, color = true, beam = true, effects = true } },
}

function Presets.new(data)
  local self = setmetatable({}, Presets)
  data = type(data) == "table" and data or {}
  self.slots = {}
  for k, v in pairs(data.slots or {}) do
    local n = tonumber(k)
    if n and n >= 1 and n <= Presets.MAX and type(v) == "table" then self.slots[n] = v end
  end
  self.links = {}
  for k, v in pairs(data.links or {}) do
    local scene, slot = tonumber(k), tonumber(v)
    if scene and slot then self.links[scene] = slot end
  end
  return self
end

function Presets:data()
  local slots, links = {}, {}
  for n, p in pairs(self.slots) do slots[tostring(n)] = p end
  for scene, slot in pairs(self.links) do links[tostring(scene)] = slot end
  return { slots = slots, links = links }
end

local function scope_of_role(role)
  local g = L.ROLES[role] and L.ROLES[role].group
  if g == "position" then return "position" end
  if g == "beam" then return "beam" end
  if g == "effects" or g == "color_extra" then return "effects" end
end

-- capture = { layout, pos = {pan, tilt}, light = {level, x, y, mode}, extra = role -> value }
function Presets:save(slot, name, scope, fade_ms, capture)
  slot = tonumber(slot)
  if not slot or slot < 1 or slot > Presets.MAX then return nil, "slot must be 1-" .. Presets.MAX end
  local p = {
    name = (name and U.trim(name) ~= "") and U.trim(name) or ("Preset " .. slot),
    layout_id = capture.layout.id,
    layout_label = capture.layout.label,
    scope = U.copy(scope),
    fade_ms = tonumber(fade_ms) or 0,
    roles = {},
  }
  if scope.position then p.pos = { pan = capture.pos.pan, tilt = capture.pos.tilt } end
  if scope.color then p.light = U.copy(capture.light) end
  for role, v in pairs(capture.extra or {}) do
    local s = scope_of_role(role)
    if s and scope[s] and role ~= "reset" then p.roles[role] = v end
  end
  self.slots[slot] = p
  return p
end

function Presets:get(slot)
  return self.slots[tonumber(slot)]
end

function Presets:delete(slot)
  slot = tonumber(slot)
  self.slots[slot] = nil
  for scene, s in pairs(self.links) do
    if s == slot then self.links[scene] = nil end
  end
end

function Presets:rename(slot, name)
  local p = self.slots[tonumber(slot)]
  if not p then return false end
  p.name = U.trim(name) ~= "" and U.trim(name) or p.name
  return true
end

-- Work out what a recall should apply on `layout`. Roles the layout lacks are skipped and
-- reported (brief 8.3: layout mismatch).
function Presets:plan(slot, layout)
  local p = self.slots[tonumber(slot)]
  if not p then return nil, "preset " .. tostring(slot) .. " is empty" end
  local plan = { preset = p, roles = {}, skipped = {} }
  if p.scope.position and p.pos then plan.pos = p.pos end
  if p.scope.color and p.light then plan.light = p.light end
  for role, v in pairs(p.roles or {}) do
    if layout.roles[role] ~= nil then plan.roles[role] = v else plan.skipped[#plan.skipped + 1] = role end
  end
  table.sort(plan.skipped)
  plan.other_layout = p.layout_id ~= layout.id
  return plan
end

-- "3: Stage Left" style labels for Composer lists; empty slots omitted unless include_empty.
function Presets:labels(include_empty)
  local out = {}
  for n = 1, Presets.MAX do
    local p = self.slots[n]
    if p then out[#out + 1] = n .. ": " .. p.name
    elseif include_empty then out[#out + 1] = n .. ": (empty)" end
  end
  return out
end

function Presets.slot_from_label(label)
  return tonumber(tostring(label or ""):match("^%s*(%d+)"))
end

function Presets:link(scene_id, slot)
  scene_id, slot = tonumber(scene_id), tonumber(slot)
  if not scene_id then return nil, "no lighting scene has been activated yet" end
  if not self.slots[slot] then return nil, "preset " .. tostring(slot) .. " is empty" end
  self.links[scene_id] = slot
  return true
end

function Presets:unlink(scene_id)
  scene_id = tonumber(scene_id)
  if not scene_id or not self.links[scene_id] then return false end
  self.links[scene_id] = nil
  return true
end

function Presets:links_text()
  local keys = U.sorted_keys(self.links)
  if #keys == 0 then return "No scenes linked." end
  local parts = {}
  for _, scene in ipairs(keys) do
    local slot = self.links[scene]
    local p = self.slots[slot]
    parts[#parts + 1] = string.format("scene %d -> %d: %s", scene, slot, p and p.name or "(deleted)")
  end
  return table.concat(parts, "; ")
end

function Presets:export_json()
  return U.json_encode(self:data())
end

function Presets.import_json(s)
  local data, err = U.json_decode(s)
  if type(data) ~= "table" then return nil, "not valid JSON: " .. tostring(err) end
  return Presets.new(data)
end

return Presets
