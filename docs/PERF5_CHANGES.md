# perf5 — the multi-second trace lag: root cause and fix (2026-07-10)

## Symptom

On perf4 the UI was responsive and trigger sync solid, but the *content* of
the trace lagged reality by 3–10 seconds: change the input frequency or the
timebase and the display kept showing the old signal for seconds.

## Root cause (found in code, confirmed by simulation)

`ingen.py`'s `recv()` read the ingen socket **one byte per syscall**
(`sock.recv(1)` with a `settimeout` per byte). A scope frame is ~2 KB, so at
24 frames/s the receive thread needed ~100k syscalls/s — more than it can
sustain on this CPU while sharing the GIL with the UI loop. Its actual
capacity was ~20.5 frames/s (the `recv/2s≈41` in the perf4 logs) against 24
produced, so the **kernel socket buffer** (~200 KB ≈ ~100 frames ≈ ~5 s)
silently filled and stayed full. Every frame the UI rendered was already
seconds old when Python first saw it; every input change had to flush
through that stale pipe at ~20 fps.

This is why the perf4 log looked healthy while the scope felt seconds
behind: `queue=0-4` measured the *downstream* ui_messages queue (drained and
coalesced instantly, as designed). The backlog lived upstream of every
metric we had.

## What changed

### ingen_wrapper.py (ingen.py stays untouched at the 407 baseline)

- **Bulk reads**: new `_recv_messages()` reads 64 KB per syscall, splits on
  the protocol's null terminators, reassembles partial messages across
  reads. Receive capacity goes from ~20 fps to effectively unbounded for
  this stream — the socket buffer stays empty, so display latency collapses
  to ~1 frame.
- **Receive-level coalescing**: if a batch still contains several scope
  frames (catch-up burst, e.g. right after boot or a preset load), only the
  newest is JSON-parsed and hex-decoded; stale ones are counted and skipped.
  All non-scope messages are always processed in order.
- The drain uses `select()` with zero timeout rather than flipping the
  socket non-blocking, because the send thread shares the socket object.

### show_widget.py — extended USB logging (the "see what's happening" ask)

New fields in the 2 s log line:
- `sockq=` — bytes pending in the kernel buffer of the ingen socket
  (FIONREAD). **This is the latency gauge**: ~2 KB ≈ 1 frame ≈ 40–60 ms of
  staleness. Expect ~0 after this fix; sustained growth means the receive
  thread fell behind again.
- `rxskip/2s=` — stale frames skipped at the receive stage.
- `t=` — monotonic timestamp per line.

Logging robustness: lines are now always kept in a ~20-minute RAM ring and
flushed to `/usb_flash/scope_perf.log` when a USB is inserted (marker line
with the build tag, backlog first, then live). You can reproduce a problem
FIRST and insert the stick AFTER — the history is still captured. No USB =
no disk writes at all (zero flash wear; deliberately NOT a RotatingFileHandler
on `/pedal_state`, which would wear persistent flash and add UI-thread I/O).

### Versions

`PACKAGE_VERSION = "perf5"`, `scopeBuild: "perf5"`. USB payload rebuilt;
45/45 installer tests pass; receive path verified against a socketpair
simulation (60-frame backlog drained in one call, newest frame + all
control messages preserved, partial-message reassembly, EOF).

## Review of the external (Gemini) analysis

Kernel of truth: there IS a producer/consumer deficit and the fix must
decouple display from production. But the located bottleneck and most
patches don't survive contact with the code:

1. **"UI queue grows unbounded → 13 s behind"** — contradicted by the log it
   analyses: `queue=0-4` throughout, because `coalesce_ui_messages` already
   drops all-but-newest per drain. The QML "latestFrames + Timer frame
   dropping" patch re-implements coalescing that has existed since perf1,
   one layer lower.
2. **`drift_max=16` read as "16 frames behind"** — that column is the
   trigger-alignment metric, in *samples*, capped at ±16 by `_SYNC_MAX_LAG`.
   Unrelated to latency.
3. **"Decimate canvas paths — thousands of sub-pixel points"** — frames are
   192 samples drawn across ~1050 px; there are ~5 px between points. Their
   own formula yields `step=1`, a no-op.
4. **"Cap process_ui_messages at 50 messages"** — with coalescing in place
   the queue holds ~1 frame; a cap does nothing. Worse, their sketch
   processes the *oldest* 50 and leaves the newest queued — it would add
   latency under load, not remove it.
5. **"Let the C++ scopeFrames QObject intercept scope_frame; recv thread
   only to `pass`"** — there is no C++ layer (`scopeFrames` is a Python
   QObject) and the handler calls `set_frame`, not `pass`. The salvageable
   idea — handle scope frames as early as possible — is what perf5's
   receive-level coalescing actually does.
6. **"atom:Vector / shm instead of atom:String"** — ingen serialises client
   events to JSON text; a float vector would serialise as a huge JSON array
   (likely *worse* on the wire than compact hex). shm is heavy surgery that
   the measured numbers don't justify: post-fix decode cost is ~0.3 ms per
   displayed frame. Revisit only if evidence ever points here.
7. **RotatingFileHandler on `/pedal_state` + global debug_print override** —
   continuous DEBUG logging onto persistent flash wears it and adds blocking
   I/O to the UI thread. perf5 keeps zero-wear USB-gated logging but adopts
   the spirit: RAM-ring backlog + timestamps + the metrics that actually
   discriminate hypotheses (`sockq`).

## How to verify on the device

1. Install from the USB (Settings → QA CHECK → Run debug); SETUP must show
   **polyscope perf5**.
2. Felt test: wiggle the input frequency / step the timebase — the trace
   should follow within ~0.1–0.2 s.
3. Log test (USB with no `debug.sh`): `sockq` ≈ 0–4096 and stable;
   `recv/2s` ≈ 48 (or steady at the plugin's true production rate);
   `rxskip/2s` ≈ 0 in steady state (>0 only in catch-up bursts);
   `painted/2s` unchanged (~30-34) — rendering was never the lag.
4. If `sockq` still climbs: the receive thread is starved some other way —
   the new fields will show it directly.

## Remaining perf5+ candidates (unchanged from perf4 doc)

Plugin-measured frequency (readout aliasing), 12-bit wire format, GPU canvas
if device GL is confirmed, delete dead `qml/ScopePreview.qml`.
