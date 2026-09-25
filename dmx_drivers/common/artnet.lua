-- artnet.lua -- Art-Net 4 packet construction. Pure Lua 5.1: string.char and integer math only,
-- no bit library (Director does not guarantee one).
--
-- ArtDmx layout (Art-Net 4 spec, "ArtDmx"):
--   0  8  ID        "Art-Net\0"
--   8  2  OpCode    0x5000, LITTLE-endian -> bytes 00 50
--  10  2  ProtVer   14, big-endian -> 00 0E
--  12  1  Sequence  1..255 rolling (0 would disable sequencing)
--  13  1  Physical  0
--  14  1  SubUni    (SubNet << 4) | Universe
--  15  1  Net       Net & 0x7F
--  16  2  Length    big-endian, always 512 here
--  18 512 Data

local A = {}

A.PORT = 6454
A.ID = "Art-Net\0"
A.OP_DMX = 0x5000
A.OP_POLL = 0x2000
A.OP_POLL_REPLY = 0x2100
A.PROTOCOL_VERSION = 14
A.SLOTS = 512

local function lo(n) return n % 256 end
local function hi(n) return math.floor(n / 256) % 256 end

function A.valid_address(net, subnet, universe)
  return net >= 0 and net <= 127 and subnet >= 0 and subnet <= 15 and universe >= 0 and universe <= 15
end

-- 15-bit Port-Address: Net(7) | SubNet(4) | Universe(4).
function A.port_address(net, subnet, universe)
  return net * 256 + subnet * 16 + universe
end

function A.next_sequence(seq)
  seq = (seq or 0) + 1
  if seq > 255 then seq = 1 end
  return seq
end

-- slots: a 512-byte string (the frame is cached as a string by the node, see universe.lua).
function A.pack_dmx(net, subnet, universe, sequence, slots)
  assert(#slots == A.SLOTS, "ArtDmx data must be exactly 512 slots, got " .. #slots)
  assert(A.valid_address(net, subnet, universe), "invalid Art-Net port address")
  return A.ID
    .. string.char(lo(A.OP_DMX), hi(A.OP_DMX))      -- 00 50
    .. string.char(0, A.PROTOCOL_VERSION)           -- 00 0E
    .. string.char(sequence, 0)                     -- sequence, physical
    .. string.char(subnet * 16 + universe, net)     -- SubUni, Net
    .. string.char(hi(A.SLOTS), lo(A.SLOTS))        -- 02 00
    .. slots
end

-- Turn a 1..512 array of numbers into the 512-byte data string. Chunked because string.char with
-- 512 arguments is legal but pointlessly close to interpreter argument limits.
function A.slots_to_string(values)
  local parts = {}
  for base = 1, A.SLOTS, 64 do
    local chunk = {}
    for i = base, base + 63 do
      local v = values[i] or 0
      if v < 0 then v = 0 elseif v > 255 then v = 255 end
      chunk[#chunk + 1] = math.floor(v + 0.5)
    end
    parts[#parts + 1] = string.char(unpack(chunk))
  end
  return table.concat(parts)
end

-- Decode an Art-Net packet. Used by the node to recognise replies and, mainly, by the offline
-- test harness to check exactly what the driver put on the wire.
function A.parse(packet)
  if type(packet) ~= "string" or #packet < 12 or string.sub(packet, 1, 8) ~= A.ID then
    return nil, "not an Art-Net packet"
  end
  local op = string.byte(packet, 9) + string.byte(packet, 10) * 256
  local result = { opcode = op }
  if op == A.OP_DMX then
    if #packet < 18 then return nil, "short ArtDmx" end
    result.protver = string.byte(packet, 11) * 256 + string.byte(packet, 12)
    result.sequence = string.byte(packet, 13)
    result.physical = string.byte(packet, 14)
    local subuni = string.byte(packet, 15)
    result.subnet = math.floor(subuni / 16)
    result.universe = subuni % 16
    result.net = string.byte(packet, 16)
    result.length = string.byte(packet, 17) * 256 + string.byte(packet, 18)
    result.data = string.sub(packet, 19, 18 + result.length)
    if #result.data ~= result.length then return nil, "ArtDmx length field does not match data" end
  end
  return result
end

-- Value of DMX slot n (1-based) in a parsed ArtDmx.
function A.slot(parsed, n)
  return string.byte(parsed.data, n) or 0
end

return A
