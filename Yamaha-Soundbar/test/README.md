# Offline test harness

`simharness.lua` runs `driver.lua` with **no controller and no soundbar**. It stubs the
DriverWorks `C4` API and simulates the bar's SSL socket end to end —
`NetConnect` → `ONLINE` → `SendToNetwork` → `ReceivedFromNetwork(HTTP response)` → `OFFLINE` —
so it exercises the real httpapi transport, the HTTP parsing and the queue, not just the sweep
logic.

```bash
lua test/simharness.lua driver.lua <archetype> <action>
```

- **archetype** — how the simulated bar behaves: `clamp` (limits out-of-range writes to the
  nearest valid value), `reject` (keeps its previous value), `acceptall` (stores any string,
  including junk).
- **action** — any Composer Action name: `LearnSubwooferRange`, `LearnSoundPrograms`,
  `LearnInputCodes`, `ProbeSettings`, `TestHttpApi`.

The `acceptall` archetype exists to prove the negative controls fire. Running
`acceptall LearnSoundPrograms` must report **NEGATIVE CONTROL FAILED / INCONCLUSIVE** — if it ever
reports a clean all-pass, the control has stopped working and every sweep result is
unfalsifiable.

## Why this exists

Every hardware round trip on this project costs a driver rebuild, a Composer remove/re-add and a
trip to the bar. The sweeps are stateful async machines chaining dozens of requests, which is
exactly the kind of code that hangs or races. The harness caught **three real bugs that hardware
testing had not**:

1. **Stale-OFFLINE race.** The previous socket's close notification was being attributed to the
   next request, failing it with "socket closed with no response at all" moments before its reply
   arrived. Fixed with a settling gap (`PUMP_GAP_MS`) between requests.
2. **Cooldown raised too late.** The gap was set *after* the completion callback ran — and every
   sweep issues its next request from inside that callback, so the one request the gap existed to
   protect skipped it. Fixed by raising `gCooldown` before invoking the callback.
3. **Unreliable baseline.** The subwoofer sweep classified each probe by "did it change from what
   was there before", but never established what was there to begin with, making the negative
   control — which gates the whole sweep — a coin flip. Fixed with a baseline read.

Note that (1) and (2) are latent on real hardware: the timing happened to work on the bar, so the
sweeps produced correct results while silently logging failed writes. The harness makes them
deterministic.

`drain()` aborts on a timer storm, so an infinite loop in the driver fails the run instead of
hanging it.
