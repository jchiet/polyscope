"""v3 scope wire-format tests. The reference encoder here IS the spec: the C
plugin must produce packets this file's decoder round-trips within one LSB."""

import base64
import hashlib
import importlib.util
import math
import os

UI = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                  "source", "polyeffects-src", "digit_ui")
spec = importlib.util.spec_from_file_location(
    "scope_util", os.path.join(UI, "scope_util.py"))
scope_util = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope_util)

SAMPLES = 192
Q_STEP = 2.0 / 4095.0  # one 12-bit LSB in the [-1, 1] range


def _quantize12(v):
    v = max(-1.0, min(1.0, v))
    return max(0, min(4095, int(round((v * 0.5 + 0.5) * 4095.0))))


def _ref_encode_channel_v3(floats):
    """Reference v3 channel encoder (the wire-format spec)."""
    q = [_quantize12(v) for v in floats]
    packed = bytearray()
    i = 0
    while i + 1 < len(q):
        s0, s1 = q[i], q[i + 1]
        packed.append(s0 & 0xFF)
        packed.append(((s0 >> 8) & 0x0F) | ((s1 & 0x0F) << 4))
        packed.append((s1 >> 4) & 0xFF)
        i += 2
    if i < len(q):                      # odd tail (not hit at 192, kept for safety)
        s0 = q[i]
        packed.append(s0 & 0xFF)
        packed.append((s0 >> 8) & 0x0F)
    return base64.b64encode(bytes(packed)).decode("ascii")


def _make_v3_packet(channels, min_series=None, max_series=None):
    """channels: 4 float lists. min/max default to the point series (flat env)."""
    header = "PSCP|3|%d|110.00,220.00,330.00,440.00" % SAMPLES
    series = []
    for ch in range(4):
        point = _ref_encode_channel_v3(channels[ch])
        mn = _ref_encode_channel_v3(min_series[ch]) if min_series else point
        mx = _ref_encode_channel_v3(max_series[ch]) if max_series else point
        series += [point, mn, mx]
    return header + "|" + "|".join(series)


def test_v3_channel_roundtrip_within_one_lsb():
    original = [math.sin(2 * math.pi * n / 48.0) for n in range(SAMPLES)]
    encoded = _ref_encode_channel_v3(original)
    decoded = scope_util.decode_scope_frame_channel_v3(encoded, SAMPLES)
    assert decoded is not None
    assert len(decoded) == SAMPLES
    assert max(abs(a - b) for a, b in zip(original, decoded)) <= Q_STEP + 1e-9


def test_v3_odd_sample_count_roundtrip():
    original = [math.sin(2 * math.pi * n / 7.0) for n in range(5)]
    encoded = _ref_encode_channel_v3(original)
    decoded = scope_util.decode_scope_frame_channel_v3(encoded, 5)
    assert decoded is not None
    assert len(decoded) == 5
    assert max(abs(a - b) for a, b in zip(original, decoded)) <= Q_STEP + 1e-9


def test_v3_packet_decodes_to_v2_shape():
    chans = [[math.sin(2 * math.pi * n / (16.0 + ch)) for n in range(SAMPLES)]
             for ch in range(4)]
    result = scope_util.decode_scope_frame_packet(_make_v3_packet(chans))
    assert result is not None
    # 4 points + 4 mins + 4 maxes + 1 frequency list == 13 entries (same as v2)
    assert len(result) == 13
    assert result[12] == [110.0, 220.0, 330.0, 440.0]
    assert max(abs(a - b) for a, b in zip(chans[0], result[0])) <= Q_STEP + 1e-9


def test_v3_flat_envelope_is_suppressed_to_none():
    # min == max payload => decoder must emit None placeholders (GC win, and
    # Polyscope.qml relies on the null to skip the envelope overlay).
    chans = [[0.25] * SAMPLES for _ in range(4)]
    result = scope_util.decode_scope_frame_packet(_make_v3_packet(chans))
    assert result is not None
    assert result[4:12] == [None] * 8


def test_v3_distinct_envelope_is_decoded():
    chans = [[0.0] * SAMPLES for _ in range(4)]
    mins = [[-0.5] * SAMPLES for _ in range(4)]
    maxs = [[0.5] * SAMPLES for _ in range(4)]
    result = scope_util.decode_scope_frame_packet(
        _make_v3_packet(chans, mins, maxs))
    assert result is not None
    assert abs(result[4][0] - (-0.5)) <= Q_STEP
    assert abs(result[8][0] - 0.5) <= Q_STEP


