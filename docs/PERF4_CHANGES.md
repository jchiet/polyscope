# perf4 — layered rendering + threaded trace paint (2026-07-10)

## Why

The instrumented perf logs (perf1–perf3) proved the QML Canvas software paint is
the wall: `paint_ms ≈ 130–195` on busy 4-channel waveforms vs `proc_ms ≈ 25–38`,
collapsing the trace to 1–3 fps *and freezing the whole UI* (knobs, touch,
pages) because rasterisation ran on the GUI thread inside `processEvents()`.
The perf3 log showed `shown/2s` dropping to 2–6 on busy content while `recv/2s`
held steady at ~48 (24 Hz notify).

Two separate problems, two separate fixes:

1. **Stutter** (UI freezes during paint) → move rasterisation off the GUI thread.
2. **Low trace fps** (paint cost) → stop repainting what didn't change.

## What changed

### Polyscope.qml (`scopeBuild: "perf4"`)

- **Layered canvases.** `gridCanvas` (background, row shading, graticule,
  ruler baseline) repaints only on control/layout changes. `chart` (traces,
  envelope, hold markers, trigger guide, cursors) is transparent and repaints
  per frame over a `clearRect`. Previously every frame re-rasterised the full
  background + 4 grids + ~30 text strings.
- **`chart` uses `renderStrategy: Canvas.Threaded`.** The stroke rasterisation
  (the 130–195 ms) now runs on a worker thread; the GUI thread stays
  responsive. Escape hatch: set `threadedTracePaint: false` at the top of
  Polyscope.qml to fall back to the perf2 single-thread path.
- **All numeric readouts are QML `Text` elements** (scene-graph cached glyphs)
  instead of canvas `fillText`. They update from `traceStats` on a ~5 Hz beat
  (`statsIntervalMs: 200`) — like a bench scope's measurement refresh — which
  also stops the numbers flickering unreadably at frame rate.
- **Stats pipeline**: single-pass min/max/mean/rms loop (was 6 passes × 4ch),
  DC-coupled traces skip the per-frame copy, envelope + hold markers +
  XY correlation refresh on the stats beat.

### show_widget.py

- `painted/2s` added to the USB perf log: counts real `chart` paints (with a
  threaded canvas, `shown/2s` only counts handoffs to QML, not screen updates).
- The diagnostic sync-metric (O(lags×samples) pure-Python search per frame) now
  runs **only while a USB is mounted** (cached flag, refreshed every 2 s by the
  perf-logger thread).

### scope_util.py

- Hex decode uses a 256-entry float lookup table (less GIL time stolen from the
  UI loop by the recv thread). Covered by existing tests.

### Installer

- `PACKAGE_VERSION = "perf4"`, USB payload rebuilt, all 45 installer tests pass.

## How to verify on the device

1. Install from `dist/hector-scope-usb-v2/` (Settings → QA CHECK → Run debug).
2. SETUP page must show **polyscope perf4**.
3. Empty-USB perf log (USB with *no* `debug.sh`), worst-case busy waveform,
   all 4 channels visible, ~60 s. Compare to `perf3_scope_perf.log`:
   - `painted/2s` is the true trace fps — expect a clear rise vs perf3's
     `shown/2s` 2–6 worst case.
   - `paint_ms` (GUI-thread event time) should drop hard — that is the
     stutter fix, independent of trace fps.
   - Knob/touch responsiveness while a busy waveform renders is the felt test.
4. If the trace canvas renders blank/garbled (threaded-canvas incompatibility
   with the device Qt build): set `threadedTracePaint: false` in
   `/home/debian/UI/qml/Polyscope.qml`, restart UI, re-test. Layering + text
   offload still apply in that mode.

## Known remaining limits / candidates for perf5

- Worst-case trace stroke cost is inherent to software rasterisation
  (arc-length × lineWidth); a buzzsaw across 4 channels still costs what it
  costs — it just no longer blocks the UI. GPU path (FramebufferObject /
  scene-graph geometry) would need confirmation of GL on the device first.
- 8-bit sample depth (hex wire format) shows quantisation stair-stepping at
  high volts/div zoom. A 12-bit packing would be a wire-format bump (PSCP|2).
- `estimateFrequency()` in QML point-samples and aliases on fast signals; the
  proven fix from the reverted min/max experiment is measuring frequency in the
  plugin from the full-rate signal (see memory: hectorscope-flipping-bug).
- `qml/ScopePreview.qml` is dead code (never instantiated) — candidate for
  removal in a cleanup pass.
