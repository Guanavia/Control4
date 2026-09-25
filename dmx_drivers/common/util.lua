-- util.lua -- small helpers shared by every driver in the set. Pure Lua 5.1, no C4 calls.

local U = {}

function U.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Round half away from zero. math.floor(v + 0.5) is wrong for negatives, and every value this
-- set emits is non-negative anyway, but keep it honest.
function U.round(v)
  if v >= 0 then return math.floor(v + 0.5) end
  return -math.floor(-v + 0.5)
end

-- Integers as strings WITHOUT a trailing ".0". Director's Lua is 5.1/LuaJIT, where tostring(3/1)
-- is "3", but anything formatted from a float must go through here so the wire format never
-- depends on the interpreter.
function U.int(v)
  return string.format("%d", U.round(tonumber(v) or 0))
end

function U.trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function U.split(s, sep)
  local out = {}
  s = tostring(s or "")
  if s == "" then return out end
  local pos = 1
  while true do
    local a, b = string.find(s, sep, pos, true)
    if not a then
      out[#out + 1] = string.sub(s, pos)
      break
    end
    out[#out + 1] = string.sub(s, pos, a - 1)
    pos = b + 1
  end
  return out
end

function U.xml_escape(s)
  s = tostring(s or "")
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;")
  return s
end

function U.toboolean(v)
  if type(v) == "boolean" then return v end
  v = string.lower(tostring(v or ""))
  return v == "true" or v == "1" or v == "yes" or v == "on"
end

function U.copy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = U.copy(v) end
  return c
end

function U.sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return tostring(a) < tostring(b)
  end)
  return keys
end

---------------------------------------------------------------------------------------------
-- Minimal JSON, used only for the Presets Export/Import property. Presets persist as Lua tables
-- through C4:PersistSetValue; JSON exists so a dealer can copy a rig's presets between fixtures.
---------------------------------------------------------------------------------------------

local function json_encode_value(v, out)
  local t = type(v)
  if t == "nil" then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then
      out[#out + 1] = string.format("%d", v)
    else
      out[#out + 1] = string.format("%.6g", v)
    end
  elseif t == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c)
      local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
      return map[c] or string.format("\\u%04x", string.byte(c))
    end) .. '"'
  elseif t == "table" then
    -- An array is a table whose keys are exactly 1..n.
    local n = #v
    local is_array = true
    local count = 0
    for k in pairs(v) do
      count = count + 1
      if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then is_array = false end
    end
    if is_array and count == n and n > 0 then
      out[#out + 1] = "["
      for i = 1, n do
        if i > 1 then out[#out + 1] = "," end
        json_encode_value(v[i], out)
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      for _, k in ipairs(U.sorted_keys(v)) do
        if not first then out[#out + 1] = "," end
        first = false
        json_encode_value(tostring(k), out)
        out[#out + 1] = ":"
        json_encode_value(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else
    error("cannot encode " .. t .. " as JSON")
  end
end

function U.json_encode(v)
  local out = {}
  json_encode_value(v, out)
  return table.concat(out)
end

function U.json_decode(s)
  local pos = 1
  local function ws()
    pos = string.find(s, "[^ \t\r\n]", pos) or (#s + 1)
  end
  local value
  local function str()
    local out = {}
    pos = pos + 1
    while true do
      local c = string.sub(s, pos, pos)
      if c == "" then error("unterminated string") end
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local e = string.sub(s, pos + 1, pos + 1)
        local map = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        if e == "u" then
          local code = tonumber(string.sub(s, pos + 2, pos + 5), 16)
          out[#out + 1] = code < 128 and string.char(code) or "?"
          pos = pos + 6
        else
          out[#out + 1] = map[e] or e
          pos = pos + 2
        end
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
    return table.concat(out)
  end
  value = function()
    ws()
    local c = string.sub(s, pos, pos)
    if c == "{" then
      local obj = {}
      pos = pos + 1
      ws()
      if string.sub(s, pos, pos) == "}" then pos = pos + 1; return obj end
      while true do
        ws()
        local k = str()
        ws()
        if string.sub(s, pos, pos) ~= ":" then error("expected ':' at " .. pos) end
        pos = pos + 1
        obj[k] = value()
        ws()
        local d = string.sub(s, pos, pos)
        pos = pos + 1
        if d == "}" then return obj end
        if d ~= "," then error("expected ',' or '}' at " .. (pos - 1)) end
      end
    elseif c == "[" then
      local arr = {}
      pos = pos + 1
      ws()
      if string.sub(s, pos, pos) == "]" then pos = pos + 1; return arr end
      while true do
        arr[#arr + 1] = value()
        ws()
        local d = string.sub(s, pos, pos)
        pos = pos + 1
        if d == "]" then return arr end
        if d ~= "," then error("expected ',' or ']' at " .. (pos - 1)) end
      end
    elseif c == '"' then
      return str()
    elseif string.sub(s, pos, pos + 3) == "true" then
      pos = pos + 4; return true
    elseif string.sub(s, pos, pos + 4) == "false" then
      pos = pos + 5; return false
    elseif string.sub(s, pos, pos + 3) == "null" then
      pos = pos + 4; return nil
    else
      local num = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then error("unexpected character at " .. pos) end
      pos = pos + #num
      return tonumber(num)
    end
  end
  local ok, result = pcall(value)
  if not ok then return nil, result end
  return result
end

return U
