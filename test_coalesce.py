import importlib.util, os
UI = os.path.join(os.path.dirname(__file__),
                  "source", "polyeffects-src", "digit_ui")
spec = importlib.util.spec_from_file_location("scope_util",
                                              os.path.join(UI, "scope_util.py"))
scope_util = importlib.util.module_from_spec(spec); spec.loader.exec_module(scope_util)
coalesce = scope_util.coalesce_ui_messages


def test_keeps_only_last_scope_frame_per_effect():
    msgs = [
        ["scope_frame", "/main/scope1", [1]],
        ["value_change", "/main/scope1/freeze", "0"],
        ["scope_frame", "/main/scope1", [2]],
        ["scope_frame", "/main/scope1", [3]],
    ]
    out = coalesce(msgs)
    assert out == [
        ["value_change", "/main/scope1/freeze", "0"],
        ["scope_frame", "/main/scope1", [3]],
    ]


def test_separate_effects_each_kept():
    msgs = [
        ["scope_frame", "/main/scope1", [1]],
        ["scope_frame", "/main/scope2", [9]],
        ["scope_frame", "/main/scope1", [2]],
    ]
    out = coalesce(msgs)
    assert out == [
        ["scope_frame", "/main/scope2", [9]],
        ["scope_frame", "/main/scope1", [2]],
    ]


def test_non_scope_order_preserved_and_short_messages_ok():
    msgs = [["exit"], ["value_change", "/a/b", "1"], ["bpm_change", (120,)]]
    assert coalesce(msgs) == msgs


def _slow_decode_channel(channel_payload, sample_count):
    """Original per-pair int() reference algorithm, for equivalence checking."""
    if len(channel_payload) != sample_count * 2:
        return None
    out = []
    for i in range(0, len(channel_payload), 2):
        enc = int(channel_payload[i:i + 2], 16)
        out.append((enc / 255.0) * 2.0 - 1.0)
    return out


def test_fast_decode_matches_reference_for_all_byte_values():
    payload = "".join("%02X" % b for b in range(256))   # 0x00..0xFF
    fast = scope_util.decode_scope_frame_channel(payload, 256)
    slow = _slow_decode_channel(payload, 256)
    assert fast == slow
    assert fast[0] == -1.0 and fast[-1] == 1.0


def test_fast_decode_rejects_bad_input():
    assert scope_util.decode_scope_frame_channel("ZZ", 1) is None      # non-hex
    assert scope_util.decode_scope_frame_channel("AABB", 1) is None    # wrong length


def test_decode_packet_roundtrip():
    ch = "".join("%02X" % ((i * 7) % 256) for i in range(192))
    pkt = "PSCP|1|192|" + "|".join([ch, ch, ch, ch])
    frames = scope_util.decode_scope_frame_packet(pkt)
    assert frames is not None and len(frames) == 4 and len(frames[0]) == 192
    assert scope_util.decode_scope_frame_packet("PSCP|2|192|x|x|x|x") is None  # bad version


if __name__ == "__main__":
    test_keeps_only_last_scope_frame_per_effect()
    test_separate_effects_each_kept()
    test_non_scope_order_preserved_and_short_messages_ok()
    test_fast_decode_matches_reference_for_all_byte_values()
    test_fast_decode_rejects_bad_input()
    test_decode_packet_roundtrip()
    print("ALL COALESCE + DECODE TESTS PASSED")


def test_split_null_messages_basic_and_partial():
    buf = bytearray(b'{"a":1}\0{"b":2}\0{"par')
    msgs, rest = scope_util.split_null_messages(buf)
    assert msgs == ['{"a":1}', '{"b":2}']
    assert rest == bytearray(b'{"par')
    # feeding the remainder plus the rest of the message completes it
    rest.extend(b'tial":3}\0')
    msgs2, rest2 = scope_util.split_null_messages(rest)
    assert msgs2 == ['{"partial":3}']
    assert rest2 == bytearray(b"")


