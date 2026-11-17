-- protocol.lua -- node <-> fixture messages (brief 3.2). Carried by C4:SendToDevice and received
-- in ExecuteCommand. Every parameter is a string.
--
--   fixture -> node   DMX_REGISTER   FIXTURE_ID NAME START FOOTPRINT KIND LAYOUT
--   fixture -> node   DMX_UPDATE     FIXTURE_ID OFFSETS VALUES FADE_MS [PAIRS]
--   fixture -> node   DMX_UNREGISTER FIXTURE_ID
--   node -> fixture   NODE_STATE     ONLINE CONFLICT NODE_NAME
--   node -> fixture   NODE_RESYNC    (re-register and send OFFSETS=ALL)
--
-- KIND (light|mover) was added to the brief's REGISTER so the node can apply the overlap policy.

local U = require "util"

local P = {}

P.REGISTER = "DMX_REGISTER"
P.UPDATE = "DMX_UPDATE"
P.UNREGISTER = "DMX_UNREGISTER"
P.NODE_STATE = "NODE_STATE"
P.NODE_RESYNC = "NODE_RESYNC"
P.PEER_CHECK = "ARTNET_PEER_CHECK"      -- node -> node duplicate-address check
P.PEER_CLASH = "ARTNET_PEER_CLASH"

-- The control binding that links them. Custom class so nothing else in Composer can bind to it.
P.BINDING_CLASS = "ARTNET_DMX"
-- The node's package file name: Director's identity for the driver. Must match build.sh's
-- PKG_PREFIX + "artnet_node" (the node looks for duplicate copies of itself by it).
P.NODE_C4Z = "lensshift_artnet_node.c4z"

P.FIXTURE_INPUT_BINDING = 1
P.NODE_OUTPUT_BINDING = 1

-- A fixture's SECOND input (dmx_light only): a Control4 DMX gateway such as the Creative Lighting
-- eDIDIO, through its own Control4 driver. Class and messages are those Control4's own DMX Light
-- Driver uses with that gateway (read from its unencrypted driver.lua; facts only, no code):
--   light -> gateway  DMX_LEVEL    LINE DEVICE_ID TIME(ms, the gateway fades) [channel]=value...
--   gateway -> light  LINES_INFO   [line]="DMX"|"DALI"|...   (which lines can take DMX)
--   gateway -> light  NETWORK_STATUS STATUS                  (gateway online)
--   gateway -> light  DMX_LEVELS   [channel]=value           (reply to DMX_QUERY; we never ask)
-- `channel` is the absolute DMX address on that line (UNVERIFIED on hardware).
P.GATEWAY_INPUT_BINDING = 2
P.GATEWAY_CLASS = "DMX_DLG"
P.GW_LEVEL = "DMX_LEVEL"
P.GW_LINES = "LINES_INFO"
P.GW_STATUS = "NETWORK_STATUS"
P.GW_LEVELS = "DMX_LEVELS"

function P.encode_list(list)
  local parts = {}
  for i, v in ipairs(list) do parts[i] = U.int(v) end
  return table.concat(parts, ",")
end

function P.decode_list(s)
  local out = {}
  for _, item in ipairs(U.split(s or "", ",")) do
    local n = tonumber(U.trim(item))
    if n then out[#out + 1] = n end
  end
  return out
end

-- pairs: list of { coarse = off, fine = off } -> "0:1,2:3"
function P.encode_pairs(pairs_list)
  local parts = {}
  for _, p in ipairs(pairs_list or {}) do parts[#parts + 1] = U.int(p.coarse) .. ":" .. U.int(p.fine) end
  return table.concat(parts, ",")
end

function P.decode_pairs(s)
  local out = {}
  for _, item in ipairs(U.split(s or "", ",")) do
    local c, f = item:match("^%s*(%d+)%s*:%s*(%d+)%s*$")
    if c then out[#out + 1] = { coarse = tonumber(c), fine = tonumber(f) } end
  end
  return out
end

return P
