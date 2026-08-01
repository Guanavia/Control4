# Sharp LC-52LE64OU — TV driver patched with an optical audio output

Not our driver. This is Control4's stock `tv_ir_sharp_LC-52LE64OU [IR].c4i` with **one connection
added**, because the stock driver makes a soundbar impossible to sequence correctly.

## Why

Control4 has **no ARC connection class**. Verified two ways:

- Composer's own 295 built-in drivers use only `DIGITAL_COAX`, `DIGITAL_OPTICAL`, `STEREO`, `HDMI`,
  `AUDIO_SELECTION`, `AUDIO_VOLUME`.
- The online catalog returns **0 drivers** for `*ARC*`, `HDMI_ARC`, `ARC` or `EARC`, against
  **18,841** for `DIGITAL_OPTICAL`.

So HDMI ARC is invisible to Control4 — it can only happen via CEC, outside the system's knowledge
or sequencing. That is the real reason "use optical instead of ARC" is the standard advice, and it
is not because ARC is flaky.

The stock Sharp driver then makes it worse: it declares **`audio_provider_count = 0`** and has no
audio output connection at all. With no bindable TV audio output, Control4 cannot see a path from
the television to a soundbar, so when a source wired straight to the TV is selected it sends the
soundbar **only volume and mute** — no power, no input select. The soundbar sits on whatever input
it was last on and the room shows the wrong source.

## What changed

| | Stock | Patched |
|---|---|---|
| `audio_provider_count` | `0` | `1` |
| Audio output connection | none | `4000 OPTICAL OUT (to soundbar)`, class `DIGITAL_OPTICAL` |
| `<version>` | 1 | 2 |
| `<name>` | Sharp LC-52LE64OU | Sharp LC-52LE64OU **[IR + Optical Out]** |

All 87 IR codes are untouched. The connection's shape is copied verbatim from a shipping driver
(`dvd_ir_samsung_dvd-hd841.c4i`) rather than invented.

## Before using it — the trade-off

The LC-52LE640U's manual states its optical output **"outputs in 2-ch stereo when from external
equipment connected using an HDMI cable"**. So audio from an HDMI source reaches the soundbar as
**stereo, downmixed** — no Dolby Digital or DTS.

That means this patch buys Control4 visibility and correct input sequencing **at the cost of
surround** for anything plugged into the TV.

**The alternative that keeps surround:** put the source that actually has audio through the
soundbar's own HDMI input, and run the source that does not (a Control4 controller's on-screen
navigator) straight to the TV. Then the soundbar is genuinely in the path, Control4 sequences it
without any driver patching, and the audio stays untouched. The YAS-209 has only one HDMI input, so
only one source can take that route.

## Installing

Adding a connection is a **structural** change, so Composer will ask to restart Director. Back the
project up first, and prefer the restart over remove/re-add — a re-add discards bindings and resets
every property.
