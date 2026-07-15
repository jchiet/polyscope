# HectorScope

A four-channel digital oscilloscope for the **Poly Effects Hector** eurorack
module. Community firmware patch: a custom full-screen scope UI, a new LV2
scope plugin, and a checksum-gated USB installer with full backup/recovery.

> **Current stable: `v1.2.0-perf8`** — grab the installer from the GitHub
> release assets. Previous fallbacks: `v1.1-perf7-stable`, `v1.0-perf5-stable`.

## Features

- **4 input channels** with direct thru outputs (patch signals through the
  scope without losing them)
- **Views:** per-channel STACK, combined OVERLAY, and XY (CH1/2 or CH3/4)
  with live correlation readout
- **Timebase** 0.5–100 ms/div · **Scale** 0.5–10 V/div · per-channel
  **AC/DC coupling** and visibility
- **Triggering:** AUTO / RISE / FALL / **ROLL** (free-running right-to-left
  scroll — the best view for slow CV and evolving signals), adjustable level
  with optional auto-tracking, per-channel sync source, and **trigger
  holdoff** (1–500 ms) for locking onto complex, multi-edge waveforms
- **HF DETAIL anti-alias envelope:** under-sampled high-frequency content is
  drawn as an honest min/max band (recorded at full sample rate in the
  plugin) instead of a misleading aliased waveform
- **Alias-free measurements:** frequency is measured in the plugin from the
  raw full-rate signal; per-channel pp / rms / min / max / period readouts
- **Persistence** (5 levels) with afterglow envelope, **intensity** control,
  **measurement cursors** (fullscreen), **AUTOSET**, **FREEZE/RUN**, and a
  fullscreen trace viewer (tap the trace)
- Engineered for responsiveness on the Hector's CPU: threaded trace
  rendering, layered static/dynamic canvases, bulk socket ingest —
  sub-200 ms input-to-display latency at roughly 8–12 fps

## Requirements

- Poly Effects **Hector** on **firmware 407** — the installer verifies every
  file against the 407 baseline checksums and refuses to touch anything
  else, so a mismatched firmware aborts cleanly before any change
- A **FAT32 USB stick**

## Install

1. Download `HectorScope-USB-installer-…zip` from the latest release and
   unzip it.
2. Copy the **contents** of `hector-scope-usb-v2/` to the **root** of a
   FAT32 USB stick (so `debug.sh` and `hector-scope-patch/` sit at the top
   level).
3. Insert the stick into Hector, then: **Settings → QA CHECK → Run debug.**
4. Wait for the install to finish and the module to restart.
5. Verify: open the scope module, go to **SETUP** — the footer must read
   **polyscope perf8**.

The installer backs up every original file on the device *and* onto the USB
stick before changing anything, verifies every write, and rolls back
completely on any failure.

### Uninstall / recovery

- The release also ships a **recovery USB** zip: prepare a stick the same
  way and run it via QA CHECK to restore the pristine firmware-407 files
  from any state.
- The install stick keeps a copy of the original files under
  `hector_scope_originals_backup/` as an extra safety net.

## Mini manual

**Main page** — trace area (tap it for fullscreen), bottom bar with
RUN/FREEZE, CLEAR, TIME −/+, SCALE −/+, view selector (STACK / OVR / XY12 /
XY34) and SETUP. Right column: per-channel ON, SYNC (trigger source) and
OPTIONS (coupling, stats).

**SETUP page** — trigger mode/source/level (with AUTO level tracking),
**TRIGGER HOLDOFF** in ms (OFF = classic trigger; set just below your
pattern's repeat period to lock complex waveforms), persistence, intensity,
**HF DETAIL** on/off, AUTOSET, and the build tag.

**Reading tips**

- Fast audio on a slow timebase? The dim band around the trace is the
  **HF envelope** — the true amplitude of content too fast for the point
  trace. The Hz readout stays correct regardless (measured at full rate).
- Watching sequences, LFOs, envelopes evolve? Use **ROLL** trigger mode —
  the trace streams right-to-left continuously.
- Jumpy display on a complex repeating waveform? Raise **HOLDOFF** until it
  locks. Keep it OFF for simple periodic signals.
- **Cursors** live in the fullscreen view (CURSORS button, drag A/B for
  Δt / ΔV / frequency readouts).

## Performance logging (for bug reports)

Insert a FAT32 USB stick **without** `debug.sh` on it while the scope is
running: the UI appends a metrics line to `scope_perf.log` every 2 s
(receive rate, painted fps, queue depths, worst-case loop times, trigger
stability). The last ~20 minutes before insertion are included
retroactively. Attach that file to any issue.

## Building from source

Everything ships in this repo: `source/` holds the patched UI
(`digit_ui/`) and the LV2 plugins (`PolyLV2/poly_scope2.lv2` is the active
scope). `build_scope_usb_v2.sh` cross-compiles the plugins (zig + lv2
headers + llvm-strip) and produces `dist/hector-scope-usb-v2/` (installer)
and `dist/hector-scope-recovery-usb-v2/` (recovery). The test suites
(`test_coalesce.py`, `test_scope_installer.py`) cover the wire protocol and
the full install/rollback state machine. Note: regenerating the
installer's baseline checksums requires a pristine firmware-407
`digit_ui` git baseline (not shipped here) — the prebuilt `dist/`
installer in this repo and in the release assets is ready to flash,
and the LV2 plugins alone rebuild with their Makefiles.

Engineering history — how the latency and rendering bottlenecks were found
and fixed — is documented in `docs/PERF4_CHANGES.md` and
`docs/PERF5_CHANGES.md`.

## License, attribution, disclaimer

This project modifies and redistributes source from **Poly Effects**
(`digit_ui`, `ingen` fork) under their open-source licenses; the scope LV2
plugins are original work licensed **GPL-2.0-or-later**; the patch set as a
whole is distributed under the **GPL-3.0**. See `LICENSE`.

This is a community project, **not affiliated with or endorsed by
Poly Effects**. Flashing modifies files on your device — the installer is
checksum-gated and fully reversible, but you use it at your own risk.
