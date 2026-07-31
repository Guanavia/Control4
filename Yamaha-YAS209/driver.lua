--[[
  Yamaha Soundbar (umbrella) - Control4 DriverWorks driver
  Model: YAS-209 (Linkplay/WiiMu module).  See research/LINKPLAY_RE.md.

  Control methods (Control Method property): IR / IP / Serial.  IP is implemented:
    * Volume / mute              -> UPnP SOAP on :49152 (no auth).
    * Power / input select        -> Linkplay httpapi on :443 (mutual-TLS, bundled
                                     client cert).  Requires Control Method = IP.

  Confirmed commands (captured + validated on real hardware, research/LINKPLAY_RE.md):
    Power ON  : httpapi YAMAHA_DATA_SET:{"power saving":"1"}
    Power OFF : httpapi YAMAHA_DATA_SET:{"power saving":"0"}   (standby)
    Input     : httpapi setPlayerCmd:switchmode:HDMI|bluetooth|optical  (TV=optical)
    Volume    : UPnP RenderingControl SetVolume (0-100)  |  Mute: SetMute

  STATUS (2026-07-27): BOTH control surfaces VALIDATED on the real bar via a real director.
    * UPnP half  — volume/mute read live.
    * httpapi    — mutual-TLS handshake SUCCEEDS over the raw SSL network connection
                   (binding 6002) with the PLAIN key; getStatusEx returned HTTP 200, and
                   POWER ON/OFF + INPUT SELECT are confirmed working on the bar.
                   C4:url() was abandoned because it cannot present a client certificate.
    Remaining gap: state FEEDBACK.  Power/input are write-only right now — the driver
    reports back what it last sent, not what the bar is actually doing, so anything that
    changes the bar outside Control4 (remote, front panel, app) drifts the UI.
    All soundbar testing is on real hardware — a virtual director cannot reach the bar.

  Bindings: 5001 receiver proxy | 6001 network (UPnP monitor) | 6002 SSL httpapi (:443)
            7000 room end-point | 2000 HDMI out | 3000..3004 input sources
]]

-------------------------------------------------
-- CONSTANTS
-------------------------------------------------
-- IR emitter output.  MUST be 2, not 1: in a DriverWorks driver id 1 is the reserved serial
-- binding, and an IR connection placed there never appears in Composer's Connections view.
local IR_BINDING       = 2
local RECEIVER_BINDING = 5001
local NETWORK_BINDING  = 6001
local SSL_BINDING      = 6002      -- Linkplay httpapi, mutual-TLS (driver.xml classname SSL)
local OUTPUT_BINDING   = 7000
local UPNP_PORT        = 49152
local HTTPAPI_PORT     = 443
local HTTPAPI_TIMEOUT_MS = 10000
-- Settling gap between one httpapi request finishing and the next starting; see HttpApiFinish.
local PUMP_GAP_MS = 250

-- Passphrase for the bundled private key.  Only consulted when driver.xml marks
-- <private_key protected="True"> -- the shipped build uses a PLAIN key, so Director
-- never calls GetPrivateKeyPassword.  Kept wired so switching to an encrypted key is a
-- one-attribute XML change (build with ENCRYPT_KEY=1) with no Lua edit.
local HTTPAPI_KEY_PASSWORD = "yas209-linkplay"

-- IR code ids.  These are Control4's CONVENTIONAL receiver ir-code ids, identical across every
-- receiver IR driver in the catalog, so they are reused here rather than invented.  They must
-- match <irsection> in driver.xml.
local IR = {
  -- CAPTURED from the real YAS-209 remote (2026-07-30) -- authoritative for this bar.
  POWER_TOGGLE = 103, VOLUME_UP = 106, VOLUME_DOWN = 107, MUTE_TOGGLE = 139, INFO = 120,
  TV_INPUT = 1002, HDMI = 1001, BLUETOOTH = 1003, NET = 1004,
  MOVIE = 1007, MUSIC = 1009, SPORTS = 1010, GAME = 1011, TV_SURROUND = 1008, STEREO = 1012,
  SURROUND_3D = 1006, CLEAR_VOICE = 1005, BASS_EXTENSION = 1000,
  BASS_UP = 143, BASS_DOWN = 144,
  -- From the YSP-1000 donor, kept: the remote has only toggles for these, but discrete is what
  -- the proxy and automation need, and all four are hardware-confirmed on this bar.
  POWER_ON = 101, POWER_OFF = 102, MUTE_ON = 137, MUTE_OFF = 138,
}

local INPUT_IR = {
  [3000] = IR.TV_INPUT, [3001] = IR.HDMI, [3003] = IR.BLUETOOTH, [3004] = IR.NET,
}

-- Control4 input connection id -> Linkplay switchmode value.
-- There is deliberately no separate "Optical In": the bar has ONE optical/ARC input and
-- the Linkplay layer exposes ONE switchmode ("optical") for it, which is what the TV
-- input already selects.  A second entry would have been a duplicate of 3000.
-- What the "Current Input" PROPERTY shows. These are the user-facing names and MUST match the
-- <connectionname> values in driver.xml. The property used to display INPUT_MAP's value instead,
-- which is the Linkplay WIRE string -- so selecting TV reported "optical". That is an internal
-- protocol token, and worse, it names a physically separate input this bar does not have: the
-- optical jack is part of the TV input, not a selectable source of its own (which is exactly why
-- the standalone "Optical In" connection was removed earlier). Never surface a wire value in a
-- property a dealer reads.
local INPUT_NAME = {
  [3000] = "TV (ARC / Optical)",
  [3001] = "HDMI In",
  [3003] = "Bluetooth",
  [3004] = "Network / Streaming",
}

local INPUT_MAP = {
  [3000] = "optical",    -- TV (ARC / optical)
  [3001] = "HDMI",       -- HDMI In
  [3003] = "bluetooth",  -- Bluetooth
  [3004] = "wifi",       -- Network / streaming
}
local INPUT_ORDER = { 3000, 3001, 3003, 3004 }
local SWITCH_TO_CONN = { optical = 3000, HDMI = 3001, bluetooth = 3003, wifi = 3004 }

-- getPlayerStatus "mode" (Linkplay source code) -> our input connection id.
-- LEARNED ON HARDWARE 2026-07-27 via the "Learn Input Codes" sweep (each input was selected
-- by us, then read back, so each number is self-identifying).  HDMI = 49 was the one value
-- that could not have been guessed from Linkplay's published codes.
local MODE_TO_CONN = {
  ["43"] = 3000,  -- Optical == the YAS-209's TV input   [LEARNED]
  ["49"] = 3001,  -- HDMI In                             [LEARNED]
  ["41"] = 3003,  -- Bluetooth                           [LEARNED]
  ["0"]  = 3004,  -- Network/wifi selected but IDLE      [LEARNED - see MODE_ZERO note]
  -- Network/streaming while something is actually playing.  These are Linkplay's documented
  -- codes and were NOT observed during the sweep, because playback status was "stop"
  -- throughout -- the bar reported 0 for wifi rather than a per-service code.
  ["1"]  = 3004,  -- AirPlay
  ["2"]  = 3004,  -- DLNA
  ["10"] = 3004,  -- wiimu playlist
  ["31"] = 3004,  -- Spotify
}

-- MODE_ZERO: "0" is Linkplay's generic idle/no-source value, not a real source id.  We map
-- it to Network because that is what the sweep showed when wifi was selected and stopped --
-- but it is the one entry that could be reported in some OTHER idle condition, standby being
-- the obvious candidate.  So mode 0 is NOT trusted while the bar is known to be off; see
-- ApplyInputState's caller.  Anything reporting 0 in standby would otherwise show the room
-- as sitting on Network, which is worse than showing nothing.
local MODE_IDLE = "0"

-- Yamaha settings surface, from the YAMAHA_DATA_GET capture (2026-07-27).  Each entry maps a
-- Composer property to its Yamaha key; writes go out as YAMAHA_DATA_SET:{"<key>":"<value>"}.
-- enc/dec translate between the Composer-facing wording and the wire value.
local function OnOffEnc(v) return (v == "On") and "1" or "0" end
local function OnOffDec(v) return (v == "1") and "On" or "Off" end
local function Identity(v) return v end

-- NOTE: "sound program" is deliberately NOT here.  It is the receiver proxy's SURROUND mode,
-- so it belongs in the device's control UI (Surround section), not in the properties list --
-- see SURROUND_MODES.  These three have no home in the receiver proxy (it models surround as a
-- single mode list, with no concept of independent DSP toggles), so properties are the right
-- place for them.
-- Subwoofer Boost limits.  LEARNED ON HARDWARE 2026-07-27 (writes of 5 and -5 were both
-- refused, the bar holding 4 / -4) and independently confirmed against the Yamaha app.  Signed,
-- centred on 0 = flat.  Declared HERE, above its first use in SubEnc: it previously lived down
-- beside the learn sweep, which made it a nil GLOBAL at this point and would have thrown the
-- moment anyone set the property.  Re-run Learn Subwoofer Range for other models/firmware.
local SUBWOOFER_RANGE = { min = -4, max = 4 }

-- Clamp to the learned subwoofer range on the way OUT.  Composer's RANGED_INTEGER already
-- bounds the UI, but programming and Actions can set a property to anything, and the bar
-- silently refuses out-of-range writes rather than erroring -- so an unclamped value would
-- look accepted and do nothing.
local function SubEnc(v)
  local n = tonumber(v) or 0
  if n < SUBWOOFER_RANGE.min then n = SUBWOOFER_RANGE.min end
  if n > SUBWOOFER_RANGE.max then n = SUBWOOFER_RANGE.max end
  return tostring(n)
end

local SETTING_PROPS = {
  { prop = "Subwoofer Boost", key = "subwoofer volume", enc = SubEnc,  dec = Identity },
  { prop = "3D Surround",    key = "3D surround",    enc = OnOffEnc, dec = OnOffDec },
  { prop = "Clear Voice",    key = "clear voice",    enc = OnOffEnc, dec = OnOffDec },
  { prop = "Bass Extension", key = "bass extension", enc = OnOffEnc, dec = OnOffDec },
  -- HDMI-CEC. Exposed 2026-07-31 to test whether the bar's CEC is fighting the TV's input
  -- selection: it sits on the TV's ARC port, and CEC One Touch Play lets a waking device pull
  -- the TV to its own input. There is no setting for this in the Yamaha app, so the driver is
  -- the only way to reach it.
  -- READ is confirmed (the bar reports "HDMI Control":"1"). WRITE IS UNPROVEN - every other
  -- Yamaha setting writes through this same verb, but this key has never been written. If it
  -- does not stick, the readback in the state poll will show it reverting.
  { prop = "HDMI Control (CEC)", key = "HDMI Control", enc = OnOffEnc, dec = OnOffDec },
}

