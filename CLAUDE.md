# Control4 Drivers Repo

Monorepo for all Control4 DriverWorks drivers built by Dave Woychek (david@propertyrenewal.llc).

## Repo conventions

- **One subfolder per driver.** All of a driver's source, docs, and research notes live in its folder (e.g. `nv_shield_tv/`, `sonoff_snzb02p/`).
- A `.c4z` file is just a **zip of the driver folder's contents** (files at zip root, not nested in a folder). `build.bat` / `build.ps1` are Windows scripts currently hardcoded to `nv_shield_tv`.
- Standard driver folder layout:
  - `driver.lua` — driver logic
  - `driver.xml` — driver metadata/config (devicedata XML)
  - `www/documentation.rtf` — dealer-facing docs shown in Composer
  - `www/icons/device_sm.gif`, `www/icons/device_lg.gif`, `www/icons/device/*.png`

## Drivers

### nv_shield_tv
NVIDIA Shield TV IP driver. Pre-existing, working. Built artifacts `nv_shield_tv-dmw.c4z` (own build) and `nv_shield_tv-fordev.c4z` at repo root.

### sonoff_snzb02p — CLOSED, no custom driver (research-only folder)
Original goal: get a Sonoff SNZB-02P temperature/humidity/battery sensor into Control4 for
dashboards, programmable threshold notifications, and history over time.

**Outcome (decided 2026-07-07): not building this.** A stock SNZB-02P cannot pair to a
Control4 zigbee mesh at all — see `sonoff_snzb02p/RESEARCH.md` for the full technical
reasoning (Control4's proprietary 0xC25D identify/product-string binding mechanism, which
stock Zigbee 3.0 firmware never speaks; plus C4's Zigbee 3.0 mesh currently only admitting
Control4 Lux lighting). Zigbee2MQTT was also considered as a bridge and ruled impractical for
this use case (see RESEARCH.md's mesh-topology section) in favor of the option below.

**Going with instead: Shelly H&T Gen3 (WiFi, battery) + Chowmain's Shelly Suite driver**
(https://chowmain.software/drivers/control4-shelly-generic — Dave is an authorized Chowmain
dealer). Works because the Shelly is a plain WiFi/IP device; DriverWorks IP drivers face none
of the zigbee gatekeeping. Battery life is worse than zigbee (~18mo vs ~4yr) but acceptable for
this scale. No driver-development work needed for the sensor itself.

**Remaining possible follow-on work** (not started): threshold-notification programming in
Composer, and a history/dashboard layer for long-term trends, once Shelly hardware + Chowmain
license are in place.

## Reference docs (Control4 DriverWorks)

- DriverWorks repo: https://github.com/snap-one/docs-driverworks
- API reference: https://snap-one.github.io/docs-driverworks-api
- Driver XML reference: https://snap-one.github.io/docs-driverworks-xml
- Fundamentals: https://snap-one.github.io/docs-driverworks-fundamentals/
- Zigbee implementation guide: https://snap-one.github.io/docs-zigbee
- Proxy protocol docs (per-proxy): linked from the DriverWorks README
