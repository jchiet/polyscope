"""Qt-free helpers for the scope UI, kept separate so they are unit-testable
without importing PySide2."""

SCOPE_PACKET_MAGIC = "PSCP"
SCOPE_PACKET_VERSION = "1"
SCOPE_PACKET_VERSION_2 = "2"
SCOPE_PACKET_CHANNELS = 4
SCOPE_PACKET_HEADER_FIELDS = 3
SCOPE_PACKET_V2_HEADER_FIELDS = 4   # magic | version | count | freqs
SCOPE_PACKET_V2_SERIES = 3          # point, bucket-min, bucket-max
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


# All 256 possible sample bytes, pre-mapped to [-1, 1]. The decode loop then
# does a single list lookup per sample instead of two float ops, which matters
# because this runs 768 times per frame on a thread that shares the GIL with
# the UI loop.
_BYTE_TO_UNIT = [(b / 255.0) * 2.0 - 1.0 for b in range(256)]


def decode_scope_frame_channel(channel_payload, sample_count):
    """Decode one channel's hex payload to floats in [-1, 1].

    Uses bytes.fromhex (C-speed) instead of a per-pair Python int() loop, so the
    receive thread can keep up with the frame rate without backing up the socket.
    """
    if len(channel_payload) != sample_count * 2:
        return None
    try:
        raw = bytes.fromhex(channel_payload)
    except ValueError:
        return None
    lut = _BYTE_TO_UNIT
    return [lut[b] for b in raw]


def decode_scope_frame_packet(value):
    """Decode a scope notify packet.

    v1 (``PSCP|1|count|<4 hex series>``) returns ``[t1, t2, t3, t4]``.
    v2 (``PSCP|2|count|f1,f2,f3,f4|<12 hex series>``) returns a 13-element
    list: 4 point traces, 4 bucket-min series, 4 bucket-max series, then the
    list of 4 plugin-measured frequencies. The QML side keys off the length,
    so v1 senders (the legacy scope module) keep working unchanged.
    """
    payload = unwrap_json_turtle_value(value)
    if not isinstance(payload, str):
        return None

    parts = payload.split("|")
    if len(parts) < 2 or parts[0] != SCOPE_PACKET_MAGIC:
        return None

    if parts[1] == SCOPE_PACKET_VERSION:
        if len(parts) != (SCOPE_PACKET_HEADER_FIELDS + SCOPE_PACKET_CHANNELS):
            return None
        header_fields = SCOPE_PACKET_HEADER_FIELDS
        series_parts = parts[header_fields:]
        frequencies = None
    elif parts[1] == SCOPE_PACKET_VERSION_2:
        if len(parts) != (SCOPE_PACKET_V2_HEADER_FIELDS + SCOPE_PACKET_CHANNELS * SCOPE_PACKET_V2_SERIES):
            return None
        try:
            frequencies = [float(f) for f in parts[3].split(",")]
        except ValueError:
            return None
        if len(frequencies) != SCOPE_PACKET_CHANNELS:
            return None
        series_parts = parts[SCOPE_PACKET_V2_HEADER_FIELDS:]
    else:
        return None

    try:
        sample_count = int(parts[2])
    except ValueError:
        return None
    if sample_count <= 0:
        return None

    if frequencies is None:
        frames = []
        for series_payload in series_parts:
            series = decode_scope_frame_channel(series_payload, sample_count)
            if series is None:
                return None
            frames.append(series)
        return frames

    decoded = _decode_v2_series(series_parts, sample_count)
    if decoded is None:
        return None
    points, minimums, maximums = decoded
    return points + minimums + maximums + [frequencies]


def _decode_v2_series(series_parts, sample_count):
    """Decode the 12 v2 series with envelope suppression.

    When a channel's min and max hex payloads are identical (decimation 1,
    or a signal with no sub-bucket excursion) the envelope carries no
    information; None placeholders avoid boxing 2x192 floats per channel per
    frame on their way into QML — the dominant JS allocation source, and the
    prime suspect for the periodic organic-GC frame drops.
    """
    points = []
    minimums = []
    maximums = []
    for channel in range(SCOPE_PACKET_CHANNELS):
        base = channel * SCOPE_PACKET_V2_SERIES
        point_hex, min_hex, max_hex = series_parts[base:base + 3]
        point = decode_scope_frame_channel(point_hex, sample_count)
        if point is None:
            return None
        points.append(point)
        if len(min_hex) != sample_count * 2 or len(max_hex) != sample_count * 2:
            return None
        if min_hex == max_hex:
            minimums.append(None)
            maximums.append(None)
        else:
            minimum = decode_scope_frame_channel(min_hex, sample_count)
            maximum = decode_scope_frame_channel(max_hex, sample_count)
            if minimum is None or maximum is None:
                return None
            minimums.append(minimum)
            maximums.append(maximum)
    return points, minimums, maximums