-- Read from the bar and recorded, but NOT surfaced as properties. These are diagnostics, and a
-- diagnostic belongs in "Get Device Status", not in the configuration surface: as a property it
-- only refreshed on the 30s poll, was visible only if someone opened the Properties tab, and
-- could not drive programming (this driver declares no property-changed events).
--
-- "Audio Stream" is the format the bar is decoding (PCM / Dolby / DTS). It answers exactly one
-- useful question -- is the TV bitstreaming over ARC or downmixing everything to PCM, which is
-- the usual reason surround "does not work" -- and nothing else. UNVERIFIED: every capture so
-- far has read "PCM"; whether it ever changes has not been tested on this bar.
--
-- "Master volume" was a "Yamaha Volume" property and was REMOVED entirely (2026-07-30): it does
-- not track. It read 24 across IP volume writes and IR presses alike, which is how the IR
-- verification came to score working codes as failures. It is not even kept here, because a
-- number that silently stops matching reality is worse than no number.
local STATUS_ONLY = {
  { label = "Audio Stream", key = "Audio Stream" },
  -- Read-only ON PURPOSE. Relevant to the "does it wake after a long idle" question, but its
  -- VOCABULARY is unknown - it reads "0" and nothing establishes whether that is a boolean or a
  -- duration index. Writing a value we have not decoded is the guesswork this driver avoids, so
  -- it is reported and not written until someone learns the range by readback.
  { label = "Auto Power Standby", key = "Auto Power Stby" },
  { label = "Network Standby",    key = "NET Standby" },
}




-- SURROUND, as the receiver proxy models it: a list of {name, id} declared in driver.xml's
-- <capabilities><surround_modes>, selected by SET_SURROUND_MODE(SurroundMode=<id>) and reported
-- back with SURROUND_MODE_CHANGED.  The ids here MUST match driver.xml exactly.  Underneath,
-- each one is just a Yamaha "sound program" string -- all six confirmed on hardware.
local SURROUND_MODES = {
  { id = 1, name = "Movie",      program = "movie" },
  { id = 2, name = "Music",      program = "music" },
  { id = 3, name = "Sports",     program = "sports" },
  { id = 4, name = "Game",       program = "game" },
  { id = 5, name = "TV Program", program = "tv program" },
  { id = 6, name = "Stereo",     program = "stereo" },
}
-- Each of the six programs has its OWN key on the remote, so IR selects a program directly
-- rather than cycling -- the same exactness the IP path has.
local PROGRAM_IR = {
  ["movie"] = "MOVIE", ["music"] = "MUSIC", ["sports"] = "SPORTS",
  ["game"] = "GAME", ["tv program"] = "TV_SURROUND", ["stereo"] = "STEREO",
}

local PROGRAM_TO_SURROUND_ID, SURROUND_ID_TO_PROGRAM = {}, {}
for _, m in ipairs(SURROUND_MODES) do
  PROGRAM_TO_SURROUND_ID[m.program] = m.id
  SURROUND_ID_TO_PROGRAM[m.id] = m.program
end

local RC = "urn:schemas-upnp-org:service:RenderingControl:1"
local RC_CTRL = "/upnp/control/rendercontrol1"

local LOG_LEVEL = { ALERT=0, ERROR=1, WARNING=2, INFO=3, TRACE=4, DEBUG=5 }

-------------------------------------------------
-- STATE
-------------------------------------------------
local gLogLevel   = LOG_LEVEL.WARNING
local gLogMode    = "Off"
local gCtrlMethod = "IR"   -- normalised to "IR" or "IP"; see OnPropertyChanged
local gAddress    = ""
local gPollSecs   = 3

local gConnected  = false
local gPollFails  = 0
local gPollTimer  = nil
local gStatePollSecs  = 30    -- httpapi power/input read-back; 0 = disabled
local gStatePollTimer = nil
local gUnknownModes   = {}    -- modes already reported, so the log warns once each
local gUnhandledProxyCmds = {}  -- proxy commands already reported as unimplemented (once each)
-- What Director says is bound, per binding id. nil = never reported, which for the IR binding is
-- itself the diagnosis: OnBindingChanged fires on bind AND unbind, so silence means unattached.
local gBindings     = {}
local gBindingClass = {}
-- Last value the BAR reported for each Yamaha setting key.  This is what stops an echo loop:
-- reading a setting updates its Composer property, which fires OnPropertyChanged, which would
-- otherwise send the value straight back.  A write only goes out when the new property value
-- differs from what the device last told us.
local gDeviceSettings = {}
local gInitDone       = false  -- suppresses writes during the initial property sweep

local gPower      = nil      -- boolean (best-effort; only known over IP)
local gYxcVolume  = nil      -- 0..100 (UPnP)
local gMute       = nil      -- boolean
local gInputSw    = nil      -- switchmode string

-- httpapi (SSL socket) transport state
local gCertPresent = false   -- bundled PEM passed its sanity check (advisory only)
local gCertInfo    = nil     -- human-readable summary for the diagnostics action
local gSslCreated  = false   -- CreateNetworkConnection has bound 6002 to an address
local gSslAddr     = nil     -- the address it was bound to (re-bind if IP changes)
local gSslOnline   = false   -- socket is up and the mutual-TLS handshake succeeded
local gQueue       = {}      -- pending { command, cb } requests
local gInFlight    = nil     -- { command, cb, sent, rx } currently on the wire
local gReqTimer    = nil
local gCooldown    = false   -- settling gap after a request; see HttpApiFinish

-------------------------------------------------
-- LOGGING
-------------------------------------------------
local function Log(level, msg, ...)
  if gLogMode == "Off" then return end
  if level > gLogLevel then return end
  local ok, s = pcall(string.format, msg, ...)
  if not ok then s = tostring(msg) end
  local line = string.format("[YAMAHASB][%s] %s", os.date("%H:%M:%S"), s)
  if gLogMode == "Print" or gLogMode == "Print and Log" then print(line) end
  -- C4:ErrorLog is the DriverWorks director-log fn (C4:Log does not exist); pcall so a
  -- logging-API mismatch can never crash the driver.
  if gLogMode == "Log" or gLogMode == "Print and Log" then pcall(function() C4:ErrorLog(line) end) end
end
-- Misconfiguration must NOT be silenceable.  Log Mode defaults to "Off", which gates every
-- Log() call above -- so a driver that cannot possibly work (no IP address) said nothing at all
-- unless someone had already turned logging on.  That is backwards: the louder the problem, the
-- less likely logging is enabled.  LogCritical bypasses the gate entirely.
local function LogCritical(msg, ...)
  local ok, s = pcall(string.format, msg, ...)
  if not ok then s = tostring(msg) end
  pcall(function() C4:ErrorLog("[YAMAHASB] " .. s) end)
  print("[YAMAHASB][CRITICAL] " .. s)
end

local function LogDebug(m,...)   Log(LOG_LEVEL.DEBUG,m,...) end
local function LogTrace(m,...)   Log(LOG_LEVEL.TRACE,m,...) end
local function LogInfo(m,...)    Log(LOG_LEVEL.INFO,m,...) end
local function LogWarning(m,...) Log(LOG_LEVEL.WARNING,m,...) end
local function LogError(m,...)   Log(LOG_LEVEL.ERROR,m,...) end

-------------------------------------------------
-- SMALL HELPERS
-------------------------------------------------
local function trim(s) return (tostring(s or "")):gsub("^%s*(.-)%s*$", "%1") end
local function UpdateProp(name, value) pcall(function() C4:UpdateProperty(name, tostring(value)) end) end
local function DeviceAddress() if gAddress and gAddress ~= "" then return gAddress end return nil end

local function UrlEncode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- The five read-only STATUS properties. Over IR the driver has no readback at all, so anything
-- shown here would be the last value it SENT, not the bar's state -- a guess wearing the clothes
-- of a status field. With IR now the default, that would be the first thing a new installer saw.
-- So under IR they read a placeholder that names the reason, and they are only populated when
-- Control Method = IP.
local STATUS_PROPS = { "Connected", "Power State", "Current Input", "Current Volume", "Muted" }
local STATUS_IR_TEXT = "IP Control Only - see documentation"

-- Write a status property, but only when it can mean something.
local function UpdateStatus(name, value)
  if gCtrlMethod ~= "IP" then return end
  UpdateProp(name, value)
end

-- Called whenever Control Method changes: park them under IR, blank them for IP so the polls
-- fill them with real values rather than leaving yesterday's text sitting there.
local function ResetStatusProps()
  for _, name in ipairs(STATUS_PROPS) do
    UpdateProp(name, (gCtrlMethod == "IP") and "unknown" or STATUS_IR_TEXT)
  end
end

local function SetConnected(c)
  if gConnected == c then return end
  gConnected = c
  UpdateStatus("Connected", tostring(c))
  LogInfo("Connected = %s", tostring(c))
end

-- Surface an unconfigured driver in the ONE place a dealer looks without turning on logging:
-- the Connected property.  A bare "false" is indistinguishable from "the bar is unplugged",
-- which is exactly the confusion that cost an evening -- volume silently stopped working after
-- a remove/re-add reset IP Address to its blank default, and nothing anywhere said so.
local gUnconfiguredWarned = false
local function CheckConfigured()
  if gCtrlMethod ~= "IP" then return true end
  if DeviceAddress() then gUnconfiguredWarned = false; return true end
  gConnected = false
  UpdateStatus("Connected", "false - NO IP ADDRESS SET")
  if not gUnconfiguredWarned then   -- once per unconfigured spell, not once per property change
    gUnconfiguredWarned = true
    LogCritical("IP Address property is EMPTY, so nothing can be controlled over IP. " ..
      "Set it to the soundbar's address (DHCP-reserved). NOTE: removing and re-adding the " ..
      "driver resets every property to its default, and this one defaults to blank.")
  end
  return false
