-- testlib.lua -- tiny assertion helpers shared by the unit tests and the harness scenarios.

local T = { passed = 0, failed = 0, failures = {} }

local function show(v)
  if type(v) == "table" then
    local parts = {}
    for i, x in ipairs(v) do parts[i] = show(x) end
    local keyed = {}
    for k, x in pairs(v) do
      if type(k) ~= "number" then keyed[#keyed + 1] = tostring(k) .. "=" .. show(x) end
    end
    table.sort(keyed)
    for _, s in ipairs(keyed) do parts[#parts + 1] = s end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return tostring(v)
end
T.show = show

local function deep_eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function record(ok, name, detail)
  if ok then
    T.passed = T.passed + 1
  else
    T.failed = T.failed + 1
    T.failures[#T.failures + 1] = (T.current or "") .. ": " .. name .. (detail and ("  -- " .. detail) or "")
    print("  FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
  end
  return ok
end

function T.section(name)
  T.current = name
  print("== " .. name)
end

function T.ok(cond, name) return record(cond and true or false, name) end

function T.eq(got, want, name)
  return record(deep_eq(got, want), name, "got " .. show(got) .. ", want " .. show(want))
end

function T.near(got, want, tol, name)
  local ok = type(got) == "number" and math.abs(got - want) <= tol
  return record(ok, name, "got " .. show(got) .. ", want " .. show(want) .. " +/-" .. tol)
end

function T.like(got, pattern, name)
  local ok = type(got) == "string" and string.find(got, pattern) ~= nil
  return record(ok, name, "got " .. show(got) .. ", want match '" .. pattern .. "'")
end

function T.finish()
  print(string.format("\n%d passed, %d failed", T.passed, T.failed))
  if T.failed > 0 then
    for _, f in ipairs(T.failures) do print("  " .. f) end
    os.exit(1)
  end
end

return T