def test_split_null_messages_empty_and_double_null():
    msgs, rest = scope_util.split_null_messages(bytearray(b"\0\0abc"))
    assert msgs == []
    assert rest == bytearray(b"abc")
    msgs, rest = scope_util.split_null_messages(bytearray(b""))
    assert msgs == [] and rest == bytearray(b"")


def test_stale_scope_frame_indices_keeps_only_newest():
    msgs = [
        '{"set": "PSCP|1|192|AA"}',      # stale scope frame
        '{"set": "volume", "v": 1}',     # unrelated -> always kept
        '{"set": "PSCP|1|192|BB"}',      # stale scope frame
        '{"set": "PSCP|1|192|CC"}',      # newest scope frame -> kept
        '{"set": "enabled"}',
    ]
    assert scope_util.stale_scope_frame_indices(msgs) == {0, 2}


def test_stale_scope_frame_indices_single_or_none():
    assert scope_util.stale_scope_frame_indices(['{"set": "PSCP|1|192|AA"}']) == set()
    assert scope_util.stale_scope_frame_indices(['{"a":1}', '{"b":2}']) == set()
    assert scope_util.stale_scope_frame_indices([]) == set()


def _hex_series(byte_value, count=192):
    return ("%02X" % byte_value) * count


def test_decode_v2_packet_groups_series_and_freqs():
    parts = ["PSCP", "2", "192", "440.00,0.00,2.50,12000.00"]
    for ch in range(4):
        parts.append(_hex_series(0x80 + ch))       # point
        parts.append(_hex_series(0x10 + ch))       # min
        parts.append(_hex_series(0xF0 - ch))       # max
    decoded = scope_util.decode_scope_frame_packet("|".join(parts))
    assert decoded is not None and len(decoded) == 13
    points, mins, maxs, freqs = decoded[0:4], decoded[4:8], decoded[8:12], decoded[12]
    assert freqs == [440.0, 0.0, 2.5, 12000.0]
    for ch in range(4):
        assert len(points[ch]) == 192 and len(mins[ch]) == 192 and len(maxs[ch]) == 192
        # ordering must be regrouped: mins below points below maxs
        assert mins[ch][0] < points[ch][0] < maxs[ch][0]


def test_decode_v2_rejects_malformed():
    assert scope_util.decode_scope_frame_packet("PSCP|2|192|1.0,2.0") is None          # missing series
    bad_freqs = "PSCP|2|192|x,y,z,w|" + "|".join(_hex_series(1) for _ in range(12))
    assert scope_util.decode_scope_frame_packet(bad_freqs) is None
    three_freqs = "PSCP|2|192|1,2,3|" + "|".join(_hex_series(1) for _ in range(12))
    assert scope_util.decode_scope_frame_packet(three_freqs) is None


def test_decode_v1_still_returns_four_traces():
    payload = "PSCP|1|192|" + "|".join(_hex_series(0x40 + ch) for ch in range(4))
    decoded = scope_util.decode_scope_frame_packet(payload)
    assert decoded is not None and len(decoded) == 4
    assert all(len(tr) == 192 for tr in decoded)


def test_decode_v2_suppresses_uninformative_envelope():
    parts = ["PSCP", "2", "192", "10.00,20.00,30.00,40.00"]
    for ch in range(4):
        parts.append(_hex_series(0x80))
        if ch == 1:
            parts.append(_hex_series(0x80))   # min == max -> suppressed
            parts.append(_hex_series(0x80))
        else:
            parts.append(_hex_series(0x10))
            parts.append(_hex_series(0xF0))
    decoded = scope_util.decode_scope_frame_packet("|".join(parts))
    assert decoded is not None and len(decoded) == 13
    assert decoded[4 + 1] is None and decoded[8 + 1] is None      # ch1 suppressed
    assert decoded[4 + 0] is not None and decoded[8 + 0] is not None
    assert decoded[12] == [10.0, 20.0, 30.0, 40.0]
