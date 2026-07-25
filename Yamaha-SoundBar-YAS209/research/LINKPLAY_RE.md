# YAS-209 local control — reverse-engineering playbook

**Status: SOLVED + validated on real hardware (2026-07-25).** Full authenticated local control of
the YAS-209 (power/input/volume/everything) is achievable over IP. This doc is the reproducible
playbook — the same method applies to most Linkplay/WiiMu-based devices (the YAS-209's network
module is Linkplay, not Yamaha MusicCast).

## TL;DR
- The YAS-209 is **not** MusicCast/YXC. Its network module is **Linkplay (WiiMu)**.
- Two local control surfaces:
  1. **UPnP MediaRenderer** on `:49152` (plain HTTP, no auth) → **volume, mute, transport** only.
  2. **Linkplay httpapi** on `:443` (**mutual-TLS**, client cert required) → **everything incl. power + input**.
- The httpapi client cert is embedded in the "Sound Bar Controller" app behind three layers
  (XOR + AES + signature-binding). All cracked; credentials below.

## Device port map (this unit, IP 192.168.1.214)
| Port | Role |
|---|---|
| 80 | closed |
| 443 | Linkplay httpapi over **mutual-TLS** (cert `CN=www.linkplay.com`) — the local control channel |
| 8819 | `communication_port` (Linkplay internal) |
| 8899 | `uart_pass_port` |
| 49152 / 59152 | UPnP MediaRenderer (AVTransport / RenderingControl / ConnectionManager + wiimu PlayQueue) |
| 55443 | Alexa (`WHALEXA`) mutual-TLS endpoint (not needed) |

`getStatusEx` reports `"security":"https/2.0"` — this drives the app to require the **new** client cert (see below).

## UPnP path (no auth) — `:49152`
SOAP over HTTP. Confirmed working:
- `RenderingControl` (`/upnp/control/rendercontrol1`): `GetVolume`/`SetVolume`, `GetMute`/`SetMute` (volume is **0–100**, maps 1:1 to the C4 receiver proxy).
- `AVTransport` (`/upnp/control/rendertransport1`): `Play`/`Pause`/`Stop`/`Next`/`Previous`, `GetTransportInfo`, `GetPositionInfo`, `GetMediaInfo` (metadata only reflects network/DLNA playback, not HDMI/TV sources).
- **No** power or input action exists in any UPnP service (enumerated all SCPDs).

## httpapi path (mutual-TLS) — `:443`
Base: `https://<ip>/httpapi.asp?command=<cmd>`. Requires a client cert signed by the **capital-L
`O=Linkplay`** CA. TLS is legacy — use OpenSSL 3 (`brew install openssl@3`); macOS LibreSSL fails the
handshake. Confirmed commands (read): `getStatusEx`, `getPlayerStatus`. Control commands present in
the app: `setPlayerCmd:vol:<0-100>`, `setPlayerCmd:mute:<0|1>`, `setPlayerCmd:switchmode:<mode>`
(input), and power via `setShutdown:` / `MCUKeyShortClick:` (`CMD_POWER`, `NET_Standby`). *(Exact
power/input arg strings to be finalized while building the driver; not fired yet — bar was in use.)*

## The client-cert protection scheme (all three layers)
Source: app `com.wifiaudio.Yamaha` (a re-skinned Linkplay app). Pull the APK with `apkeep -a
com.wifiaudio.Yamaha -d apk-pure`, unzip the XAPK → base APK → `assets/` + `classes*.dex`; decompile
with `jadx`.

1. **Cert selection** (`DeviceRequest.getSSLSocketFactory`): if device `security != "https"` (ours is
   `https/2.0`) → use **`certificate_new`** (the app also ships the older `alice.p12` /
   `certificate_old`, signed by lowercase `O=linkplay` — the device **rejects** those with TLS
   `alert 48 unknown_ca`).
2. **XOR obfuscation:** the `assets/certificate_new` file is a PKCS#12 **XOR'd byte-wise with `0x02`**
   (deobfuscated header `30 82 0d a9` = valid DER, length matches).