end

-------------------------------------------------
-- PROXY NOTIFICATIONS
-------------------------------------------------
local function NotifyPower(on) C4:SendToProxy(RECEIVER_BINDING, on and "ON" or "OFF", {}, "NOTIFY") end
local function NotifyVolume(level)
  C4:SendToProxy(RECEIVER_BINDING, "VOLUME_LEVEL_CHANGED",
    { LEVEL = tostring(level), OUTPUT = tostring(OUTPUT_BINDING) }, "NOTIFY")
end
local function NotifyMute(m)
  C4:SendToProxy(RECEIVER_BINDING, "MUTE_CHANGED",
    { MUTE = tostring(m), OUTPUT = tostring(OUTPUT_BINDING) }, "NOTIFY")
end
local function NotifySurroundMode(id)
  -- The proxy docs render this parameter as "SURROUND MODE" (with a space) in the notification
  -- table but "SurroundMode" in the command table, and the docs have already proven unreliable
  -- on naming.  Sending all three spellings costs nothing and avoids a hardware round trip to
  -- find out which one the proxy actually reads.
  C4:SendToProxy(RECEIVER_BINDING, "SURROUND_MODE_CHANGED", {
    OUTPUT                = tostring(OUTPUT_BINDING),
    SURROUND_MODE         = tostring(id),
    ["SURROUND MODE"]     = tostring(id),
    SurroundMode          = tostring(id),
  }, "NOTIFY")
end

local function NotifyInput(connId)
  C4:SendToProxy(RECEIVER_BINDING, "INPUT_OUTPUT_CHANGED",
    { INPUT = tostring(connId), OUTPUT = tostring(OUTPUT_BINDING) }, "NOTIFY")
end

-------------------------------------------------
-- UPnP SOAP LAYER (:49152, plain HTTP, no auth) - volume/mute
-------------------------------------------------
local function SoapEnvelope(service, action, innerXml)
  return '<?xml version="1.0" encoding="utf-8"?>' ..
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ' ..
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>' ..
    '<u:' .. action .. ' xmlns:u="' .. service .. '">' .. (innerXml or "") ..
    '</u:' .. action .. '></s:Body></s:Envelope>'
end

