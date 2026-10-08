-- artnet_node -- owns ONE Art-Net universe on ONE node. Merges every bound fixture's channels
-- into one frame, runs all fades, and sends ArtDmx unicast to the node on UDP 6454.
--
-- No proxy: it is a gateway, like the Vibrant DALI/DMX gateway. Fixtures bind to its "Fixtures"
-- control output (class ARTNET_DMX) in Connections and talk to it with C4:SendToDevice.

local U = require "util"
local A = require "artnet"
local P = require "protocol"
local Universe = require "universe"

local N = {
  universe = Universe.new(),
  seq = 0,
  last_send = 0,
  frames_sent = 0,
  dirty = false,
  engine = nil,
  keepalive = nil,
  health = "unknown",     -- unknown | reachable | unreachable
  net_status = "not configured",
  peers_clash = nil,
  init_done = false,
}

local NET_BINDING = 6001
local PING_INTERVAL_MS = 30000

local function now() return C4:GetTime() end

local function debug(fmt, ...)
  if Properties["Debug Mode"] == "On" then
    print("[artnet_node] " .. (select("#", ...) > 0 and string.format(fmt, ...) or fmt))
  end
end

local function critical(fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  C4:ErrorLog("[artnet_node] " .. msg)
  print("[artnet_node] " .. msg)
end

local function set_prop(name, value)
  if Properties[name] ~= nil and Properties[name] ~= value then
    C4:UpdateProperty(name, value)
    Properties[name] = value
  end
end

local function address()
  local ip = U.trim(Properties["Node IP Address"])
  local net = U.clamp(tonumber(Properties["Art-Net Net"]) or 0, 0, 127)
  local sub = U.clamp(tonumber(Properties["Art-Net Sub-Net"]) or 0, 0, 15)
  local uni = U.clamp(tonumber(Properties["Art-Net Universe"]) or 0, 0, 15)
  return ip, net, sub, uni
end

local function valid_ip(ip)
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return false end
  for _, o in ipairs({ a, b, c, d }) do if tonumber(o) > 255 then return false end end
  -- Broadcast is not allowed by Art-Net 4 for ArtDmx; last octet 0/255 is a network/broadcast.
  if tonumber(d) == 0 or tonumber(d) == 255 then return false end
  return true
end

local function frame_interval()
  local fps = U.clamp(tonumber(Properties["Max Frame Rate (fps)"]) or 30, 10, 44)
  return math.ceil(1000 / fps)
end

local function keepalive_ms()
  return U.clamp(tonumber(Properties["Keepalive (ms)"]) or 1000, 500, 4000)
end

---------------------------------------------------------------------------------------------
-- Status
---------------------------------------------------------------------------------------------
function N.update_status()
  local ip, net, sub, uni = address()
  local parts = {}
  if not valid_ip(ip) then
    parts[#parts + 1] = "NOT SENDING: set Node IP Address (a static IP on the Control4 LAN)"
  else
    local reach = ({ reachable = "node answers ping", unreachable = "NODE NOT REACHABLE (no ping reply)",
      unknown = "reachability not yet checked" })[N.health]
    parts[#parts + 1] = string.format("Sending to %s, Net %d / Sub-Net %d / Universe %d (%s)", ip, net, sub, uni, reach)
  end
  local ok, refused = N.universe:counts()
  parts[#parts + 1] = string.format("%d fixture(s)%s", ok, refused > 0 and string.format(", %d REFUSED", refused) or "")
  if N.universe.blackout then parts[#parts + 1] = "BLACKOUT (until any fixture changes)" end
  local t = N.test_text()
  if t then parts[#parts + 1] = t end
  if N.peers_clash then parts[#parts + 1] = "WARNING: " .. N.peers_clash end
  local text = table.concat(parts, " | ")
  if text ~= N.last_status then
    N.last_status = text
    set_prop("Status", text)
    if text:find("NOT") or text:find("REFUSED") or text:find("WARNING") or text:find("TEST ACTIVE") then critical("%s", text) else debug("%s", text) end
  end
  set_prop("Patch", N.universe:patch_text())
end

---------------------------------------------------------------------------------------------
-- Channel Test: drive N consecutive channels by hand from live sliders. Overrides fixtures (not
-- HTP) so a channel can be pulled DOWN as well as up, and holds until Test Channels is Off.
---------------------------------------------------------------------------------------------
N.TEST_MAX = 16

local function test_count()
  return U.clamp(tonumber(Properties["Test Channels"]) or 0, 0, N.TEST_MAX)
end

function N.apply_test()
  local count = test_count()
  local start = U.clamp(tonumber(Properties["Test Start Channel"]) or 1, 1, 512)
  for i = 1, N.TEST_MAX do
    C4:SetPropertyAttribs("Test Ch " .. i, i <= count and 0 or 1)
  end
  C4:SetPropertyAttribs("Test Start Channel", count > 0 and 0 or 1)
  if count == 0 then
    N.universe.test = nil
    set_prop("Test Addresses", "Test off")
  else
    local test, names = {}, {}
    for i = 1, count do
      local slot = start + i - 1
      if slot <= 512 then
        test[slot] = U.clamp(tonumber(Properties["Test Ch " .. i]) or 0, 0, 255)
        names[#names + 1] = string.format("Ch %d = DMX %d", i, slot)
      else
        names[#names + 1] = string.format("Ch %d = past 512, ignored", i)
      end
    end
    N.universe.test = test
    set_prop("Test Addresses", table.concat(names, ", "))
  end
  N.universe:compose()
  N.send_frame("channel test")
  N.update_status()
end

function N.test_text()
  local count = test_count()
  if count == 0 or not N.universe.test then return nil end
  local start = U.clamp(tonumber(Properties["Test Start Channel"]) or 1, 1, 512)
  local last = math.min(start + count - 1, 512)
  return string.format("CHANNEL TEST ACTIVE on DMX %d%s (overrides fixtures; set Test Channels to Off)",
    start, last > start and ("-" .. last) or "")
end

---------------------------------------------------------------------------------------------
-- Network
---------------------------------------------------------------------------------------------
function N.connect()
  local ip = address()
  if N.connected_ip then
    pcall(function() C4:NetDisconnect(NET_BINDING, A.PORT) end)
    N.connected_ip = nil
  end
  if not valid_ip(ip) then
    N.net_status = "not configured"
    N.update_status()
    return
  end
  local ok, err = pcall(function()
    C4:CreateNetworkConnection(NET_BINDING, ip)
    C4:NetConnect(NET_BINDING, A.PORT, "UDP")
  end)
  if not ok then
    critical("could not open UDP to %s:%d: %s", ip, A.PORT, tostring(err))
    N.net_status = "error"
  else
    N.connected_ip = ip
    N.net_status = "open"
    debug("UDP opened to %s:%d", ip, A.PORT)
    -- Establish output straight away rather than waiting for the first keepalive.
    N.universe:compose()
    N.send_frame("connected")
  end
  N.health = "unknown"
  N.ping()
  N.update_status()
end

function N.send_frame(reason)
  local ip, net, sub, uni = address()
  if not N.connected_ip then return end
  N.seq = A.next_sequence(N.seq)
  local pkt = A.pack_dmx(net, sub, uni, N.seq, N.universe.frame)
  C4:SendToNetwork(NET_BINDING, A.PORT, pkt)
  N.last_send = now()
  N.frames_sent = N.frames_sent + 1
end

-- ICMP ping as the health check (C4Ping, OS 3.3.1+). Art-Net is UDP, so a send "succeeds" whether
-- or not anything is listening; ping is the only honest reachability signal. If the API is not
-- available, reachability stays "unknown" -- it is never reported as a failure without evidence.
function N.ping()
  local ip = address()
  if not valid_ip(ip) or not C4.CreatePingClient then return end
  local ok, err = pcall(function()
    local client = C4:CreatePingClient()
    client:SetOnResult(function(_, success)
      local was = N.health
      N.health = success and "reachable" or "unreachable"
      if was ~= N.health then
        N.update_status()
        N.broadcast_state()
      end
    end)
    client:Ping(ip, 2)
    N.ping_client = client
  end)
  if not ok then debug("ping unavailable: %s", tostring(err)) end
end

---------------------------------------------------------------------------------------------
-- Frame engine
---------------------------------------------------------------------------------------------
function N.engine_tick()
  local t = now()
  local active = N.universe:tick(t)
  local _, changed = N.universe:compose()
  if changed or N.dirty then
    N.send_frame("change")
    N.dirty = false
  end
  if not active and N.engine then
    N.engine:Cancel()
    N.engine = nil
  end
end

-- Called after anything changes the universe. Sends now if the frame-rate cap allows, otherwise
-- lets the engine timer pick it up; the engine only runs while fades are active.
function N.pump()
  local t = now()
  local active = N.universe:tick(t)
  local _, changed = N.universe:compose()
  if changed then
    if t - N.last_send >= frame_interval() then
      N.send_frame("change")
    else
      N.dirty = true
    end
  end
  if (active or N.dirty) and not N.engine then
    -- Repeating timer (bRepeat = true). Never rely on :Reset() restarting a fired one-shot:
    -- that is how the YAS209 state poll silently died.
    N.engine = C4:SetTimer(frame_interval(), function() N.engine_tick() end, true)
  end
end

function N.start_keepalive()
  if N.keepalive then N.keepalive:Cancel() end
  local period = math.max(100, math.floor(keepalive_ms() / 4))
  N.keepalive = C4:SetTimer(period, function()
    if now() - N.last_send >= keepalive_ms() then N.send_frame("keepalive") end
  end, true)
  N.health_timer = N.health_timer or C4:SetTimer(PING_INTERVAL_MS, function() N.ping() end, true)
end

---------------------------------------------------------------------------------------------
-- Fixture messages
---------------------------------------------------------------------------------------------
function N.node_name()
  local name = C4.GetDeviceDisplayName and C4:GetDeviceDisplayName(C4:GetDeviceID()) or nil
  return (name and name ~= "") and name or "Art-Net Node"
end

function N.tell(id)
  C4:SendToDevice(id, P.NODE_STATE, {
    ONLINE = N.health ~= "unreachable" and N.connected_ip ~= nil and "true" or "false",
    ACCEPTED = N.universe:is_accepted(id) and "true" or "false",
    CONFLICT = N.universe:conflict_text(id),
    NODE_NAME = N.node_name(),
  })
end

function N.broadcast_state()
  for id in pairs(N.universe.fixtures) do N.tell(id) end
end

function N.resync_all(reason)
  local bound = C4:GetBoundConsumerDevices(0, P.NODE_OUTPUT_BINDING)
  local ids = {}
  if type(bound) == "table" then
    for k, v in pairs(bound) do
      local id = tonumber(k) or tonumber(v)
      if id then ids[#ids + 1] = id end
    end
  end
  for id in pairs(N.universe.fixtures) do ids[#ids + 1] = id end
  local seen = {}
  for _, id in ipairs(ids) do
    if not seen[id] then
      seen[id] = true
      C4:SendToDevice(id, P.NODE_RESYNC, { NODE_ID = U.int(C4:GetDeviceID()) })
    end
  end
  debug("resync requested from %d fixture(s): %s", #ids, reason or "")
end

function N.on_register(p)
  local id = tonumber(p.FIXTURE_ID)
  local start, count = tonumber(p.START), tonumber(p.FOOTPRINT)
  if not id or not start or not count then
    critical("DMX_REGISTER with missing fields from %s", tostring(p.FIXTURE_ID))
    return
  end
  if start < 1 or count < 1 or start + count - 1 > 512 then
    critical("fixture %s asked for DMX %d-%d, outside the universe; ignored", tostring(p.NAME), start, start + count - 1)
    return
  end
  local changed = N.universe:register(id, { name = p.NAME, start = start, count = count, kind = p.KIND, layout = p.LAYOUT })
  N.tell(id)
  for _, other in ipairs(changed) do if other ~= id then N.tell(other) end end
  N.update_status()
  N.pump()
end

function N.on_update(p)
  local id = tonumber(p.FIXTURE_ID)
  if not id or not N.universe.fixtures[id] then
    -- Unknown fixture (e.g. this node restarted): ask it to register first.
    if id then C4:SendToDevice(id, P.NODE_RESYNC, { NODE_ID = U.int(C4:GetDeviceID()) }) end
    return
  end
  local values = P.decode_list(p.VALUES)
  local offsets
  if p.OFFSETS == "ALL" then
    offsets = {}
    for i = 1, #values do offsets[i] = i - 1 end
  else
    offsets = P.decode_list(p.OFFSETS)
  end
  N.universe:update(id, offsets, values, tonumber(p.FADE_MS) or 0, P.decode_pairs(p.PAIRS), now())
  N.pump()
end

function N.on_unregister(p)
  local id = tonumber(p.FIXTURE_ID)
  if not id then return end
  local changed = N.universe:unregister(id)
  for _, other in ipairs(changed) do N.tell(other) end
  N.update_status()
  N.pump()
end

---------------------------------------------------------------------------------------------
-- Duplicate-node check: a node merges at most two sources, so exactly one artnet_node may target
-- a given node + port address. Peers compare notes over SendToDevice.
---------------------------------------------------------------------------------------------
function N.peer_ids()
  local ids = {}
  local ok, devs = pcall(function() return C4:GetDevicesByC4iName("artnet_node.c4z") end)
  if ok and type(devs) == "table" then
    for k, v in pairs(devs) do
      local id = tonumber(k) or tonumber(v)
      if id and id ~= C4:GetDeviceID() then ids[#ids + 1] = id end
    end
  end
  return ids
end

function N.check_peers()
  local ip, net, sub, uni = address()
  N.peers_clash = nil
  if not valid_ip(ip) then return end
  for _, id in ipairs(N.peer_ids()) do
    C4:SendToDevice(id, P.PEER_CHECK, { FROM = U.int(C4:GetDeviceID()), IP = ip,
      NET = U.int(net), SUB = U.int(sub), UNI = U.int(uni), NAME = N.node_name() })
  end
end

function N.on_peer_check(p)
  local ip, net, sub, uni = address()
  if p.IP == ip and tonumber(p.NET) == net and tonumber(p.SUB) == sub and tonumber(p.UNI) == uni then
    N.peers_clash = string.format("'%s' also sends to %s on the same Net/Sub-Net/Universe. Only one driver may drive a node's universe.", p.NAME or "another Art-Net Node driver", ip)
    C4:SendToDevice(tonumber(p.FROM), P.PEER_CLASH, { NAME = N.node_name(), IP = ip })
    N.update_status()
  end
end

function N.on_peer_clash(p)
  N.peers_clash = string.format("'%s' also sends to %s on the same Net/Sub-Net/Universe. Only one driver may drive a node's universe.", p.NAME or "another Art-Net Node driver", p.IP or "")
  N.update_status()
end

---------------------------------------------------------------------------------------------
-- Director entry points
---------------------------------------------------------------------------------------------
function OnDriverInit()
end

function OnDriverLateInit()
  critical("loaded %s", "@BUILD@")
  N.init_done = true
  -- A channel test never survives a reload: it would silently override the fixtures.
  set_prop("Test Channels", "Off")
  N.connect()
  N.apply_test()
  N.start_keepalive()
  N.check_peers()
  N.update_status()
  -- Fixtures may have loaded before the node: ask every bound fixture to (re)register.
  N.resync_all("node loaded")
end

function OnDriverDestroyed()
  if N.engine then N.engine:Cancel() end
  if N.keepalive then N.keepalive:Cancel() end
  if N.health_timer then N.health_timer:Cancel() end
end

function OnPropertyChanged(name)
  if not N.init_done then return end
  if name == "Node IP Address" or name == "Art-Net Net" or name == "Art-Net Sub-Net" or name == "Art-Net Universe" then
    N.connect()
    N.check_peers()
    N.send_frame("address changed")
    N.broadcast_state()
  elseif name == "Keepalive (ms)" then
    N.start_keepalive()
  elseif name == "Test Channels" or name == "Test Start Channel" or name:match("^Test Ch %d+$") then
    N.apply_test()
    return
  elseif name == "Max Frame Rate (fps)" then
    if N.engine then N.engine:Cancel(); N.engine = nil end
    N.pump()
  end
  N.update_status()
end

function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
  if idBinding ~= P.NODE_OUTPUT_BINDING then return end
  local id = tonumber(otherDeviceId)
  if not id then return end
  if bIsBound then
    C4:SendToDevice(id, P.NODE_RESYNC, { NODE_ID = U.int(C4:GetDeviceID()) })
  else
    N.on_unregister({ FIXTURE_ID = U.int(id) })
  end
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
  if idBinding == NET_BINDING then
    N.net_status = tostring(strStatus)
    debug("network binding %d port %s: %s", idBinding, tostring(nPort), tostring(strStatus))
  end
end

function ReceivedFromNetwork(idBinding, nPort, strData)
  -- Nothing is expected back on this connection; Art-Net nodes reply to ArtPoll, which this
  -- driver does not send. Logged in debug only.
  debug("received %d byte(s) on binding %d", #(strData or ""), idBinding)
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  local ok, err = pcall(function()
    if strCommand == P.REGISTER then N.on_register(tParams)
    elseif strCommand == P.UPDATE then N.on_update(tParams)
    elseif strCommand == P.UNREGISTER then N.on_unregister(tParams)
    elseif strCommand == P.PEER_CHECK then N.on_peer_check(tParams)
    elseif strCommand == P.PEER_CLASH then N.on_peer_clash(tParams)
    elseif strCommand == "LUA_ACTION" then
      local action = tParams.ACTION
      if action == "RESEND" then
        N.universe:compose()
        N.send_frame("resend action")
      elseif action == "BLACKOUT" then
        N.universe.blackout = true
        N.pump()
        N.send_frame("blackout")
        N.update_status()
      elseif action == "RESYNC" then
        N.resync_all("Re-sync action")
      end
    end
  end)
  if not ok then critical("command %s failed: %s", strCommand, tostring(err)) end
end

-- Exposed for the offline harness.
ARTNET_NODE = N
