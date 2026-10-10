-- extras.lua -- builds the light_v2 Extras tab XML (EXTRAS_SETUP_CHANGED / EXTRAS_STATE_CHANGED).
--
-- Snap One's own Extras library is not published, so this builds the XML directly, as working
-- third-party light drivers do. CONFIRMED against Snap One's own sample (docs-driverworks
-- sample_drivers/thermostat_v2/"get extras setup.xml") and shipping drivers: the
-- <extras_setup>/<extra>/<section label>/<object type id label command value hidden> shape, list
-- items, and that a BUTTON's text is a CHILD ELEMENT <buttontext>, not an attribute (we had it as
-- an attribute: bench 2026-10-10, no Extras tab appeared).
-- STILL UNVERIFIED: the slider. Snap One's ExtrasSlider class has min/max/resolution fields but no
-- published XML shows whether they are attributes or child elements, so both are written; a
-- reader looking for either finds it. Settle it on the bench, then drop the unused form.
--
-- The UI sends each object's `command` as a proxy command with a `value` (and possibly `id`)
-- parameter. Every object here uses a command of the form EXTRA_<id>, so the handler knows which
-- object fired without relying on an `id` parameter being present.

local U = require "util"

local X = {}

X.COMMAND_PREFIX = "EXTRA_"

local function attr(name, value)
  if value == nil then return "" end
  return " " .. name .. '="' .. U.xml_escape(value) .. '"'
end

local function object_xml(o)
  local head = '<object' .. attr("type", o.type) .. attr("id", o.id) .. attr("label", o.label)
    .. attr("command", X.COMMAND_PREFIX .. o.id) .. attr("hidden", o.hidden and "true" or nil)
  if o.type == "slider" then
    local min, max, res = U.int(o.min or 0), U.int(o.max or 255), U.int(o.resolution or 1)
    return head .. attr("min", min) .. attr("max", max) .. attr("resolution", res)
      .. attr("value", U.int(o.value or 0)) .. ">"
      .. "<min>" .. min .. "</min><max>" .. max .. "</max><resolution>" .. res .. "</resolution>"
      .. "</object>"
  elseif o.type == "button" then
    return head .. "><buttontext>" .. U.xml_escape(o.text or o.label) .. "</buttontext></object>"
  elseif o.type == "list" then
    local items = {}
    for _, it in ipairs(o.items or {}) do
      items[#items + 1] = "<item" .. attr("text", it.text) .. attr("value", it.value) .. "/>"
    end
    return head .. attr("value", o.value) .. '><list maxselections="1" minselections="1">'
      .. table.concat(items) .. "</list></object>"
  elseif o.type == "text" then
    return head .. attr("value", o.value or "") .. "/>"
  elseif o.type == "textfield" then
    return head .. attr("value", o.value or "") .. attr("mode", o.mode or "normal") .. "/>"
  end
  error("unknown extras object type " .. tostring(o.type))
end

-- sections: list of { label = "...", objects = { {type,id,label,...}, ... } }
function X.setup_xml(sections)
  local parts = { "<extras_setup><extra>" }
  for _, s in ipairs(sections) do
    if #s.objects > 0 then
      parts[#parts + 1] = "<section" .. attr("label", s.label) .. ">"
      for _, o in ipairs(s.objects) do parts[#parts + 1] = object_xml(o) end
      parts[#parts + 1] = "</section>"
    end
  end
  parts[#parts + 1] = "</extra></extras_setup>"
  return table.concat(parts)
end

-- values: list of { id = ..., value = ... } -- only the objects that changed need be included.
function X.state_xml(values)
  local parts = { "<extras_state><extra>" }
  for _, v in ipairs(values) do
    parts[#parts + 1] = "<object" .. attr("id", v.id) .. attr("value", v.value ~= nil and tostring(v.value) or nil)
      .. attr("hidden", v.hidden ~= nil and (v.hidden and "true" or "false") or nil) .. "/>"
  end
  parts[#parts + 1] = "</extra></extras_state>"
  return table.concat(parts)
end

-- Proxy command name -> object id, or nil if the command is not an Extras command.
function X.object_for_command(cmd)
  if type(cmd) == "string" and cmd:sub(1, #X.COMMAND_PREFIX) == X.COMMAND_PREFIX then
    return cmd:sub(#X.COMMAND_PREFIX + 1)
  end
end

return X
