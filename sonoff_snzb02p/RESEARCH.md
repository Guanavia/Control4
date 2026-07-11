# SNZB-02P → Control4: Research Findings (2026-07-07)

Goal: report temperature, humidity, and battery from a Sonoff SNZB-02P into Control4 for
dashboards, programmable threshold notifications, and status history over time.

## 1. The blocker: stock SNZB-02P cannot pair to a Control4 zigbee mesh

Control4 runs two kinds of zigbee mesh, and the stock sensor is locked out of both:

### Legacy Zigbee Pro mesh (what DriverWorks zigbee drivers talk to)
Per the [Zigbee Implementation Guide](https://snap-one.github.io/docs-zigbee):

- Joining is open-ish (the C4 trust center alternates sending the network key encrypted and
  in the clear to admit legacy devices), so the SNZB-02P may well *join* at the network layer.
- But **driver binding requires the device itself to broadcast Control4's proprietary
  "Identify" packet**: a ZCL attribute report on **profile 0xC25D, cluster 0x0001**
  (the "Control4 Network Cluster", internally "SSCP") to short address 0xFFFC, containing at
  minimum DEVICE_TYPE, ANNOUNCE_WINDOW, MTORR_PERIOD, FIRMWARE_VERSION, and a
  **PRODUCT_STRING that must match the driver's `<search_types><type>` string**. This is what
  populates Composer's Identify window and binds node → driver.
- Staying "online" requires periodic unicast announces of the same cluster attributes; devices
  that don't announce are marked offline by ZServer.
- These are **device firmware behaviors**. Stock Sonoff firmware (standard Zigbee 3.0 / ZCL)
  never sends any 0xC25D traffic, so Composer will never see the sensor to identify it, and no
  DriverWorks zigbee driver can ever be bound to it. There is no manual-EUI64 bind path.

### Zigbee 3.0 mesh (OS 3.4+/X4, CORE controllers)
Per [Snap One Lux docs](https://help.snapone.com/lux-qs/Content/System%20Design%20Topics/Zigbee%203%20and%20Legacy.htm):
"At this time, only CORE controllers can act as Zigbee 3.0 mesh controllers, and Control4 Lux
lighting is the only Zigbee 3.0 device that can join." Also: one controller cannot host both
Zigbee Pro and Zigbee 3.0. So no third-party Zigbee 3.0 devices, period (as of the doc's writing).

**Conclusion:** a "pure Control4 zigbee" driver for a *stock* SNZB-02P is not viable. The
DriverWorks zigbee Lua API is fine — the device side of Control4's protocol is what's missing.

## 2. DriverWorks Zigbee Lua API (for reference — usable if device firmware were C4-aware)

From the [API reference](https://snap-one.github.io/docs-driverworks-api), "Zigbee Interface"
section (available since SDK 1.6.0/1.6.1):

- `C4:SendZigbeePacket(strPacket, nProfileID, nClusterID, nGroupID, nSourceEndpoint, nDestinationEndpoint)`
  — send raw ZCL frame to the bound node (ZigBee Pro format; profile/cluster/endpoints honored on Pro).
- `OnZigbeePacketIn(strPacket, nProfileID, nClusterID, nGroupID, nSourceEndpoint, nDestinationEndpoint)`
  — receive unsolicited/response frames.
- `OnZigbeePacketSuccess(...)` / `OnZigbeePacketFailed(...)` — delivery results.
- `OnZigbeeOnlineStatusChanged(strStatus, strVersion, strSkew)` — ONLINE/OFFLINE/REBOOT/UNKNOWN.
- `C4:GetZigbeeEUID()` — bound node's EUI64.
- OTA reflash: `C4:GetBlobByName`, `C4:RequestReflashLock`/`KeepReflashLock`/`ReleaseReflashLock`,
  `OnReflashLockGranted`/`OnReflashLockRevoked`; plus OS 3.3.2+ standard Zigbee OTA server via
  `zb = C4:RequireModule("zigbee")` (`zb:otaAddImage(...)` etc., images in `www/*.zigbee`).
- Driver XML: `<search_types><type>vendor:product_string</type></search_types>` under
  `<devicedata>` must equal the device's PRODUCT_STRING attribute (0x0006) in its Identify
  broadcast; `<combo>`, `<control>lua_gen</control>`, `<controlmethod>zigbee</controlmethod>`.

### How to read the API doc's "Zigbee Interface" intro (it sounds more open than it is)

The API reference opens the Zigbee Interface section with: support "delivered in release 1.6.1
... to provide information to Control 4 partners **already using the Zigbee SDK**", listing three
capabilities. Paragraph-by-paragraph:

- **Audience**: the "Zigbee SDK" is Control4's *embedded firmware SDK for device manufacturers*
  (Card Access/Axxess, lock vendors, etc.) — not DriverWorks and not Lua. The section describes
  the controller-side half of a hardware partnership; it presumes the device firmware was built
  to speak Control4's zigbee behaviors.
- **Bullet 1** ("send/receive data using either EmberNet or ZigBee Pro"): the raw packet API
  (`C4:SendZigbeePacket` / `OnZigbeePacketIn`). EmberNet is C4's legacy pre-Zigbee-Pro
  proprietary stack (Gen 1/2 hardware). Works only *after* a node is bound to the driver.
- **Bullet 2** ("update their ZigBee devices"): the reflash/OTA API. "Their" = partner-built
  devices.
- **Bullet 3** ("utilize the Control4 identification mechanism, but define their own ID
  strings"): sounds like an opening but is a namespacing concession, not a bypass. Partners
  still *utilize the Control4 identification mechanism* — the 0xC25D identify broadcast — and
  the flexibility is only that the PRODUCT_STRING content is vendor-defined (e.g.
  `acme:temp_sensor:v1`) and matched by the driver's `<search_types><type>`. The mechanism
  itself (device broadcasts proprietary identify; Composer matches string → driver) remains
  mandatory. A stock ZCL device broadcasts no ID string at all, so bullet 3 never comes into
  play.

### Note: C4's direction is Zigbee 3, not Zigbee Pro

Control4 has moved on from Zigbee Pro: the X4/CORE-controller era uses **Zigbee 3.0** meshes
(a controller hosts one or the other, not both). The DriverWorks zigbee interface above is the
*legacy* (EmberNet/Zigbee Pro) integration path. That makes a direct third-party zigbee driver
even less future-proof: the legacy path requires C4-aware device firmware, and the Zigbee 3
path currently admits only Control4 Lux lighting with no published third-party driver story.
If C4 ever opens Zigbee 3 to third-party ZCL devices, revisit — a stock SNZB-02P speaks
exactly the standard clusters that would need.

## 3. The sensor (SNZB-02P) — standard ZCL

Per [Zigbee2MQTT device page](https://www.zigbee2mqtt.io/devices/SNZB-02P.html) and Sonoff docs:

- Zigbee 3.0 sleepy end device, CR2477, manufacturer "eWeLink" / model "SNZB-02P", endpoint 1.
- Clusters: 0x0402 Temperature Measurement (`MeasuredValue`, int16, 0.01 °C),
  0x0405 Relative Humidity (`MeasuredValue`, uint16, 0.01 %RH),
  0x0001 Power Configuration (`BatteryPercentageRemaining` 0x0021, uint8, 0.5 % units;
  `BatteryVoltage` 0x0020).
- Reporting intervals configurable via standard ZCL Configure Reporting (min interval 5 s);
  temp/humidity calibration offsets supported by z2m converters.
- ±0.2 °C / ±2 %RH accuracy, ~4 year battery.

## 4. Viable architectures

1. **Bridge via Zigbee2MQTT (or Home Assistant/ZHA)** — RECOMMENDED.
   Sensor pairs to a standard zigbee coordinator (~$20–30 USB stick on any always-on box, or
   the HA box already present). DriverWorks **IP driver** (TCP, MQTT client in Lua — no
   cloud) subscribes to the sensor topics and exposes in C4: Temperature/Humidity/Battery
   variables + properties, programmer-settable thresholds firing C4 events (for notification
   agent / programming), history retention for dashboards. Reporting intervals configurable
   from the driver by publishing to z2m's `/set` config topics. Fully meets every stated
   requirement; sensor stays stock.
2. **Direct C4 zigbee driver** — only possible with custom C4-aware firmware on the sensor
   (it would have to implement the 0xC25D announce/identify state machine). No such firmware
   exists for the SNZB-02P; writing one is an embedded project, not a driver project.
3. **Use a Control4-certified sensor instead** (e.g. Axxess/Card Access wireless temp sensors)
   — existing drivers, native mesh, but different hardware and typically pricier/less accurate
   than the SNZB-02P.

## 5. Decision (2026-07-07): going with Shelly, not Sonoff

Dave is an authorized Chowmain dealer and already owns that relationship, so the pragmatic
choice is:

**Shelly H&T Gen3 (WiFi, battery) + Chowmain's Shelly Suite driver
(https://chowmain.software/drivers/control4-shelly-generic).**

Why this sidesteps everything in section 1: the Shelly is a **plain WiFi/IP device** — it joins
the regular LAN like any other IP device, not a zigbee mesh. DriverWorks IP drivers (TCP/HTTP)
have no equivalent gatekeeping to the zigbee identify mechanism; Chowmain's driver just talks to
the sensor's local API over the network. No certification, no product-string matching, no
mesh to join.

Two Shelly variants exist, both covered by Chowmain's suite:

- **Shelly H&T Gen3** — WiFi, 2× AAA. Self-contained, no gateway hardware needed. Chosen for
  the first install.
- **Shelly BLU H&T** — Bluetooth LE, CR2032, better battery life than the Gen3 (BLE draws far
  less power than a full WiFi join per wake-up) — but it requires a separate mains-powered
  Shelly device nearby (a plug, relay, or the Shelly BLU Gateway Gen3) to act as the BLE-to-IP
  bridge. Worth revisiting if battery life or WiFi coverage in the monitored boxes becomes a
  problem.

### Battery life comparison (why this tradeoff is worth it)

| Device | Radio | Battery | Rated life | Why |
|---|---|---|---|---|
| Sonoff SNZB-02P | Zigbee 3.0 | CR2477 | ~4 years | Zigbee mesh transmission is a brief radio burst; no WiFi-join overhead, and mains-powered mesh routers do the heavy lifting of relaying |
| Shelly H&T Gen3 | WiFi | 2× AAA | ~18 months | Reports on a 0.5 °C / 5% RH change threshold, or forced every 2 hours minimum; a full WiFi associate/connect/transmit cycle costs much more energy per wake than a zigbee or BLE transmission |
| Shelly BLU H&T | Bluetooth LE | CR2032 | ~3 years | BLE advertisement is far cheaper than WiFi, closing most of the gap to zigbee, at the cost of needing a gateway device |

Roughly a 2.5x battery-life hit choosing Gen3 WiFi over zigbee — acceptable for a small number
of sensors in boxes that already get checked periodically, not worth agonizing over unless the
deployment scales up significantly.

### Why "route the Sonoff over Zigbee2MQTT" doesn't get you a free ride on C4's existing mesh

Raised and settled during research: could a stock Sonoff join *Control4's* zigbee mesh and have
Zigbee2MQTT simply "listen in" on that traffic instead of pairing to its own coordinator?
**No.** A zigbee device joins one specific network at join time and receives that network's PAN
ID and encryption key as part of the handshake; from then on it can only communicate on that
PAN. Control4's mesh and a Z2M mesh are two independent networks with independent keys, even if
their radios physically overlap in the same building — there is no sniffing across networks.
So a Sonoff paired via Z2M joins the **Z2M coordinator's own separate network**, full stop,
regardless of proximity to C4 hardware.

Practical implication if this path is ever revisited: with just one or two sensors, that Z2M
network is a star topology (sensors talk directly to the coordinator dongle) — which is fine
functionally, since zigbee end devices work directly with a coordinator same as a WiFi client
talks directly to an access point. It only becomes a real multi-hop *mesh* by adding
mains-powered zigbee router devices (smart plugs, bulbs, dedicated repeaters) to that same Z2M
network — battery end devices like the SNZB-02P never act as routers themselves. If sensor
locations end up far from wherever the Z2M coordinator lives, the fix is adding a cheap
zigbee router to the Z2M network near them, not relying on C4's mesh (which is invisible and
unreachable to a Z2M-joined device no matter how close).

## Open questions — resolved

- ~~Is there an existing Home Assistant / Zigbee2MQTT / MQTT broker in the house?~~ No existing
  infra (confirmed 2026-07-07); moot now since Shelly needs none.
- ~~Which architecture to build?~~ Shelly H&T Gen3 + Chowmain driver (no custom driver needed
  for the sensor itself).

## Possible follow-on work

- Threshold-based notification programming in Composer once hardware is installed.
- A history/logging/dashboard layer for long-term temp/humidity/battery trends, if Chowmain's
  driver doesn't already provide sufficient history natively.
