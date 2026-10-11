-- dmx_mover -- a moving head as ONE light_v2 load (Dave, 2026-09-24: one fixture = one driver =
-- one load). Intensity and color are the native light. Position, beam, effects and presets are
-- driven by Composer programming (Recall Preset, Set Position, Set Control...) and set up from
-- Composer properties/Actions (Aim, Nudge, presets). Light Extras do not render on this system
-- (2026-10-11), so the Extras setup is still sent but nothing depends on it.
--
-- FULL Advanced Lighting Scene support (not reduced), because ACTIVATE_SCENE carries the scene
-- id: that is what lets a position preset be linked to a lighting scene without a second load.

local U = require "util"
local L = require "layouts"
local F = require "fixture"
local Pos = require "position"
local Presets = require "presets"

local M = {
  pos = Pos.new(),
  presets = Presets.new(),
  selected = 1,          -- preset slot selected on the Extras tab
  save_mode = 3,         -- index into Presets.SAVE_MODES
  pending_name = "",
  current_preset = 0,
}

local PRESETS_KEY = "DMX_MOVER_PRESETS"

local function persist_presets()
  C4:PersistSetValue(PRESETS_KEY, M.presets:data())
end

local function slot_items()
  local items = {}
  for n = 1, Presets.MAX do
    local p = M.presets:get(n)
    items[#items + 1] = { text = n .. ": " .. (p and p.name or "(empty)"), value = U.int(n) }
  end
  return items
end

local function refresh_preset_lists()
  local labels = M.presets:labels(true)
  local current = Properties["Selected Preset"]
  if not current or current == "" or not Presets.slot_from_label(current) then current = labels[1] end
  -- Keep the selection on the same slot even though its label (name) may have changed.
  local slot = Presets.slot_from_label(current) or 1
  current = labels[slot]
  C4:UpdatePropertyList("Selected Preset", table.concat(labels, ","), current)
  Properties["Selected Preset"] = current
  F.set_prop("Scene Links", M.presets:links_text())
end

local function selected_slot()
  return Presets.slot_from_label(Properties["Selected Preset"]) or 1
end

local function apply_limits()
  M.pos:set_limits({
    pan_min = Properties["Pan Min (%)"], pan_max = Properties["Pan Max (%)"],
    tilt_min = Properties["Tilt Min (%)"], tilt_max = Properties["Tilt Max (%)"],
  })
  M.pos.invert.pan = Properties["Invert Pan"] == "Yes"
  M.pos.invert.tilt = Properties["Invert Tilt"] == "Yes"
end

local function position_state()
  local pan, tilt = M.pos:percent()
  return {
    { id = "p_pan", value = U.int(pan) },
    { id = "p_tilt", value = U.int(tilt) },
  }
end

-- Keep the Aim properties showing where the head actually is (after limits, nudges, presets).
local function sync_aim()
  local pan, tilt = M.pos:percent()
  F.set_prop("Aim Pan (%)", U.int(pan))
  F.set_prop("Aim Tilt (%)", U.int(tilt))
end

local function move(fade_ms)
  F.refresh(fade_ms or 0)
  F.push_extras_state(position_state())
  sync_aim()
end

local function label_index(list, label, default)
  for i, item in ipairs(list) do if item.label == label then return i end end
  return default
end

local function link_selected(slot)
  local ok, err = M.presets:link(F.light.last_scene, slot)
  if not ok then F.critical("Link Preset: %s", err) else persist_presets(); refresh_preset_lists() end
end

local function unlink_last()
  if M.presets:unlink(F.light.last_scene) then
    persist_presets(); refresh_preset_lists()
  else
    F.critical("Unlink: the last activated scene (%s) has no preset linked", tostring(F.light.last_scene))
  end
end

---------------------------------------------------------------------------------------------
-- Presets
---------------------------------------------------------------------------------------------
function M.capture()
  return {
    layout = F.layout,
    pos = { pan = M.pos.pan, tilt = M.pos.tilt },
    light = F.light:target_state(),
    extra = F.extra,
  }
end

function M.save(slot, name, mode_index)
  if not F.layout then return nil, "no valid layout" end
  local mode = Presets.SAVE_MODES[mode_index or M.save_mode] or Presets.SAVE_MODES[3]
  local existing = M.presets:get(slot)
  if (not name or U.trim(name) == "") and existing then name = existing.name end
  local p, err = M.presets:save(slot, name, mode.scope, F.default_fade(), M.capture())
  if not p then return nil, err end
  persist_presets()
  refresh_preset_lists()
  F.push_extras_setup()
  F.debug("saved preset %d '%s' (%s)", slot, p.name, mode.label)
  return p
end

-- opts: { fade_ms = override or nil, skip_color = bool, reason = string }
function M.recall(slot, opts)
  opts = opts or {}
  if not F.layout then return nil, "no valid layout" end
  local plan, err = M.presets:plan(slot, F.layout)
  if not plan then
    F.critical("Recall Preset: %s", err)
    return nil, err
  end
  local fade = opts.fade_ms
  if fade == nil or fade < 0 then fade = plan.preset.fade_ms or 0 end
  if plan.pos then
    M.pos:set(plan.pos.pan * 100, plan.pos.tilt * 100)
  end
  for role, v in pairs(plan.roles) do F.extra[role] = v end
  if plan.light and not opts.skip_color then
    -- Through the light_v2 path so the load's level/color and its notifies stay correct. The
    -- light's apply() refreshes the whole footprint, so position rides in the same update.
    local l = plan.light
    F.light:go_with_color(l.level or 0, l.x, l.y, l.mode, fade, fade)
  else
    F.refresh(fade)
  end
  if #plan.skipped > 0 then
    F.debug("preset %d was saved on '%s'; skipped roles this layout lacks: %s", slot,
      tostring(plan.preset.layout_label), table.concat(plan.skipped, ", "))
  end
  M.current_preset = tonumber(slot)
  C4:SetVariable("CURRENT_PRESET", U.int(slot))
  C4:SetVariable("CURRENT_PRESET_NAME", plan.preset.name)
  C4:FireEvent("Preset Recalled")
  F.push_extras_setup_state()
  return true
end

---------------------------------------------------------------------------------------------
-- Hooks into the fixture engine
---------------------------------------------------------------------------------------------
local ext = {}

function ext.on_layout(layout)
  apply_limits()
end

function ext.has_extras() return true end

function ext.compute(out, lay)
  M.pos:write(out, lay)
  -- Pan/Tilt Speed may run fast->slow on some fixtures (layout `invert`).
  local off = lay.roles.pt_speed
  if off ~= nil and lay.channels[off + 1].invert and F.overrides.pt_speed == nil then
    out[off] = 255 - (F.extra.pt_speed or 0)
  end
end

function ext.extras_objects(by)
  local pan, tilt = M.pos:percent()
  local sizes = {}
  for i, s in ipairs(Pos.NUDGE_SIZES) do sizes[i] = { text = s.label, value = U.int(i) } end
  local size_index = 2
  for i, s in ipairs(Pos.NUDGE_SIZES) do if s.pct == M.pos.nudge_pct then size_index = i end end
  local position = {
    { type = "slider", id = "p_pan", label = "Pan (% of travel)", min = 0, max = 100, resolution = 1, value = pan },
    { type = "slider", id = "p_tilt", label = "Tilt (% of travel)", min = 0, max = 100, resolution = 1, value = tilt },
    { type = "list", id = "p_nudge", label = "Nudge Size", items = sizes, value = U.int(size_index) },
    { type = "button", id = "a_left", label = "Nudge Left", text = "Left" },
    { type = "button", id = "a_right", label = "Nudge Right", text = "Right" },
    { type = "button", id = "a_up", label = "Nudge Up", text = "Up" },
    { type = "button", id = "a_down", label = "Nudge Down", text = "Down" },
    { type = "button", id = "a_home", label = "Home (centre of limits)", text = "Home" },
  }
  -- Position controls lead the section; the layout's Pan/Tilt Speed slider follows them.
  for i = #position, 1, -1 do table.insert(by.Position, 1, position[i]) end
  local modes = {}
  for i, m in ipairs(Presets.SAVE_MODES) do modes[i] = { text = m.label, value = U.int(i) } end
  local presets = {
    { type = "list", id = "ps_slot", label = "Preset", items = slot_items(), value = U.int(M.selected) },
    { type = "button", id = "a_recall", label = "Recall Preset", text = "Recall" },
    { type = "textfield", id = "ps_name", label = "Name (for Save)", value = M.pending_name },
    { type = "list", id = "ps_mode", label = "Save", items = modes, value = U.int(M.save_mode) },
    { type = "button", id = "a_save", label = "Save Current Look to Preset", text = "Save" },
    { type = "button", id = "a_link", label = "Link Preset to Last Scene", text = "Link" },
    { type = "button", id = "a_unlink", label = "Unlink Last Scene", text = "Unlink" },
  }
  for _, o in ipairs(presets) do table.insert(by.Presets, o) end
end

local NUDGE_BUTTON = { a_left = "Left", a_right = "Right", a_up = "Up", a_down = "Down" }

function ext.on_extra(id, value)
  if id == "p_pan" then
    M.pos:set(tonumber(value), nil)
    move(200)
  elseif id == "p_tilt" then
    M.pos:set(nil, tonumber(value))
    move(200)
  elseif id == "p_nudge" then
    local s = Pos.NUDGE_SIZES[tonumber(value) or 2]
    if s then M.pos.nudge_pct = s.pct end
    F.push_extras_state({ { id = id, value = value } })
  elseif NUDGE_BUTTON[id] then
    M.pos:nudge(NUDGE_BUTTON[id])
    move(100)
    F.push_extras_state({ { id = id } })
  elseif id == "a_home" then
    M.pos:home()
    move(500)
    F.push_extras_state({ { id = id } })
  elseif id == "ps_slot" then
    M.selected = tonumber(value) or 1
    F.push_extras_state({ { id = id, value = value } })
  elseif id == "ps_name" then
    M.pending_name = value or ""
    F.push_extras_state({ { id = id, value = value } })
  elseif id == "ps_mode" then
    M.save_mode = tonumber(value) or 3
    F.push_extras_state({ { id = id, value = value } })
  elseif id == "a_recall" then
    M.recall(M.selected)
    F.push_extras_state({ { id = id } })
  elseif id == "a_save" then
    local _, err = M.save(M.selected, M.pending_name)
    if err then F.critical("Save Preset: %s", err) end
    M.pending_name = ""
    F.push_extras_state({ { id = id }, { id = "ps_name", value = "" } })
  elseif id == "a_link" then
    link_selected(M.selected)
    F.push_extras_state({ { id = id } })
  elseif id == "a_unlink" then
    unlink_last()
    F.push_extras_state({ { id = id } })
  else
    return false
  end
  F.schedule_persist()
  return true
end

-- A lighting scene fired. If a preset is linked to it, move there (position/beam/effects only:
-- the scene itself owns intensity and color).
function ext.on_scene_activated(scene_id)
  local slot = M.presets.links[scene_id]
  if slot then
    M.recall(slot, { skip_color = true, reason = "scene " .. scene_id })
  end
end

function ext.on_reset(started)
  C4:FireEvent(started and "Reset Started" or "Reset Finished")
end

function ext.snapshot()
  return { pos = M.pos:snapshot(), selected = M.selected, save_mode = M.save_mode }
end

function ext.restore(t)
  M.pos:restore(t.pos)
  M.selected = tonumber(t.selected) or 1
  M.save_mode = tonumber(t.save_mode) or 3
end

function ext.refresh_lists()
  refresh_preset_lists()
end

function ext.late_init()
  M.presets = Presets.new(C4:PersistGetValue(PRESETS_KEY))
  C4:AddVariable("CURRENT_PRESET", "0", "NUMBER")
  C4:AddVariable("CURRENT_PRESET_NAME", "", "STRING")
  refresh_preset_lists()
  -- The properties are the source of truth for nudge size and save mode now.
  M.save_mode = label_index(Presets.SAVE_MODES, Properties["Save Mode"], M.save_mode)
  local n = Pos.NUDGE_SIZES[label_index(Pos.NUDGE_SIZES, Properties["Nudge Size"], 2)]
  M.pos.nudge_pct = n.pct
  sync_aim()
  F.push_extras_setup()
end

M.AIM_FADE_MS = 300

function ext.on_property(name, value)
  if name:match("^Pan M") or name:match("^Tilt M") or name == "Invert Pan" or name == "Invert Tilt" then
    apply_limits()
    move(500)
  elseif name == "Aim Pan (%)" then
    M.pos:set(tonumber(value), nil)
    move(M.AIM_FADE_MS)
  elseif name == "Aim Tilt (%)" then
    M.pos:set(nil, tonumber(value))
    move(M.AIM_FADE_MS)
  elseif name == "Nudge Size" then
    M.pos.nudge_pct = Pos.NUDGE_SIZES[label_index(Pos.NUDGE_SIZES, value, 2)].pct
  elseif name == "Save Mode" then
    M.save_mode = label_index(Presets.SAVE_MODES, value, 3)
  elseif name == "Presets Export/Import" then
    if U.trim(value) == "" then return end
    local imported, err = Presets.import_json(value)
    if not imported then
      F.critical("Presets Import: %s", err)
    else
      M.presets = imported
      persist_presets()
      refresh_preset_lists()
      F.push_extras_setup()
      F.critical("Presets imported: %d preset(s)", #M.presets:labels(false))
    end
    F.set_prop("Presets Export/Import", "")
  end
end

function ext.command(cmd, p)
  if cmd == "Recall Preset" then
    local slot = Presets.slot_from_label(p["Preset"])
    local fade = tonumber(p["Fade (s)"])
    M.recall(slot, { fade_ms = (fade and fade >= 0) and U.round(fade * 1000) or nil })
  elseif cmd == "Home Position" then
    M.pos:home()
    move(tonumber(Properties["Default Fade (ms)"]) or 500)
  elseif cmd == "Nudge Position" then
    M.pos:nudge(p["Direction"], tonumber(p["Amount %"]))
    move(100)
  elseif cmd == "Set Position" then
    M.pos:set(tonumber(p["Pan %"]), tonumber(p["Tilt %"]))
    local fade = tonumber(p["Fade (s)"]) or 0
    move(U.round(fade * 1000))
  elseif cmd == "Reset Motors" then
    F.reset_motors()
  else
    return false
  end
  return true
end

function ext.action(action)
  local slot = selected_slot()
  local NUDGE = { ["NUDGE_LEFT"] = "Left", ["NUDGE_RIGHT"] = "Right", ["NUDGE_UP"] = "Up", ["NUDGE_DOWN"] = "Down" }
  if action == "HOME" then
    M.pos:home()
    move(500)
  elseif NUDGE[action] then
    M.pos:nudge(NUDGE[action])
    move(100)
  elseif action == "LINK_SCENE" then
    link_selected(slot)
  elseif action == "UNLINK_SCENE" then
    unlink_last()
  elseif action == "RECALL_PRESET" then
    M.recall(slot)
  elseif action == "SAVE_PRESET" then
    local _, err = M.save(slot, Properties["Preset Name"])
    if err then F.critical("Save Preset: %s", err) else F.set_prop("Preset Name", "") end
  elseif action == "RENAME_PRESET" then
    if M.presets:rename(slot, Properties["Preset Name"] or "") then
      persist_presets(); refresh_preset_lists(); F.push_extras_setup(); F.set_prop("Preset Name", "")
    else
      F.critical("Rename Preset: slot %d is empty", slot)
    end
  elseif action == "DELETE_PRESET" then
    M.presets:delete(slot)
    persist_presets(); refresh_preset_lists(); F.push_extras_setup()
  elseif action == "EXPORT_PRESETS" then
    F.set_prop("Presets Export/Import", M.presets:export_json())
  else
    return false
  end
  return true
end

function ext.param_list(cmd, param)
  if param == "Preset" then return M.presets:labels(false) end
end

F.install({ kind = "mover", full_als = true, ext = ext })

-- Exposed for the offline harness.
DMX_MOVER = M
