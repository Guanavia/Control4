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
handshake. Read: `getStatusEx`, `getPlayerStatus`, `YAMAHA_DATA_GET`.

**CONFIRMED command set (captured via mitmproxy from the live app, replayed + validated through the
extracted cert — power OFF/ON both returned `OK` on the real unit 2026-07-26):**
| Function | Command (`?command=`) |
|---|---|
| **Power ON** (wake) | `YAMAHA_DATA_SET:{"power saving":"1"}` (url-enc `YAMAHA_DATA_SET:{%22power%20saving%22:%221%22}`) |
| **Power OFF** (standby) | `YAMAHA_DATA_SET:{"power saving":"0"}` |
| **Input: HDMI** | `setPlayerCmd:switchmode:HDMI` |
| **Input: Bluetooth** | `setPlayerCmd:switchmode:bluetooth` |
| **Input: TV / Optical** | `setPlayerCmd:switchmode:optical` (the YAS-209's "TV" input = optical/ARC) |
| Volume (alt to UPnP) | `setPlayerCmd:vol:<0-100>` ; Mute `setPlayerCmd:mute:<0|1>` |

> The `setShutdown`/`getShutdown`/`getPowerSaving`/`lp.asp` paths are **"unknown command"/404** on
> this firmware — power is the Yamaha-specific `YAMAHA_DATA_SET` verb above, NOT the generic Linkplay
> shutdown. Capture method: mitmproxy `--mode regular --ssl-insecure --set client_certs=<dir>` (the
> app's TrustManager is trust-all, so no CA install needed; re-originate mutual-TLS upstream with the
> extracted client cert). Phone Wi-Fi proxy → Mac:8080.

## Validated FROM the Control4 driver (2026-07-27, real director, real bar)

The httpapi path above was originally proven from a Mac with OpenSSL. It is now **proven from
inside DriverWorks**: the mutual-TLS handshake succeeds, `getStatusEx` returns HTTP 200 (1598-byte
body), and **the full command set in the table above — power on/off and input select — is
confirmed working on the bar from Control4.** Details that only surfaced on the controller:

- **`C4:url()` can never do this.** No client-certificate support at all (verified against
  Control4's own `global/url.lua`). The working transport is a **raw SSL `network_connection`** —
  `driver.xml` binding 6002 / port 443, `classname SSL`, `method tlsv12`, `verify_mode none`
  (the bar's *server* cert is private-CA; verifying it would kill the handshake). The driver then
  speaks HTTP/1.1 over the socket itself.
- **The PLAIN private key works.** No `protected="True"` needed. That attribute is not a
  Control4-owned secret anyway — it merely makes Director call `GetPrivateKeyPassword(Binding,
  Port)` in the driver for a passphrase *we* choose. Encrypted-key build kept as a fallback
  (`ENCRYPT_KEY=1 ./build.sh`) but it was not required.
- **`certificate` / `private_key` / `cacert` may all be the same file** — the one-file
  `linkplay_client.pem` (leaf + issuing CA + key) serves all three.
- **A second network binding coexists fine** with the existing 6001 UPnP monitor binding.
- **Lua cannot inspect the bundled cert at all — stop trying.** `C4:ReadFile()` **does not exist**
  in DriverWorks (0 hits across Control4's published API — the same trap as `C4:Log`); wrapped in a
  `pcall` it fails silently. `C4:FileExists()` *does* exist but **also returns false** for a
  `.c4z`-bundled file. Both were observed reporting "cert missing" on runs whose handshake
  **succeeded**. Only Director can read inside the archive, using the paths in `driver.xml`. There
  is therefore no Lua-side probe that can tell the truth here — **the TLS handshake is the only
  real test**, and any cert-presence warning is a lie waiting to send someone down a false trail.
  Also never probe with `C4:FileOpen()` — it *creates* the file when missing, faking a pass.

- **`getStatusEx` is IDENTITY/CAPABILITY ONLY — it never reflects input or playback state.**
  Proven, not assumed: five captures taken at five different physical inputs were **identical
  except the clock** (65 of 66 fields), and the payload contains no `mode`/`source`/`input`/`eq`/
  `surround` key whatsoever. Input state lives in **`getPlayerStatus`** (`mode`). Don't re-test
  this.
- **Old Boa server behaviour holds:** send `Connection: close`, honour `Content-Length`, and treat
  the socket close as end-of-body.

### Device fingerprint (`getStatusEx`, this unit)
| Field | Value | Note |
|---|---|---|
| `project` / `priv_prj` | `YAS_109` | **Wrong/shared Linkplay project string** — do NOT use it to identify the model |
| `yamaha_model_name` | `YAS_209` | the trustworthy model field |
| `bt_name` | `YAS-209 Yamaha` | |
| `firmware` | `Linkplay.3.6.418924` | `Release 2022060308` |
| `mcu_ver` / `mcu_ver_customize` | `531` / `00.87_01.46_3.3.1.4_20.01.29_00.08_3.88.1_3.88.2` | DSP/MCU build stack |
| `uuid` / `upnp_uuid` | `FFB8F0020E742090E14BCD76` | stable device id, usable for discovery |
| `eth2` / `ETH_MAC` | `192.168.1.214` / `00:22:6C:FE:5E:DF` | this unit is on **ethernet**, not Wi-Fi |
| `preset_key` | `6` | 6 hardware presets exist — unexplored |
| `uart_pass_port` | `8899` | **UART passthrough to the MCU — the most promising unexplored surface** for DSP/sound-mode control that httpapi does not expose |
| `communication_port` | `8819` | Linkplay internal |
| `securemode` / `security` | `1` / `https/2.0` | forces the *new* client cert |
| `streams` / `capability` / `plm_support` | `0x65cb3fc` / `0x200a4000` / `0x4` | capability bitfields, not yet decoded |

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
