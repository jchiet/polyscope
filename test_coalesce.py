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
        '{"set": "PSCP|3|192|AA"}',      # stale scope frame
        '{"set": "volume", "v": 1}',     # unrelated -> always kept
        '{"set": "PSCP|3|192|BB"}',      # stale scope frame
        '{"set": "PSCP|3|192|CC"}',      # newest scope frame -> kept
        '{"set": "enabled"}',
    ]
    assert scope_util.stale_scope_frame_indices(msgs) == {0, 2}


def test_stale_scope_frame_indices_single_or_none():
    assert scope_util.stale_scope_frame_indices(['{"set": "PSCP|3|192|AA"}']) == set()
    assert scope_util.stale_scope_frame_indices(['{"a":1}', '{"b":2}']) == set()
    assert scope_util.stale_scope_frame_indices([]) == set()


def _hex_series(byte_value, count=192):
    return ("%02X" % byte_value) * count


def test_old_wire_versions_are_rejected():
    # v1 and v2 support was removed (plugin and UI always ship together);
    # stray packets from an older install must be dropped, never an error.
    v1 = "PSCP|1|192|" + "|".join(_hex_series(0x40 + ch) for ch in range(4))
    assert scope_util.decode_scope_frame_packet(v1) is None
    v2 = "PSCP|2|192|1.00,2.00,3.00,4.00|" + "|".join(
        [_hex_series(0x80)] * 12)
    assert scope_util.decode_scope_frame_packet(v2) is None
    assert scope_util.decode_scope_frame_packet("PSCP|9|192|x") is None


if __name__ == "__main__":
    test_keeps_only_last_scope_frame_per_effect()
    test_separate_effects_each_kept()
    test_non_scope_order_preserved_and_short_messages_ok()
    test_split_null_messages_basic_and_partial()
    test_split_null_messages_empty_and_double_null()
    test_stale_scope_frame_indices_keeps_only_newest()
    test_stale_scope_frame_indices_single_or_none()
    test_old_wire_versions_are_rejected()
    print("ALL COALESCE + TRANSPORT TESTS PASSED")