-- cb(ok, body)   [INSTRUMENTED for on-controller diagnosis]
local function Soap(ctrlPath, service, action, innerXml, cb)
  local addr = DeviceAddress()
  if not addr then LogWarning("SOAP %s: no device address (IP Address property empty)", action); if cb then cb(false) end return end
  local url = "http://" .. addr .. ":" .. UPNP_PORT .. ctrlPath
  local body = SoapEnvelope(service, action, innerXml)
  local headers = {
    ["Content-Type"] = 'text/xml; charset="utf-8"',
    ["SOAPACTION"]   = '"' .. service .. '#' .. action .. '"',
    ["Expect"]       = "",   -- suppress libcurl "Expect: 100-continue" (old Boa server 500s on it)
  }
  LogDebug("SOAP -> POST %s  [%s]", url, action)
  local ok, req = pcall(function() return C4:url() end)
  if not ok or not req then LogError("C4:url() unavailable: %s", tostring(req)); if cb then cb(false) end return end
  req:OnDone(function(transfer, responses, errCode, errMsg)
    local rt = type(responses)
    local rbody, rcode
    if rt == "table" then
      local r = responses[#responses] or responses
      if type(r) == "table" then rbody = r.body or r.data; rcode = r.code end
    elseif rt == "string" then rbody = responses end
    LogDebug("SOAP OnDone %s: err=%s httpcode=%s bodylen=%s",
      action, tostring(errCode), tostring(rcode), tostring(rbody and #rbody or "nil"))
    -- treat a 2xx OR any body we can parse as usable
    local usable = (rbody ~= nil and rbody ~= "") and (rcode == nil or rcode < 400)
    if cb then cb(usable, rbody) end
  end)
  pcall(function() req:SetOptions({ fail_on_error = false, timeout = 6, connect_timeout = 4 }) end)
  -- headers go as the 3rd arg to Post (NOT via SetOptions)
  local okp, errp = pcall(function() req:Post(url, body, headers) end)
  if not okp then LogError("SOAP req:Post threw: %s", tostring(errp)) end
end

-------------------------------------------------
-- httpapi TRANSPORT (:443 mutual-TLS over a raw SSL network connection) - power/input
-- Requires Control Method = IP.
--
-- WHY A RAW SOCKET AND NOT C4:url():  C4:url() has NO client-certificate support
-- (confirmed against Control4's own global/url.lua -- SetOptions handles cookies /
-- fail_on_error / timeouts, and nothing else).  The bar REQUIRES a client cert for
-- mutual TLS on :443, so the url interface can never authenticate.  Instead driver.xml
-- declares binding 6002 / port 443 with classname SSL + certificate/private_key/cacert;
-- Director performs the handshake and hands us a plain byte stream, over which we speak
-- HTTP/1.1 ourselves.
--
-- The bar runs an old Boa server (the same one that 500s on "Expect: 100-continue"), so
-- we send "Connection: close" and treat the socket close as end-of-body.  Content-Length
-- is honoured when present, which usually completes the request before the close arrives.
-- One connect per request; power/input are infrequent enough that this is free.
-------------------------------------------------
local PumpQueue   -- forward declaration (HttpApiFinish pumps the next request)

-- Split a raw HTTP response.  Returns code, body, contentLength, headerBlock.
local function ParseHttpResponse(raw)
  if not raw or raw == "" then return nil end
  local head, body = raw:match("^(.-)\r\n\r\n(.*)$")
  if not head then return nil end
  local code = tonumber(head:match("^HTTP/%d%.%d%s+(%d+)"))
  local clen = tonumber(head:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
  return code, body, clen, head
end

local function HttpApiFinish(ok, body, why)
  local req = gInFlight
  gInFlight = nil
  if gReqTimer then pcall(function() gReqTimer:Cancel() end); gReqTimer = nil end
  -- We always asked for "Connection: close", so the socket is spent either way.
  pcall(function() C4:NetDisconnect(SSL_BINDING, HTTPAPI_PORT) end)
  gSslOnline = false
  -- Raise the cooldown BEFORE running the callback, not after.  Every sweep issues its next
  -- request from inside that callback, so setting the flag afterwards lets exactly the request
  -- we are trying to protect slip out early and collide with the trailing OFFLINE.
  gCooldown = true

  if req then
    if ok then
      LogDebug("httpapi '%s' OK (%s, %d byte body)", req.command, tostring(why), #(body or ""))
    else
      LogWarning("httpapi '%s' FAILED: %s", req.command, tostring(why or "unknown"))
    end
    if req.cb then pcall(req.cb, ok, body) end
  end
  -- Do NOT start the next request immediately.  We just called NetDisconnect, and the OFFLINE
  -- notification for THAT socket is still in flight; if the next request has already connected
  -- by the time it lands, the stale OFFLINE is attributed to the NEW request and kills it
  -- ("socket closed with no response at all") even though its reply arrives moments later.
  -- The offline harness reproduces this deterministically.
  --
  -- gCooldown (raised above, before the callback) is what makes the gap actually hold: every
  -- sweep issues its next request from inside that callback, and HttpApiGet pumps the queue
  -- directly, so without the flag the new request would start instantly and skip the gap.
  C4:SetTimer(PUMP_GAP_MS, function()
    gCooldown = false
    if PumpQueue then PumpQueue() end
  end, false)
end

local function SendHttpApiRequest()
  local req = gInFlight
  if not req then return end
  local addr = DeviceAddress()
  if not addr then HttpApiFinish(false, nil, "IP Address property is empty"); return end
  local path = "/httpapi.asp?command=" .. UrlEncode(req.command)
  local wire = table.concat({
    "GET " .. path .. " HTTP/1.1",
    "Host: " .. addr,
    "User-Agent: Control4/DriverWorks",
    "Accept: */*",
    "Connection: close",
    "", "",
  }, "\r\n")
  req.sent = true
  req.rx   = ""
  LogDebug("httpapi TX -> %s:%d %s", addr, HTTPAPI_PORT, path)
  local ok, err = pcall(function() C4:SendToNetwork(SSL_BINDING, HTTPAPI_PORT, wire) end)
  if not ok then HttpApiFinish(false, nil, "SendToNetwork threw: " .. tostring(err)) end
end

-- Bind the declared SSL connection to the address from the IP Address property, so the
-- dealer never types the IP twice.  This is the documented pattern for a static SSL
-- <connection>: CreateNetworkConnection -> (NetPortOptions) -> NetConnect.
local function EnsureSslConnection()
  local addr = DeviceAddress()
  if not addr then return false end
  if gSslCreated and gSslAddr == addr then return true end
  local ok, err = pcall(function() C4:CreateNetworkConnection(SSL_BINDING, addr, "SSL") end)
  if not ok then
    LogError("CreateNetworkConnection(%d, %s, SSL) threw: %s", SSL_BINDING, addr, tostring(err))
    return false
  end
  -- Belt-and-braces: the XML already declares these, but re-asserting them costs nothing
  -- and makes the intent explicit if the XML port block is ever edited.
  pcall(function()
    C4:NetPortOptions(SSL_BINDING, HTTPAPI_PORT, "SSL", {
      AUTO_CONNECT = false, KEEP_CONNECTION = false, MONITOR_CONNECTION = false,
    })
  end)
  gSslCreated, gSslAddr = true, addr
  LogInfo("httpapi SSL connection bound to %s:%d", addr, HTTPAPI_PORT)
  return true
end

PumpQueue = function()
  if gInFlight then return end
  local req = table.remove(gQueue, 1)
  if not req then return end
  gInFlight = req
  gReqTimer = C4:SetTimer(HTTPAPI_TIMEOUT_MS, function()
    gReqTimer = nil
    HttpApiFinish(false, nil, string.format("timeout after %dms", HTTPAPI_TIMEOUT_MS))
  end, false)
  if not EnsureSslConnection() then
    HttpApiFinish(false, nil, "could not bind the SSL connection")
    return
  end
  if gSslOnline then
    SendHttpApiRequest()
  else
    LogDebug("httpapi: connecting %s:%d (mutual-TLS handshake) ...", tostring(gSslAddr), HTTPAPI_PORT)
    local ok, err = pcall(function() C4:NetConnect(SSL_BINDING, HTTPAPI_PORT) end)
    if not ok then HttpApiFinish(false, nil, "NetConnect threw: " .. tostring(err)) end
  end
end

local function HttpApiGet(command, cb)
  if not DeviceAddress() then
    LogWarning("httpapi '%s': no device address (IP Address property empty)", tostring(command))
    if cb then cb(false) end; return
  end
  -- NO per-request cert check.  Lua cannot see inside the .c4z (both C4:ReadFile and
  -- C4:FileExists fail on bundles whose handshake then succeeds), so any such line is
  -- noise at best and misleading at worst.  The handshake decides.
  gQueue[#gQueue + 1] = { command = command, cb = cb }
  LogTrace("httpapi queued '%s' (depth %d)", tostring(command), #gQueue)
  -- During the post-request cooldown the timer in HttpApiFinish owns the pump; starting here
  -- would race the previous socket's trailing OFFLINE (see there).
  if not gCooldown then PumpQueue() end
end

-------------------------------------------------
-- IR LAYER (Control Method = IR)
--
-- IR is one-way and stateless: nothing comes back, so the driver cannot know whether a code
-- landed, or what the bar's state is.  That is the fundamental difference from the IP path and
-- the reason IP stays the better option for an owner who can use it.  IR exists because it is
-- what ships to dealers, needs no client certificate, and works on any unit.
-------------------------------------------------
-- When true, every IR send also reports through the UNSILENCEABLE path.  Set during the
-- IR test/verify Actions.  Bringup taught this the hard way: the whole IR layer was landing
-- on a driver whose Log Mode had reset to "Off", so a fired code and a refused one were
-- indistinguishable -- both produced total silence.  A diagnostic you have to remember to
-- enable is not a diagnostic during bringup.
local gIrLoud = false

local function SendIR(code, label)
  if not code then return false end
  local name = tostring(label or "?")
  -- The docs say C4:SendIR(idBinding, idIRCode) takes the numeric id, but Control4's own
  -- shipping lua_gen drivers (c4_ir_connection template) pass it as a STRING.  Only one of
  -- those is verified working, and it is not the documented one -- so try the documented
  -- form and fall back, rather than spending a hardware trip deciding which is right.
  local ok, err = pcall(function() C4:SendIR(IR_BINDING, code) end)
  if not ok then
    local ok2, err2 = pcall(function() C4:SendIR(IR_BINDING, tostring(code)) end)
    if ok2 then
      LogCritical("C4:SendIR needed the STRING code form (numeric threw: %s) -- worth baking in.",
        tostring(err))
      ok, err = true, nil
    else
      err = tostring(err) .. " / string form: " .. tostring(err2)
    end
  end
  if ok then
    LogDebug("IR -> %s (code %d) on binding %d", name, code, IR_BINDING)
    if gIrLoud then
      LogCritical("IR fired: %s (code %d) on binding %d. C4:SendIR did not error -- if the " ..
        "emitter did not blink, the problem is the binding or the emitter, NOT this code.",
        name, code, IR_BINDING)
    end
  else
    -- A throw here means the API call itself is wrong (the C4:Log / C4:ReadFile trap again).
    -- That can never be gated behind a log level: it means IR cannot work at all.
    LogCritical("C4:SendIR(%d, %s) THREW: %s -- IR output is not functional.",
      IR_BINDING, tostring(code), tostring(err))
  end
  return ok
end

-- Ask Director, at the moment of use, what it thinks is attached to the IR binding.  Composer's
-- Connections view showing a wire is NOT proof Director agrees: the view is the project's
-- intent, this is the runtime's opinion, and only the second one can transmit.  Every call is
-- pcall'd because an API that does not exist must degrade to "unknown", never take the driver
-- down (C4:Log and C4:ReadFile were both learned that way).
local function IrBindingReport()
  local myId = select(2, pcall(function() return C4:GetDeviceID() end))
  LogCritical("IR binding %d diagnostics (this driver's device id: %s):", IR_BINDING, tostring(myId))

  -- NOT evidence of anything on its own. OnBindingChanged fires only when a binding CHANGES,
  -- so a binding that was already bound when the driver loaded never fires it. An earlier
  -- version of this line read that silence as "nothing is attached", which was flatly wrong and
  -- contradicted GetBoundProviderDevice in the same block. GetBoundProviderDevice is the
  -- authority here; this line is only useful for spotting a bind/unbind DURING the session.
  if gBindings[IR_BINDING] == nil then
    LogCritical("  OnBindingChanged: not seen this session (normal -- it only fires on a CHANGE, " ..
      "so a binding already bound at load never reports. Trust GetBoundProviderDevice below.)")
  else
    LogCritical("  OnBindingChanged: last reported bIsBound = %s (class %s)",
      tostring(gBindings[IR_BINDING]), tostring(gBindingClass[IR_BINDING]))
  end

  -- THE authoritative check: which device is driving our IR input binding right now.
  local ok, prov = pcall(function() return C4:GetBoundProviderDevice(myId, IR_BINDING) end)
  if ok and prov and prov ~= 0 then
    LogCritical("  GetBoundProviderDevice -> %s   (BOUND: device %s is the IR output feeding us)",
      tostring(prov), tostring(prov))
  else
    LogCritical("  GetBoundProviderDevice -> %s   <-- NOTHING IS DRIVING THIS BINDING",
      ok and tostring(prov) or "unavailable")
  end

  -- Expected to be empty/nil: our IR connection is a CONSUMER, so it has no bound consumers of
  -- its own. Logged only so its emptiness is not mistaken for a fault.
  local ok2, cons = pcall(function() return C4:GetBoundConsumerDevices(myId, IR_BINDING) end)
  local n = 0
  if ok2 and type(cons) == "table" then
    for id, name in pairs(cons) do n = n + 1; LogCritical("  bound consumer: %s (%s)", tostring(id), tostring(name)) end
  end
  if n == 0 then
    LogCritical("  bound consumers: none (EXPECTED -- this is a consumer connection, not a provider)")
  end
end

-- Fire exactly one code with no other machinery in the way: no proxy, no capabilities, no
-- Control Method check and no IP address.  This is the instrument that
-- separates "the emitter/binding is dead" from "the code is wrong" -- the two failures that
-- look identical from the driver's side, because IR is one-way.
local function IrFireOne(codeName)
  local code = IR[codeName]
  if not code then LogCritical("IR test: no such code %s", tostring(codeName)); return end
  LogCritical("---- IR emitter test: %s (code %d) on binding %d ----", codeName, code, IR_BINDING)
  IrBindingReport()
  LogCritical("Watch the emitter LED. This bypasses Control Method and the IP path.")
  -- Exactly ONE code per press. The numeric id form is confirmed working on hardware
  -- (POWER_ON/POWER_OFF both scored WORKS with it), so the old number-then-string double fire
  -- is gone: for by-ear testing a second burst would move the volume twice or toggle mute back.
  gIrLoud = true
  SendIR(code, codeName)
  gIrLoud = false
end

-- True when this command should go out as IR rather than over IP.
local function UsingIR() return gCtrlMethod == "IR" end

-------------------------------------------------
-- SETTERS
-------------------------------------------------
local function xmlval(body, tag) return body and body:match("<" .. tag .. ">(.-)</" .. tag .. ">") end

-- Absolute volume over IR.  There is no "set to 40" IR code, so the only way to honour a
-- discrete request is to pulse toward it from the level we last believed.  That drifts,
-- because nothing confirms it -- hence the cap and the honest log line.
--
-- This path exists because <capabilities> is NOT per-control-method: has_discrete_volume_control
-- is declared once and applies in IR mode too, so Navigator's slider and Halo BOTH send
-- SET_VOLUME_LEVEL regardless of Control Method.  Before this branch existed, that command fell
-- straight through to UPnP SOAP and fired NO IR at all -- the single biggest reason "IR mode did
-- nothing" when the volume control was the thing being pressed.
local IR_VOL_STEP_PCT  = 2    -- assumed change per VOLUME_UP/DOWN pulse
local IR_VOL_MAX_PULSE = 20   -- never machine-gun the emitter on a big jump

local function SetVolumeLevelIR(level)
  local from  = gYxcVolume or 20
  local delta = level - from
  local n     = math.floor(math.abs(delta) / IR_VOL_STEP_PCT + 0.5)
  if n > IR_VOL_MAX_PULSE then n = IR_VOL_MAX_PULSE end
  if n < 1 then
    LogDebug("IR volume: %d -> %d is under one step, nothing sent", from, level)
    return
  end
  -- Nothing corrects this afterwards: state feedback is off in IR mode by design, so the
  -- inferred level is the only level the driver has.
  local up   = delta > 0
  local code = up and IR.VOLUME_UP or IR.VOLUME_DOWN
  LogDebug("IR volume: %d -> %d = %d %s pulse(s) (assumed %d%%/pulse; NOT confirmed by the bar)",
    from, level, n, up and "up" or "down", IR_VOL_STEP_PCT)
  for _ = 1, n do SendIR(code, up and "VOLUME_UP" or "VOLUME_DOWN") end
  gYxcVolume = from + (up and 1 or -1) * n * IR_VOL_STEP_PCT
end

local function SetVolumeLevel(level)
  if not level then return end
  if level < 0 then level = 0 elseif level > 100 then level = 100 end
  if UsingIR() then
    SetVolumeLevelIR(level)
    -- Report the level we were ASKED for, not the one we inferred: the UI slider has to track
    -- the user's own drag or it fights them. The inferred value stays internal (gYxcVolume).
    UpdateStatus("Current Volume", tostring(level))
    NotifyVolume(level)
    return
  end
  gYxcVolume = level
  UpdateStatus("Current Volume", tostring(level))
  NotifyVolume(level)
  Soap(RC_CTRL, RC, "SetVolume",
    "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>" .. level .. "</DesiredVolume>")
end

local function VolStep(dir)
  if UsingIR() then
    -- One IR pulse per press.  We cannot track absolute level over IR, so no property update:
    -- claiming a number we have not verified would be worse than showing the last known one.
    SendIR(dir == "up" and IR.VOLUME_UP or IR.VOLUME_DOWN, "VOLUME_" .. string.upper(dir))
    return
  end
  local base = gYxcVolume or 20
  SetVolumeLevel(base + (dir == "up" and 3 or -3))
end

-- Held volume (Navigator/Halo press-and-hold).  SUSTAIN-style ramping is what C4:SendIRStart /
-- C4:SendIRStop are for; plain C4:SendIR only ever emits a single burst.  If the proxy sends
-- these at all they must be handled, or a held button does nothing.
local function VolRamp(dir, start)
  if not UsingIR() then
    if start then VolStep(dir) end
    return
  end
  local code = (dir == "up") and IR.VOLUME_UP or IR.VOLUME_DOWN
  local fn   = start and "SendIRStart" or "SendIRStop"
  local ok, err = pcall(function() C4[fn](C4, IR_BINDING, code) end)
  if not ok then
    LogCritical("C4:%s(%d, %d) threw: %s -- falling back to a single pulse.",
      fn, IR_BINDING, code, tostring(err))
    if start then SendIR(code, "VOLUME_" .. string.upper(dir)) end
  else
    LogDebug("IR ramp %s: %s", fn, dir)
  end
end

local function SetMute(m)
  gMute = m
  UpdateStatus("Muted", tostring(m))
  NotifyMute(m)
  if UsingIR() then
    SendIR(m and IR.MUTE_ON or IR.MUTE_OFF, m and "MUTE_ON" or "MUTE_OFF")
    return
  end
  Soap(RC_CTRL, RC, "SetMute",
    "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredMute>" .. (m and "1" or "0") .. "</DesiredMute>")
end

local SetPower   -- forward declaration; CONNECT_OUTPUT / DISCONNECT_OUTPUT call it
SetPower = function(on)
  gPower = on
  UpdateStatus("Power State", on and "On" or "Standby")
  NotifyPower(on)
  if UsingIR() then
    SendIR(on and IR.POWER_ON or IR.POWER_OFF, on and "POWER_ON" or "POWER_OFF")
    return
  end
  -- Power over IP is httpapi (mutual-TLS).
  --
  -- VERIFIED, not fire-and-forget. This used to send with no callback, so a power command that
  -- never reached the bar was completely silent while the driver had ALREADY reported the new
  -- state - which is exactly what "the soundbar did not come on with the system" looks like from
  -- Composer. A command that fails must say so, and must not leave the UI claiming it worked.
  local want = on and "1" or "0"
  HttpApiGet('YAMAHA_DATA_SET:{"power saving":"' .. want .. '"}', function(ok, body)
    if ok then
      LogDebug("power %s acknowledged by the bar", on and "on" or "off")
      return
    end
    -- Roll the reported state back to unknown rather than leave a claim nothing supports.
    gPower = nil
    UpdateStatus("Power State", "unknown - last command failed")
    LogCritical("POWER %s FAILED: the bar did not answer over mutual TLS. It is either " ..
      "unreachable at %s or in a standby deep enough that its network is asleep. Nothing was " ..
      "changed; the reported power state has been cleared rather than left claiming success.",
      on and "ON" or "OFF", tostring(DeviceAddress()))
  end)
end

-- Readback schedule: check at 3s, and if it did not take, resend once and check again at 5s.
--
-- SCOPE, deliberately modest. Hardware (2026-07-31) showed the bar switching input correctly even
-- straight out of a 3-hour standby, so a retry storm would be solving a problem that has not been
-- observed. What IS established about this device is that a 200 OK means nothing - it acknowledges
-- junk exactly as it acknowledges a valid value - so a single verification that can SAY the input
-- did not take is worth one readback. Two attempts, then it reports and stops.
local INPUT_VERIFY_MS  = { 3000, 5000 }

local VerifyInput   -- forward declaration; SelectInputByConn calls it
local SelectInputByConn

-- Read the bar's actual input back and re-send if it did not take.
VerifyInput = function(connId, sw, attempt)
  local wait = INPUT_VERIFY_MS[attempt]
  if not wait then
    LogCritical("INPUT: asked for %s %d times and the bar never reported it. It may have been " ..
      "waking from standby, or this input cannot be selected in its current state. The room may " ..
      "be showing the wrong source.", tostring(sw), #INPUT_VERIFY_MS)
    return
  end
  C4:SetTimer(wait, function()
    HttpApiGet("getPlayerStatus", function(ok, body)
      local mode = ok and jsonstr(body, "mode") or nil
      local got  = mode and MODE_TO_CONN[mode] or nil
      if got == connId then
        LogDebug("input confirmed: bar reports mode %s = connection %d", tostring(mode), connId)
        return
      end
      LogInfo("input not taken yet (bar reports mode %s, wanted connection %d) -- resending (%d/%d)",
        tostring(mode), connId, attempt, #INPUT_VERIFY_MS)
      HttpApiGet("setPlayerCmd:switchmode:" .. sw, function()
        VerifyInput(connId, sw, attempt + 1)
      end)
    end)
  end, false)
end

SelectInputByConn = function(connId)
  local sw = INPUT_MAP[connId]
  if not sw then LogWarning("unknown input connection id %s", tostring(connId)); return end
  gInputSw = sw
  UpdateStatus("Current Input", INPUT_NAME[connId] or sw)
  NotifyInput(connId)
  if UsingIR() then
    -- Was a hard refusal until the remote was captured (2026-07-30): the donor set had
    -- TV/DVD/VCR/AUX, none of which are this bar's inputs. All four now have discrete keys.
    local code = INPUT_IR[connId]
    if not code then
      LogCritical("IR: no captured input code for connection %s -- not sent.", tostring(connId))
      return
    end
    SendIR(code, "INPUT " .. tostring(sw))
    return
  end
  -- VERIFY, then RETRY. A 200 OK from this bar means NOTHING - proven on this device during the
  -- sound-program work, where it acknowledged a junk value exactly as it acknowledged a valid
  -- one. Only the readback distinguishes them.
  --
  -- That matters most on room-on, when the proxy issues ON, CONNECT_OUTPUT, SET_INPUT and
  -- SET_VOLUME_LEVEL inside the SAME SECOND while the bar is still waking from standby. The
  -- input command is accepted, acknowledged and discarded, so the bar powers up on whatever
  -- input it was last on and the room shows a black screen - which is exactly the fault Dave
  -- hit. Firing once and trusting the 200 cannot detect that.
  HttpApiGet("setPlayerCmd:switchmode:" .. sw, function()
    VerifyInput(connId, sw, 1)
  end)
end

local function CycleInput()
  local cur = gInputSw and SWITCH_TO_CONN[gInputSw] or nil
  local idx = 1
  for i, id in ipairs(INPUT_ORDER) do if id == cur then idx = i; break end end
  SelectInputByConn(INPUT_ORDER[(idx % #INPUT_ORDER) + 1])
end


local function ConnIdFromParams(t)
  if type(t) ~= "table" then return nil end
  for _, k in ipairs({ "InputBindingID", "INPUT", "idBinding", "BindingID", "IDBINDING" }) do
    local v = tonumber(t[k]); if v and INPUT_MAP[v] then return v end
  end
  for _, v in pairs(t) do local n = tonumber(v); if n and INPUT_MAP[n] then return n end end
  return nil
end

-------------------------------------------------
-- POLLING (UPnP volume/mute; no cert needed)
-------------------------------------------------
local function Poll()
  Soap(RC_CTRL, RC, "GetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel>", function(ok, body)
    if not ok or not body then
      gPollFails = gPollFails + 1
      if gPollFails >= 3 then SetConnected(false) end
      return
    end
    gPollFails = 0; SetConnected(true)
    local v = tonumber(xmlval(body, "CurrentVolume"))
    if v and v ~= gYxcVolume then
      gYxcVolume = v; UpdateStatus("Current Volume", tostring(v)); NotifyVolume(v)
    end
  end)
  Soap(RC_CTRL, RC, "GetMute", "<InstanceID>0</InstanceID><Channel>Master</Channel>", function(ok, body)
    if not ok or not body then return end
    local m = xmlval(body, "CurrentMute")
    if m then
      local mb = (m == "1" or m == "true")
      if mb ~= gMute then gMute = mb; UpdateStatus("Muted", tostring(mb)); NotifyMute(mb) end
    end
  end)
end

local function StopPoll() if gPollTimer then gPollTimer:Cancel(); gPollTimer = nil end end
local function StartPoll()
  StopPoll()
  -- Gated on Control Method BY DESIGN (owner's decision, 2026-07-30). A driver set to IR is
  -- controlling a device it is not talking to over the network, and it should not quietly go
  -- reading state behind that choice: an IR install is one-way, and the driver knowing only the
  -- last command it sent is the honest model. A hybrid (IR out, IP back) was proposed and
  -- REJECTED -- do not re-decouple this without asking.
  if gCtrlMethod ~= "IP" then
    -- Say so on the property too. "Connected" is set by this poll, so leaving it at its last
    -- value would keep claiming a live link to a bar the driver has stopped talking to -- the
    -- same failure as any other stale display, and misleading precisely when someone is
    -- debugging an IR install.
    gConnected = false
    -- ResetStatusProps has already parked every status field with the reason.
    LogDebug("volume/mute feedback off: Control Method = %s", tostring(gCtrlMethod))
    return
  end
  if not DeviceAddress() then
    LogDebug("volume/mute feedback off: no IP Address set")
    return
  end
  Poll()
  -- bRepeat = TRUE. Do not go back to a one-shot plus timer:Reset(): that pattern fired exactly
  -- once and left the UI showing stale values forever (2026-07-31).
  gPollTimer = C4:SetTimer(gPollSecs * 1000, function() Poll() end, true)
end

-------------------------------------------------
-- STATE FEEDBACK (power / input, read back over httpapi)
--
-- Separate and MUCH slower than the UPnP poll above on purpose.  UPnP is cheap plaintext
-- SOAP; every httpapi read is a full mutual-TLS handshake, because each request is one
-- connect with "Connection: close".  Polling this at the volume/mute cadence would mean a
-- TLS handshake every few seconds, forever.
--
-- These apply state WITHOUT re-sending commands -- they reflect what the bar reports, so
-- the UI stays right when someone uses the Yamaha remote or the front panel.
-------------------------------------------------
local gPowerKeyWarned = false

local function pesc(s) return (tostring(s):gsub("(%W)", "%%%1")) end
local function jsonstr(body, key)
  if not body then return nil end
  return body:match('"' .. pesc(key) .. '"%s*:%s*"([^"]*)"')
end

local function ApplyPowerState(on)
  if on == gPower then return end
  gPower = on
  UpdateStatus("Power State", on and "On" or "Standby")
  NotifyPower(on)
  LogInfo("power changed at the bar -> %s", on and "On" or "Standby")
end

local function ApplyInputState(connId)
  local sw = INPUT_MAP[connId]
  if not sw or gInputSw == sw then return end
  gInputSw = sw
  UpdateStatus("Current Input", INPUT_NAME[connId] or sw)
  NotifyInput(connId)
  -- Log keeps the wire value too: it is what the bar actually reported and what any protocol
  -- debugging needs, even though it must not be what the property shows.
  LogInfo("input changed at the bar -> %s (connection %d, mode '%s')",
    INPUT_NAME[connId] or sw, connId, sw)
end

-- `manual` = triggered by the Get Device Status action rather than the timer. It skips the
-- interval check ONLY: "State Poll Seconds = 0" means "do not poll on a timer", not "never read",
-- and someone who turned automatic polling off to avoid a TLS handshake every 30s is exactly the
-- person who wants a button. The Control Method and address gates still apply --
-- those are about whether reading is permitted at all, not how often.
local function PollHttpApiState(manual)
  if gCtrlMethod ~= "IP" or not DeviceAddress() then return end
  if not manual and gStatePollSecs <= 0 then return end

  HttpApiGet("getPlayerStatus", function(ok, body)
    if not ok or not body then return end
    LogDebug("getPlayerStatus raw: %s", body)
    local mode = jsonstr(body, "mode")
    if not mode then return end
    -- Ignore the generic idle value while the bar is known to be off: 0 is "no source",
    -- not "Network", and reporting Network in standby is worse than reporting nothing.
    if mode == MODE_IDLE and gPower == false then
      LogDebug("ignoring mode 0 (idle) while power is off")
      return
    end
    local conn = MODE_TO_CONN[mode]
    if conn then
      ApplyInputState(conn)
    elseif not gUnknownModes[mode] then
      -- Warn once per distinct value, not every poll.
      gUnknownModes[mode] = true
      LogWarning("getPlayerStatus mode='%s' is not in MODE_TO_CONN -- note which input is " ..
        "physically selected right now and add it to that table in driver.lua", mode)
    end
  end)

  HttpApiGet("YAMAHA_DATA_GET", function(ok, body)
    if not ok or not body then return end
    LogDebug("YAMAHA_DATA_GET raw: %s", body)

    -- Power.  CONFIRMED on hardware: the payload really does carry "power saving".
    local ps = jsonstr(body, "power saving")
    if ps == "1" then ApplyPowerState(true)
    elseif ps == "0" then ApplyPowerState(false)
    elseif not gPowerKeyWarned then
      gPowerKeyWarned = true
      LogWarning("YAMAHA_DATA_GET returned no \"power saving\" field on this firmware, so " ..
        "power feedback is unavailable. Run 'Probe Yamaha Settings' and read the raw payload.")
    end

    -- Surround mode: reported to the receiver proxy, not to a property.
    local prog = jsonstr(body, "sound program")
    if prog then
      if prog ~= gDeviceSettings["sound program"] then
        LogInfo("sound program changed at the bar -> %s", prog)
      end
      gDeviceSettings["sound program"] = prog
      local id = PROGRAM_TO_SURROUND_ID[prog]
      if id then
        NotifySurroundMode(id)
      elseif not gUnknownModes["prog:" .. prog] then
        gUnknownModes["prog:" .. prog] = true
        LogWarning("bar reports sound program '%s', which is not in SURROUND_MODES -- add it " ..
          "there AND to <surround_modes> in driver.xml (the ids must match)", prog)
      end
    end

    -- Writable settings: remember what the bar said BEFORE touching the property, so the
    -- resulting OnPropertyChanged is recognised as an echo and not sent back.
    for _, s in ipairs(SETTING_PROPS) do
      local raw = jsonstr(body, s.key)
      if raw ~= nil then
        gDeviceSettings[s.key] = raw
        UpdateProp(s.prop, s.dec(raw))
      end
    end
    for _, s in ipairs(STATUS_ONLY) do
      local raw = jsonstr(body, s.key)
      if raw ~= nil then gDeviceSettings[s.key] = raw end   -- recorded; reported by Get Device Status
    end

  end)
end

-- Write one Yamaha setting.  Optimistically records the value as the device's, so the
-- property echo this causes does not bounce straight back out again.
-- Yamaha settings that IR can reach, and how. The three DSP switches have TOGGLE-only keys on
-- the remote, so over IR the driver can flip them but cannot assert an absolute state: with no
-- readback there is nothing to reconcile against. It sends the toggle and says so, rather than
-- pretending the requested value was applied.
local SETTING_IR_TOGGLE = {
  ["3D surround"]    = "SURROUND_3D",
  ["clear voice"]    = "CLEAR_VOICE",
  ["bass extension"] = "BASS_EXTENSION",
}

local function SetYamahaSetting(key, wireValue, cb)
  if UsingIR() then
    local sub = (key == "subwoofer volume")
    if sub then
      -- Subwoofer trim has discrete Up/Down keys; step from the last value the BAR reported.
      local from = tonumber(gDeviceSettings[key]) or 0
      local to   = tonumber(wireValue) or from
      local n    = math.abs(to - from)
      if n == 0 then if cb then cb(true) end return end
      local code = (to > from) and IR.BASS_UP or IR.BASS_DOWN
      LogDebug("IR subwoofer: %d -> %d = %d %s press(es)", from, to, n, to > from and "up" or "down")
      for _ = 1, n do SendIR(code, to > from and "BASS_UP" or "BASS_DOWN") end
      gDeviceSettings[key] = wireValue
      if cb then cb(true) end
      return
    end
    local toggle = SETTING_IR_TOGGLE[key]
    if toggle then
      SendIR(IR[toggle], toggle)
      LogCritical("IR '%s': the remote has only a TOGGLE for this, so the driver flipped it " ..
        "rather than setting it to '%s'. Over IR there is no readback to correct against.",
        key, tostring(wireValue))
      gDeviceSettings[key] = wireValue
      if cb then cb(true) end
      return
    end
    if key == "sound program" then
      local name = PROGRAM_IR[wireValue]
      if name then
        SendIR(IR[name], name)
        gDeviceSettings[key] = wireValue
        if cb then cb(true) end
        return
      end
    end
    LogCritical("IR: no captured code for setting '%s' -- not sent. Use Control Method = IP.", key)
    if cb then cb(false) end
    return
  end
  gDeviceSettings[key] = wireValue
  local cmd = string.format('YAMAHA_DATA_SET:{"%s":"%s"}', key, wireValue)
  LogInfo("setting %s = %s", key, wireValue)
  HttpApiGet(cmd, cb)
end

local function StopStatePoll()
  if gStatePollTimer then gStatePollTimer:Cancel(); gStatePollTimer = nil end
end

local function StartStatePoll()
  StopStatePoll()
  -- Same gate as the volume/mute poll, and for the same reason: state feedback belongs to IP
  -- control. See StartPoll.
  if gCtrlMethod ~= "IP" or not DeviceAddress() or gStatePollSecs <= 0 then
    LogDebug("state feedback off (method=%s addr=%s interval=%s)",
      tostring(gCtrlMethod), tostring(DeviceAddress()), tostring(gStatePollSecs))
    return
  end
  -- Deliberately NO immediate poll: OnDriverLateInit walks every property, so firing here
  -- would touch off a burst of TLS handshakes on load.  First read happens one interval in.
  -- bRepeat = TRUE; see StartPoll.
  gStatePollTimer = C4:SetTimer(gStatePollSecs * 1000, function() PollHttpApiState() end, true)
  LogInfo("state feedback on: power/input read back every %ds", gStatePollSecs)
end


-------------------------------------------------
-- VERIFY IR CODES
--
-- The seeded patterns come from Control4's Yamaha YSP-1000 driver (2005) and are unverified on
-- this 2019 bar.  IR gives no feedback, so the only way to know whether a code landed is to
-- watch the bar over the IP path: fire the code, then read YAMAHA_DATA_GET and see whether the
-- expected field actually moved.  That makes the IP work we already did the test instrument for
-- IR, and gives an objective per-code pass/fail instead of judging by ear.
--
-- Needs an IR emitter aimed at the bar AND Control Method = IP (for the readback).
-------------------------------------------------
-------------------------------------------------
-- RECEIVER PROXY COMMANDS (5001)
-------------------------------------------------
local ReceiverCommands = {}
function ReceiverCommands.ON()  SetPower(true)  end
function ReceiverCommands.OFF() SetPower(false) end
function ReceiverCommands.SET_VOLUME_LEVEL(p) SetVolumeLevel(tonumber(p and p.LEVEL)) end
function ReceiverCommands.PULSE_VOL_UP()   VolStep("up")   end
function ReceiverCommands.PULSE_VOL_DOWN() VolStep("down") end
-- Press-and-hold ramping.  Which of these the proxy actually emits is unconfirmed, so all the
-- spellings seen in the receiver-proxy docs are accepted -- same reasoning as the surround-mode
-- parameter names: cheaper than spending a hardware trip finding out which one is real.
function ReceiverCommands.START_VOL_UP()   VolRamp("up",   true)  end
function ReceiverCommands.STOP_VOL_UP()    VolRamp("up",   false) end
function ReceiverCommands.START_VOL_DOWN() VolRamp("down", true)  end
function ReceiverCommands.STOP_VOL_DOWN()  VolRamp("down", false) end
ReceiverCommands.STARTVOLUMEUP    = ReceiverCommands.START_VOL_UP
ReceiverCommands.STOPVOLUMEUP     = ReceiverCommands.STOP_VOL_UP
ReceiverCommands.STARTVOLUMEDOWN  = ReceiverCommands.START_VOL_DOWN
ReceiverCommands.STOPVOLUMEDOWN   = ReceiverCommands.STOP_VOL_DOWN
function ReceiverCommands.MUTE_ON()     SetMute(true)  end
function ReceiverCommands.MUTE_OFF()    SetMute(false) end
-- MUTE_TOGGLE is what the Control4 remote's mute button sends -- it has no discrete on/off.
-- This used to be SetMute(not gMute), i.e. it inverted the driver's BELIEF about the bar. When
-- that belief was stale or unknown (nil -> "not nil" is true -> MUTE_ON) it commanded the state
-- the bar was already in, so the first press did nothing and the second worked. Observed on
-- hardware 2026-07-30. A toggle must never be resolved against a cached value.
function ReceiverCommands.MUTE_TOGGLE()
  if UsingIR() then
    -- The remote's own toggle code. State-independent by construction: the BAR decides what to
    -- flip, so this is correct even though IR gives us nothing to read. Strictly better here
    -- than picking a discrete code from a guess.
    SendIR(IR.MUTE_TOGGLE, "MUTE_TOGGLE")
    -- Best-effort local tracking; nothing can confirm it over IR.
    if gMute ~= nil then
      gMute = not gMute
      UpdateStatus("Muted", tostring(gMute))
      NotifyMute(gMute)
    end
    return
  end
  -- Over IP, ask the bar what it is actually doing, then command the opposite discretely.
  Soap(RC_CTRL, RC, "GetMute", "<InstanceID>0</InstanceID><Channel>Master</Channel>",
    function(ok, body)
      local cur = ok and body and xmlval(body, "CurrentMute") or nil
      if cur == nil then
        -- No readback: fall back to the belief rather than doing nothing, and say so, because
        -- this is the exact condition that makes a toggle land wrong.
        LogWarning("MUTE_TOGGLE: could not read current mute state, toggling from the last " ..
          "known value (%s) -- may need a second press if that was stale", tostring(gMute))
        SetMute(not gMute)
        return
      end
      local muted = (cur == "1" or cur == "true")
      LogDebug("MUTE_TOGGLE: bar reports muted=%s, commanding %s", tostring(muted), tostring(not muted))
      SetMute(not muted)
    end)
end
function ReceiverCommands.SET_INPUT(p)  local id = ConnIdFromParams(p); if id then SelectInputByConn(id) end end
function ReceiverCommands.PULSE_INPUT() CycleInput() end

-- Output routing. Control4's OWN receiver driver makes ON/OFF no-ops and does the real work in
-- CONNECT_OUTPUT / DISCONNECT_OUTPUT ("--Handled by CONNECT_OUTPUT" is literally the body of its
-- PRX_CMD.ON). This driver had it the other way round and ignored both, which is why they showed
-- up as unimplemented on every room-on. Implemented here as power, guarded so that the ON that
-- arrives alongside them does not send a second, redundant power command.
function ReceiverCommands.CONNECT_OUTPUT(p)
  LogDebug("CONNECT_OUTPUT (output %s)", tostring(p and p.OUTPUT))
  if gPower ~= true then SetPower(true) end
end

function ReceiverCommands.DISCONNECT_OUTPUT(p)
  LogDebug("DISCONNECT_OUTPUT (output %s)", tostring(p and p.OUTPUT))
  if gPower ~= false then SetPower(false) end
end

-- The proxy ASKS for state; answering is how the UI stays right. Unanswered, it simply keeps
-- whatever it last assumed.
function ReceiverCommands.GET_IS_MUTED()
  NotifyMute(gMute and true or false)
end

-- Surround section of the device's control UI.  Accepts every spelling of the parameter the
-- proxy docs use, for the same reason NotifySurroundMode sends all three.
function ReceiverCommands.SET_SURROUND_MODE(p)
  local raw = p and (p.SurroundMode or p.SURROUND_MODE or p["SURROUND MODE"] or p.MODE)
  local id = tonumber(raw)
  local prog = id and SURROUND_ID_TO_PROGRAM[id]
  if not prog then
    LogWarning("SET_SURROUND_MODE: unrecognised mode %s (expected one of the ids in " ..
      "<surround_modes>)", tostring(raw))
    return
  end
  gDeviceSettings["sound program"] = prog
  NotifySurroundMode(id)
  SetYamahaSetting("sound program", prog)
end

-------------------------------------------------
-- CLIENT CERT (bundled; gray-area material, gitignored from repo)
--
-- Director itself reads linkplay_client.pem out of the .c4z for the SSL handshake (the
-- paths are in driver.xml).  This check is purely a bringup aid: it tells the log what
-- the bundle actually contains, and never gates a request.
-------------------------------------------------
local function CheckCert()
  -- HISTORY, so nobody re-introduces this: the first version called C4:ReadFile(), which
  -- DOES NOT EXIST in DriverWorks (0 hits across Control4's published API -- same trap as
  -- C4:Log).  Wrapped in pcall, it failed silently and reported "cert not readable" on a
  -- bundle that was in fact perfect, on the very run where the handshake SUCCEEDED.
  -- C4:FileExists is the real API.  Do NOT probe with C4:FileOpen: it CREATES the file
  -- when missing, which would manufacture a false pass.
  -- SECOND FINDING (2026-07-27, on hardware): C4:FileExists ALSO returns false for a
  -- .c4z-bundled file, on the very runs whose handshake succeeded.  Lua simply cannot see
  -- inside the archive -- only Director can, and it reads the PEM itself using the paths in
  -- driver.xml.  So there is NO Lua-side probe that can tell us anything true here, and a
  -- "missing cert" line would be a lie.  Report the state of knowledge honestly instead.
  gCertPresent, gCertInfo = false, nil
  local ok, exists = pcall(function() return C4:FileExists("linkplay_client.pem") end)
  gCertPresent = (ok and exists) and true or false
  if gCertPresent then
    gCertInfo = "linkplay_client.pem visible to Lua"
  else
    gCertInfo = "not visible to Lua (expected -- .c4z contents are Director's to read)"
  end
  LogInfo("client bundle: %s; the TLS handshake is the only real test", gCertInfo)
end

local function HttpApiDiag()
  LogInfo("---- httpapi (SSL) diagnostics ----")
  LogInfo("Control Method    : %s", tostring(gCtrlMethod))
  LogInfo("IP Address        : '%s'", tostring(gAddress))
  LogInfo("Client bundle     : %s", tostring(gCertInfo or "not checked"))
  LogInfo("                    (Lua cannot read .c4z contents; not-visible is NORMAL)")
  LogInfo("SSL binding %d    : created=%s addr=%s online=%s",
    SSL_BINDING, tostring(gSslCreated), tostring(gSslAddr), tostring(gSslOnline))
  LogInfo("Queue depth       : %d, in flight: %s",
    #gQueue, gInFlight and tostring(gInFlight.command) or "none")
  LogInfo("----------------------------------")
end

-- Called by Director ONLY when driver.xml marks <private_key protected="True">.
function GetPrivateKeyPassword(Binding, Port)
  LogInfo("GetPrivateKeyPassword(%s, %s) -> supplying bundled key passphrase",
    tostring(Binding), tostring(Port))
  return HTTPAPI_KEY_PASSWORD
end

-------------------------------------------------
-- ACTIONS / COMMANDS
-------------------------------------------------
-- Read everything the driver can read, right now, and print what it ended up knowing.
-- Exists so nobody has to shorten "State Poll Seconds" just to see current values and then
-- remember to put it back -- and because every httpapi read is a full mutual-TLS handshake,
-- which is exactly why that interval is slow by default.
--
-- The summary is unsilenceable: an action whose entire purpose is to SHOW you the status is
-- useless if its output lands behind a Log Mode that defaults to Off.
local function GetDeviceStatus()
  LogCritical("---- device status ----")
  if gCtrlMethod ~= "IP" then
    LogCritical("Control Method is %s, so the driver does not read state from the bar " ..
      "(IR is one-way). Values below are what the driver last SENT, not what the bar reports.",
      tostring(gCtrlMethod))
  elseif not DeviceAddress() then
    LogCritical("No IP Address set -- nothing can be read. Values below are last-sent only.")
  end

  Poll()               -- UPnP volume/mute
  PollHttpApiState(true)   -- power / input / surround / DSP settings

  -- Let the reads land before reporting; both are async and the httpapi half is a handshake
  -- per request. Reporting immediately would print the PREVIOUS values and look like a bug.
  C4:SetTimer(3000, function()
    local function show(label, v)
      LogCritical("  %-18s %s", label, (v == nil or v == "") and "unknown" or tostring(v))
    end
    show("Connected",   (gCtrlMethod == "IP") and tostring(gConnected) or STATUS_IR_TEXT)
    show("Control Method", gCtrlMethod)
    show("Power",       gPower == nil and nil or (gPower and "On" or "Standby"))
    show("Input",       gInputSw and (INPUT_NAME[SWITCH_TO_CONN[gInputSw]] or gInputSw) or nil)
    show("Volume",      gYxcVolume)
    show("Muted",       gMute == nil and nil or tostring(gMute))
    show("Sound Program", gDeviceSettings["sound program"])
    for _, s in ipairs(SETTING_PROPS) do
      local raw = gDeviceSettings[s.key]
      show(s.prop, raw ~= nil and s.dec(raw) or nil)
    end
    for _, s in ipairs(STATUS_ONLY) do show(s.label, gDeviceSettings[s.key]) end
    LogCritical("----------------------")
  end, false)
end

-- Answers ONE question: is this particular unit compatible with the certificate this driver
-- ships? The certificate is a single shared Linkplay credential extracted from the vendor app,
-- not something issued to a device, so it either works on a given bar or it does not -- and a
-- firmware update is the one thing likely to change that answer. There is no way to
-- re-authenticate from inside the driver (no DriverWorks API supplies a client certificate at
-- runtime; the paths are read from driver.xml by Director), so replacing it means a rebuild.
-- That is well outside what an integrator would attempt, which is exactly why the verdict has
-- to be stated plainly rather than left to be inferred from a stack of log lines.
local function TestIpControl()
  LogCritical("---- IP control compatibility test ----")
  if gCtrlMethod ~= "IP" then
    LogCritical("NOTE: Control Method is IR, so this test only checks whether IP control COULD")
    LogCritical("work. Nothing here changes how the driver controls the bar.")
  end
  if not DeviceAddress() then
    LogCritical("RESULT: CANNOT TEST -- no IP Address set. Enter the bar's address first.")
    LogCritical("---------------------------------------")
    return
  end
  LogCritical("Bar address      : %s:%d", tostring(DeviceAddress()), HTTPAPI_PORT)
  LogCritical("Testing          : mutual-TLS handshake, then a getStatusEx read")

  HttpApiGet("getStatusEx", function(ok, body)
    if ok and body then
      local model = jsonstr(body, "yamaha_model_name") or jsonstr(body, "project") or "unknown"
      local fw    = jsonstr(body, "firmware") or "unknown"
      LogCritical("RESULT: COMPATIBLE -- this device accepts the driver's certificate.")
      LogCritical("  model reported : %s", tostring(model))
      LogCritical("  firmware       : %s", tostring(fw))
      LogCritical("  IP control, state feedback and the IP-only properties are all available.")
    else
      LogCritical("RESULT: NOT COMPATIBLE -- the device did not answer over mutual TLS.")
      LogCritical("  Either the certificate was rejected, or the bar is unreachable at this")
      LogCritical("  address. Check the address first; if that is right, this firmware no longer")
      LogCritical("  accepts the certificate this driver ships and IP control is unavailable")
      LogCritical("  until the driver is rebuilt with a new one. Use Control Method = IR.")
    end
    LogCritical("---------------------------------------")
  end)
end

function ExecuteCommand(strCommand, tParams)
  -- Composer Actions arrive as "LUA_ACTION" with the real action name in tParams.ACTION.
  if strCommand == "LUA_ACTION" then
    if type(tParams) == "table" and tParams["ACTION"] then
      strCommand = tParams["ACTION"]
    else
      local keys = {}
      if type(tParams) == "table" then for k, v in pairs(tParams) do keys[#keys+1] = tostring(k) .. "=" .. tostring(v) end end
      LogInfo("LUA_ACTION params (need the action key): %s", table.concat(keys, ", "))
    end
  end
  LogTrace("ExecuteCommand: %s", tostring(strCommand))
  if     strCommand == "RefreshNow"        then Poll()
  elseif strCommand == "GetDeviceStatus"   then GetDeviceStatus()
  elseif strCommand == "TestIrEmitter" then IrFireOne("POWER_ON")
  elseif strCommand == "TestHttpApi"       then TestIpControl()
  else LogTrace("Unhandled command: %s", tostring(strCommand)) end
end

-------------------------------------------------
-- CONTROL4 LIFECYCLE
-------------------------------------------------
function OnDriverInit()  LogInfo("OnDriverInit") end

function OnDriverLateInit()
  LogInfo("Yamaha Soundbar driver loaded (build 2026-07-27-a; UPnP validated on hardware, httpapi now on a raw SSL socket)")
  UpdateProp("Driver Version", "@BUILD@")
  for k, _ in pairs(Properties or {}) do OnPropertyChanged(k) end
  CheckCert()
  CheckConfigured()
  StartPoll()
  StartStatePoll()
  -- Only now may property edits be treated as user intent (see OnPropertyChanged).
  gInitDone = true
end

function OnDriverDestroyed()
  LogInfo("OnDriverDestroyed")
  StopPoll()
  StopStatePoll()
  if gReqTimer then pcall(function() gReqTimer:Cancel() end); gReqTimer = nil end
  if gSslCreated then pcall(function() C4:NetDisconnect(SSL_BINDING, HTTPAPI_PORT) end) end
end

function OnPropertyChanged(sProperty)
  local value = Properties and Properties[sProperty]
  LogTrace("OnPropertyChanged: %s = %s", tostring(sProperty), tostring(value))
  if sProperty == "Log Level" then
    gLogLevel = tonumber(string.match(value or "", "^(%d+)")) or LOG_LEVEL.WARNING
  elseif sProperty == "Log Mode" then
    gLogMode = value or "Off"
  elseif sProperty == "Control Method" then
    -- Match the leading token only: the visible label carries a pointer to the documentation.
    gCtrlMethod = (tostring(value or ""):upper():match("^(I[PR])")) or "IR"
    ResetStatusProps()
    StartPoll()
    StartStatePoll()
  elseif sProperty == "IP Address" then
    local newAddr = trim(value)
    if newAddr ~= gAddress then
      -- Force the SSL binding to be re-bound to the new address on the next request.
      if gSslCreated then pcall(function() C4:NetDisconnect(SSL_BINDING, HTTPAPI_PORT) end) end
      gSslCreated, gSslAddr, gSslOnline = false, nil, false
    end
    gAddress = newAddr
    if gAddress ~= "" then
      LogInfo("IP Address set to %s", gAddress)
      StartPoll()
      StartStatePoll()
    else
      CheckConfigured()
    end
  elseif sProperty == "Poll Interval Seconds" then
    gPollSecs = tonumber(value) or 3
    if gPollTimer then StartPoll() end
  elseif sProperty == "State Poll Seconds" then
    gStatePollSecs = tonumber(value) or 30
    StartStatePoll()
  else
    -- Yamaha settings.  Two guards keep this from writing when it shouldn't:
    --  1. gInitDone -- OnDriverLateInit walks every property, which would otherwise push the
    --     driver's defaults onto the bar on every single load.
    --  2. echo check -- reading a setting updates its property, which lands right back here;
    --     only a value that differs from what the device last reported is a real user edit.
    for _, s in ipairs(SETTING_PROPS) do
      if sProperty == s.prop then
        if not gInitDone then
          LogDebug("ignoring %s during init (not a user edit)", sProperty)
        else
          local wire = s.enc(value)
          if wire == gDeviceSettings[s.key] then
            LogDebug("%s echo (%s already current) - not sending", sProperty, tostring(value))
          else
            SetYamahaSetting(s.key, wire)
          end
        end
        return
      end
    end
  end
end

function OnConnectionStatusChanged(nBinding, nPort, sStatus)
  LogTrace("OnConnectionStatusChanged: binding=%s port=%s status=%s",
    tostring(nBinding), tostring(nPort), tostring(sStatus))

  if nBinding == NETWORK_BINDING then
    if sStatus == "ONLINE" then SetConnected(true) end
    return
  end

  if nBinding ~= SSL_BINDING then return end

  if sStatus == "ONLINE" then
    gSslOnline = true
    LogInfo("httpapi SSL socket ONLINE -- mutual-TLS handshake SUCCEEDED (client cert accepted)")
    if gInFlight and not gInFlight.sent then SendHttpApiRequest() end
    return
  end

  gSslOnline = false
  LogDebug("httpapi SSL socket %s", tostring(sStatus))
  if not (gInFlight and gInFlight.sent) then
    -- Went down before we sent anything: a handshake rejection looks exactly like this.
    if gInFlight then
      HttpApiFinish(false, nil, "socket went " .. tostring(sStatus) ..
        " before the request was sent (handshake rejected? check the client cert)")
    end
    return
  end
  -- We asked for "Connection: close", so a close AFTER the request is the normal
  -- end-of-response, not a failure -- provided we actually received something.
  local raw = gInFlight.rx or ""
  if #raw > 0 then
    local code, body = ParseHttpResponse(raw)
    if code then HttpApiFinish(code < 400, body, "HTTP " .. code)
    else HttpApiFinish(false, raw, "unparseable response (" .. #raw .. " bytes)") end
  else
    HttpApiFinish(false, nil, "socket closed with no response at all (status=" .. tostring(sStatus) .. ")")
  end
end

function ReceivedFromNetwork(nBinding, nPort, sData)
  if nBinding ~= SSL_BINDING then return end
  if not gInFlight then
    LogTrace("httpapi RX with no request in flight (%d bytes discarded)", #(sData or ""))
    return
  end
  gInFlight.rx = (gInFlight.rx or "") .. (sData or "")
  LogTrace("httpapi RX %d bytes (%d buffered)", #(sData or ""), #gInFlight.rx)
  -- Complete early when Content-Length says we have the whole body; otherwise wait for
  -- the close (handled in OnConnectionStatusChanged).
  local code, body, clen = ParseHttpResponse(gInFlight.rx)
  if code and clen and body and #body >= clen then
    HttpApiFinish(code < 400, body, "HTTP " .. code)
  end
end

-- Director calls this whenever a binding is bound or unbound.  The driver had no way to know
-- whether its IR output was actually attached, which is precisely the question a silent emitter
-- raises -- and Composer's Connections view cannot answer it, because that view is the project's
-- intent while this is the runtime's state.
function OnBindingChanged(idBinding, class, bIsBound)
  gBindings[idBinding]     = bIsBound
  gBindingClass[idBinding] = class
  LogDebug("OnBindingChanged: binding=%s class=%s bound=%s",
    tostring(idBinding), tostring(class), tostring(bIsBound))
  if idBinding == IR_BINDING then
    -- Unsilenceable: if the IR binding drops, every IR command silently stops working, and
    -- there is no other symptom to notice.
    LogCritical("IR binding %s is now %s (class %s).", tostring(idBinding),
      bIsBound and "BOUND" or "UNBOUND", tostring(class))
  end
end

function ReceivedFromProxy(idBinding, sCommand, tParams)
  LogTrace("ReceivedFromProxy: binding=%s cmd=%s", tostring(idBinding), tostring(sCommand))
  if idBinding == RECEIVER_BINDING then
    local h = ReceiverCommands[sCommand]
    if h then
      h(tParams)
    else
      -- Unsilenceable, once per command name per load.  "The UI button did nothing" and "the
      -- driver never implemented that button" are the same experience from the outside, and
      -- the default Log Mode = Off made the difference invisible.  Deduped so a proxy that
      -- repeats an unknown command cannot flood the director log.
      if not gUnhandledProxyCmds[sCommand] then
        gUnhandledProxyCmds[sCommand] = true
        LogCritical("Receiver proxy sent '%s', which this driver does not implement -- that " ..
          "button will do nothing. (Reported once per driver load.)", tostring(sCommand))
      end
    end
  else
    LogWarning("ReceivedFromProxy: unknown binding %s", tostring(idBinding))
  end
end

LogCritical("driver.lua loaded: Yamaha YAS-209 @BUILD@")