3. **AES password:** the p12 password is **not** a literal. `DeviceSecurityConfig` computes it as
   `AES-128-CBC-NoPadding( base64(embedded_ciphertext), key, IV=0 )` where **key = first 16 chars of
   the app's own signing-cert SHA-1** (uppercase hex, colons removed). Anti-tamper: password is bound
   to the app signature.
   - App signing cert: `CN=uxyamaha, O=yamaha` (original, preserved by APKPure). SHA-1 =
     `1921b89705aa7bb264e50b81215d0b4f668495d8` → key16 = `1921B89705AA7BB2`.
   - **Gotcha:** compute the SHA-1 hex with real Java `String.format("%2x", aByte)` (it does **not**
     sign-extend Byte — an openssl/python hand-model got this wrong). The build's ciphertext branch
     was `e()==2` → `VQqzmp/l2XV76kN0SegAJA==`.
   - **Recovered password: `Link2018qpwo`**.

### Regenerate the client cert (reproducible)
```bash
# 1. de-obfuscate the asset
python3 -c "open('/tmp/certnew.p12','wb').write(bytes(b^2 for b in open('.../assets/certificate_new','rb').read()))"
# 2. open with the recovered password, extract cert+key to PEM
/opt/homebrew/opt/openssl@3/bin/openssl pkcs12 -in /tmp/certnew.p12 -passin pass:Link2018qpwo -legacy -nodes -out linkplay_client.pem
# 3. use it as a mutual-TLS client cert:
printf 'GET /httpapi.asp?command=getStatusEx HTTP/1.1\r\nHost: <ip>\r\nConnection: close\r\n\r\n' \
 | openssl s_client -connect <ip>:443 -cert linkplay_client.pem -key linkplay_client.pem -cipher 'DEFAULT@SECLEVEL=0' -quiet -ign_eof
```
Extracted key material lives in `research/linkplay_keys/` (**gitignored** — do not commit the
redistributed cert; regenerate via the steps above).

## Control4 driver design (decided with owner)
**Umbrella "Yamaha Soundbar" driver:** one driver; Properties pick (a) the **model** (YAS-209 now,
others later) and (b) the **control method** — IP / IR / Serial. **Default = IR** (safe, universal;
programmed later). IP method:
- **Volume / mute / transport →** UPnP (`:49152`, no auth). Volume 0–100 ↔ receiver proxy.
- **Power / input →** Linkplay httpapi (`:443`, mutual-TLS with the extracted client cert).

### "Owner Approved" toggle mechanic (REUSABLE PATTERN)
Any capability that relies on a **gray-area technique** (here: bundling Linkplay's extracted client
cert to reach the httpapi) must sit behind an **`Owner Approved` boolean property, default `false`**.
- While `false`: the gray-area path is **disabled** — the driver still fully works via the
  non-gray paths (UPnP volume/mute/transport, and IR for power/input if wired).
- Flipping it to `true` is an explicit statement by the **equipment owner** (not the dealer) that
  they consent to the technique on their hardware. Only then does the driver enable the httpapi
  power/input path.
- Rationale: on a client site the dealer shouldn't silently enable owner-questionable behavior;
  this puts the consent decision with the owner. It's the general pattern for **every** future
  "pushing the hardware past vendor locks" feature in this repo, not just this driver.

## Reusable method summary (for the next locked device)
1. `nmap`/`nc` full port map → identify services.
2. UPnP `description.xml` (SSDP `M-SEARCH`) → enumerate services + SCPD actions (free volume/transport).
3. If control needs auth, grab the vendor app (`apkeep`), `jadx`-decompile, and trace the local
   request builder + its TLS/keystore setup.
4. Extract embedded certs/keys (watch for XOR/AES/signature-derived passwords); use **real Java** to
   replicate the app's exact crypto rather than hand-modeling it.
5. Validate with `openssl s_client -cert/-key` (OpenSSL 3 for legacy-TLS devices).
6. Gate anything gray behind the **Owner Approved** toggle.
