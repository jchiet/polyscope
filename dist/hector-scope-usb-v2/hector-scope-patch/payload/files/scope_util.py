"""Qt-free helpers for the scope UI, kept separate so they are unit-testable
without importing PySide2."""

import base64
import binascii

SCOPE_PACKET_MAGIC = "PSCP"
SCOPE_PACKET_VERSION_3 = "3"
SCOPE_PACKET_CHANNELS = 4
SCOPE_PACKET_HEADER_FIELDS = 4      # magic | version | count | freqs
SCOPE_PACKET_SERIES = 3             # point, bucket-min, bucket-max
SCOPE_PACKET_MARKER = SCOPE_PACKET_MAGIC + "|"


def split_null_messages(buffer):
    """Split a bytearray of null-terminated ingen wire messages.

    Returns (messages, remainder): every complete message decoded as text, and
    the trailing partial message (no terminator yet) as a new bytearray. Used
    by the bulk-read receive path; one null-terminated chunk = one JSON doc.
    """
    messages = []
    start = 0
    while True:
        end = buffer.find(b"\0", start)
        if end < 0:
            break
        if end > start:
            messages.append(buffer[start:end].decode("utf-8", "replace"))
        start = end + 1
    return messages, bytearray(buffer[start:])


def stale_scope_frame_indices(messages):
    """Indices of scope-frame messages made obsolete by a newer one in the
    same batch.

    A batch holding several scope-frame notifies means the reader is catching
    up on a backlog; only the newest frame will survive the downstream
    per-effect coalescer, so the older ones can be skipped before the
    expensive JSON parse + hex decode. Scope frames are single-purpose
    patch:Set messages (nothing else rides along), and only one scope
    broadcasts at a time, so a batch-wide skip is safe; even with two active
    scopes the downstream coalescer keeps display correctness.
    """
    seen = [index for index, message in enumerate(messages)
            if SCOPE_PACKET_MARKER in message]
    return set(seen[:-1])


def coalesce_ui_messages(messages):
    """Drop all but the LAST scope_frame per effect.

    messages: list of UI messages (each a list/tuple; m[0] is the type).
    For entries with m[0] == "scope_frame", m[1] is the effect name; only the
    final frame per effect is kept, in the position of its last occurrence.
    All other messages are preserved in their original order.
    """
    last_index = {}
    for i, m in enumerate(messages):
        if m and m[0] == "scope_frame":
            last_index[m[1]] = i
    out = []
    for i, m in enumerate(messages):
        if m and m[0] == "scope_frame" and last_index.get(m[1]) != i:
            continue
        out.append(m)
    return out


def unwrap_json_turtle_value(value):
    if isinstance(value, list):
        if len(value) == 1:
            return unwrap_json_turtle_value(value[0])
        return [unwrap_json_turtle_value(v) for v in value]
    if isinstance(value, dict):
        for key in ("value", "@value", "rdf:value"):
            if key in value:
                return unwrap_json_turtle_value(value[key])
    return value


# All 4096 possible 12-bit codes, pre-mapped to [-1, 1]. Decoded frames hold
# references into this table, so steady-state decoding allocates list objects
# but no new float objects — which matters because this runs on a thread that
# shares the GIL with the UI loop.
_Q12_TO_UNIT = [(q / 4095.0) * 2.0 - 1.0 for q in range(4096)]


def decode_scope_frame_channel_v3(channel_payload, sample_count):
    """Decode one channel's base64 payload of packed 12-bit samples (2 samples
    per 3 bytes) to floats in [-1, 1]. Runs on the GIL-bound receive thread
    that gates the whole display rate, so the per-sample work stays in C via
    stride slicing + zip: measured ~4x the v2 fromhex cost (vs ~5x for a
    per-sample loop), ~0.16 ms per 12-series frame on a laptop.
    """
    expected_bytes = (sample_count * 3 + 1) // 2
    try:
        raw = base64.b64decode(channel_payload, validate=True)
    except (ValueError, binascii.Error):
        return None
    if len(raw) != expected_bytes:
        return None
    lut = _Q12_TO_UNIT
    pair_bytes = (sample_count // 2) * 3
    b0 = raw[0:pair_bytes:3]
    b1 = raw[1:pair_bytes:3]
    b2 = raw[2:pair_bytes:3]
    evens = [lut[x | ((y & 0x0F) << 8)] for x, y in zip(b0, b1)]
    odds = [lut[(y >> 4) | (z << 4)] for y, z in zip(b1, b2)]
    out = [0.0] * sample_count
    out[0:sample_count - (sample_count & 1):2] = evens
    out[1::2] = odds
    if sample_count & 1:                 # odd tail (never hit at 192)
        out[-1] = lut[raw[pair_bytes] | ((raw[pair_bytes + 1] & 0x0F) << 8)]
    return out


def decode_scope_frame_packet(value):
    """Decode a scope notify packet.

    v3 (``PSCP|3|count|f1,f2,f3,f4|<12 base64 series>``) returns a 13-element
    list: 4 point traces, 4 bucket-min series, 4 bucket-max series, then the
    list of 4 plugin-measured frequencies. Each series is packed 12-bit
    base64 (2 samples per 3 bytes).
    Older wire versions (v1 legacy scope, v2 hex) are rejected; a stray
    packet from an outdated install is dropped, never an error.
    """
    payload = unwrap_json_turtle_value(value)
    if not isinstance(payload, str):
        return None

    parts = payload.split("|")
    if len(parts) < 2 or parts[0] != SCOPE_PACKET_MAGIC:
        return None

    if parts[1] != SCOPE_PACKET_VERSION_3:
        return None
    if len(parts) != (SCOPE_PACKET_HEADER_FIELDS + SCOPE_PACKET_CHANNELS * SCOPE_PACKET_SERIES):
        return None
    try:
        frequencies = [float(f) for f in parts[3].split(",")]
    except ValueError:
        return None
    if len(frequencies) != SCOPE_PACKET_CHANNELS:
        return None
    series_parts = parts[SCOPE_PACKET_HEADER_FIELDS:]

    try:
        sample_count = int(parts[2])
    except ValueError:
        return None
    if sample_count <= 0:
        return None

    decoded = _decode_v3_series(series_parts, sample_count)
    if decoded is None:
        return None
    points, minimums, maximums = decoded
    return points + minimums + maximums + [frequencies]


def _decode_v3_series(series_parts, sample_count):
    """Decode the 12 v3 series with envelope suppression: when a channel's
    min and max payloads are identical the envelope carries no information,
    so None placeholders avoid boxing two extra float lists per channel per
    frame."""
    points = []
    minimums = []
    maximums = []
    for channel in range(SCOPE_PACKET_CHANNELS):
        base = channel * SCOPE_PACKET_SERIES
        point_b64, min_b64, max_b64 = series_parts[base:base + 3]
        point = decode_scope_frame_channel_v3(point_b64, sample_count)
        if point is None:
            return None
        points.append(point)
        if min_b64 == max_b64:
            minimums.append(None)
            maximums.append(None)
        else:
            minimum = decode_scope_frame_channel_v3(min_b64, sample_count)
            maximum = decode_scope_frame_channel_v3(max_b64, sample_count)
            if minimum is None or maximum is None:
                return None
            minimums.append(minimum)
            maximums.append(maximum)
    return points, minimums, maximums