def test_v3_golden_vector_is_pinned():
    """Pins the exact wire bytes for a known ramp. If this breaks, the wire
    format changed — that is a spec violation, not a test to update."""
    ramp = [(-1.0 + 2.0 * n / (SAMPLES - 1)) for n in range(SAMPLES)]
    encoded = _ref_encode_channel_v3(ramp)
    assert len(encoded) == 384        # same char count as today's v2 hex
    assert encoded[:32] == "AFABKwAEVrAGgWAJrBAM1sAOAXERLCEU"
    assert encoded[-16:] == "ae/3lJ/6v0/96v//"
    assert (hashlib.sha256(encoded.encode()).hexdigest()
            == "25070ddbce6c929c061199025e3b447fed35c597b4dedb5a993511bd6f4d2c1f")
    decoded = scope_util.decode_scope_frame_channel_v3(encoded, SAMPLES)
    assert max(abs(a - b) for a, b in zip(ramp, decoded)) <= Q_STEP + 1e-9


def test_v3_malformed_inputs_return_none():
    good = _ref_encode_channel_v3([0.0] * SAMPLES)
    assert scope_util.decode_scope_frame_channel_v3("*" * 384, SAMPLES) is None
    assert scope_util.decode_scope_frame_channel_v3(good[:-4], SAMPLES) is None
    assert scope_util.decode_scope_frame_channel_v3("", SAMPLES) is None
    # packet with a corrupted series must reject the whole packet
    chans = [[0.1] * SAMPLES for _ in range(4)]
    packet = _make_v3_packet(chans)
    parts = packet.split("|")
    parts[4] = "!!!!" + parts[4][4:]
    assert scope_util.decode_scope_frame_packet("|".join(parts)) is None
    # wrong series count
    assert scope_util.decode_scope_frame_packet(
        "|".join(packet.split("|")[:-1])) is None


def test_v1_is_rejected():
    # The legacy scope (v1 sender) was removed from the build; a stray v1
    # packet from an old on-device plugin must be dropped, never crash.
    hexmid = "80" * SAMPLES
    v1 = "PSCP|1|%d|%s|%s|%s|%s" % (SAMPLES, hexmid, hexmid, hexmid, hexmid)
    assert scope_util.decode_scope_frame_packet(v1) is None


def test_v2_is_rejected():
    # v2 (8-bit hex) support was dropped along with the rest of the
    # backwards-compat surface; the shipped plugin and UI are always
    # installed together, so only v3 is spoken.
    hexval = "%02X" % 200
    series = hexval * SAMPLES
    packet = "PSCP|2|%d|1.00,2.00,3.00,4.00|%s" % (
        SAMPLES, "|".join([series] * 12))
    assert scope_util.decode_scope_frame_packet(packet) is None


import shutil
import subprocess

PLUGIN_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "source", "polyeffects-src", "PolyLV2",
                          "poly_scope2.lv2")


def test_c_encoder_roundtrips_through_python_decoder():
    """Compile the plugin's encoder helpers on the host, encode a ramp, and
    decode it with the shipping Python decoder. Skipped when no C toolchain
    or LV2 headers are available."""
    import pytest
    cc = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
    if cc is None:
        pytest.skip("no C compiler on host")
    cflags = subprocess.run(["pkg-config", "--cflags", "lv2"],
                            capture_output=True, text=True)
    if cflags.returncode != 0:
        pytest.skip("lv2 headers not found via pkg-config")
    import tempfile
    # build into a temp dir so the plugin's build/ stays exactly what the USB
    # bundle script produces (its make clean rmdir chokes on stray files)
    exe = os.path.join(tempfile.mkdtemp(prefix="scope_v3_host_"),
                       "test_v3_encoder_host")
    compile_cmd = [cc, "-o", exe,
                   os.path.join(PLUGIN_DIR, "test_v3_encoder_host.c"),
                   "-lm"] + cflags.stdout.split()
    built = subprocess.run(compile_cmd, capture_output=True, text=True)
    assert built.returncode == 0, built.stderr
    encoded = subprocess.run([exe], capture_output=True, text=True,
                             timeout=10).stdout.strip()
    assert len(encoded) == 384
    ramp = [(-1.0 + 2.0 * n / (SAMPLES - 1)) for n in range(SAMPLES)]
    decoded = scope_util.decode_scope_frame_channel_v3(encoded, SAMPLES)
    assert decoded is not None
    assert max(abs(a - b) for a, b in zip(ramp, decoded)) <= Q_STEP + 1e-9
