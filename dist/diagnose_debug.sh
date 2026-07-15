#!/bin/bash
# HectorScope read-only diagnostic v2. Changes nothing on the unit.
# No lock (read-only; concurrent QA launches just duplicate output).
# Most important checks first, with frequent syncs so the log survives.

LOG="/usb_flash/hector_scope_diagnose.log"
if ! touch "$LOG" 2>/dev/null; then LOG="/tmp/hector_scope_diagnose.log"; fi
exec > >(tee -a "$LOG") 2>&1

flush() { sync 2>/dev/null || true; }

UI=/home/debian/UI

echo "===================================================="
echo "HectorScope DIAGNOSTIC v2  (writing to: $LOG)"
date 2>/dev/null || true
echo "===================================================="
flush

echo
echo "[A] *** KEY TEST: does module_info.py on disk STILL have scope? ***"
echo -n "  module_info.py scope URI count : "; grep -c "polyeffects.com/lv2/scope" "$UI/module_info.py" 2>&1
echo -n "  module_info.py 'scope:' count  : "; grep -c "'scope':" "$UI/module_info.py" 2>&1
echo -n "  module_info.js scope count     : "; grep -c "scope" "$UI/qml/module_info.js" 2>&1
echo -n "  Scope.qml exists               : "; [ -f "$UI/qml/Scope.qml" ] && echo YES || echo NO
echo -n "  poly_scope.lv2 exists          : "; [ -d /usr/lib/lv2/poly_scope.lv2 ] && echo YES || echo NO
echo -n "  install marker exists          : "; [ -e "$UI/.hector_scope_v2_done" ] && echo YES || echo NO
flush

echo
echo "[B] *** Is the root filesystem persistent? (overlay / ro check) ***"
echo "  --- / and /home and overlay mounts from /proc/mounts ---"
grep -E ' / |overlay| /home' /proc/mounts 2>&1
echo "  --- mount output (filtered) ---"
( mount 2>/dev/null | grep -E ' on / | on /home|overlay|read-only|\bro\b' ) 2>&1
echo "  --- is / writable right now? ---"
if touch "$UI/.scope_persist_test" 2>/dev/null; then
  echo "  / is writable in this session (wrote $UI/.scope_persist_test)"
  rm -f "$UI/.scope_persist_test" 2>/dev/null || true
else
  echo "  / appears NOT writable in this session"
fi
flush

echo
echo "[C] File timestamps (note: unit clock may be wrong):"
ls -la "$UI/module_info.py" "$UI/qml/module_info.js" "$UI/qml/Scope.qml" 2>&1
flush

echo
echo "[D] Bytecode cache (a .pyc NEWER than module_info.py = possibly stale):"
ls -la "$UI"/__pycache__/module_info*.pyc "$UI"/__pycache__/module_browser_model*.pyc "$UI"/module_info.pyc 2>&1
flush

echo
echo "[E] RUNTIME import test (what the UI does):"
cd "$UI" 2>/dev/null
python3 - <<'PY' 2>&1
try:
    import module_info as m
    print("  scope in effect_prototypes_models_all:", 'scope' in m.effect_prototypes_models_all)
    print("  scope in effect_type_maps['beebo']  :", 'scope' in m.effect_type_maps['beebo'])
except Exception as e:
    print("  module_info import ERROR:", repr(e))
try:
    import module_browser_model as b
    print("  scope in browser effect_prototypes  :", 'scope' in b.effect_prototypes)
    print("  total browser modules               :", len(b.effect_prototypes))
except Exception as e:
    print("  module_browser_model import ERROR:", repr(e))
PY
flush

echo
echo "[F] Running UI process + where it loads from:"
( ps aux 2>/dev/null || ps -ef 2>/dev/null || ps 2>/dev/null ) | grep -iE "python|show_widget|headless|digit" | grep -v grep
echo -n "  python3: "; which python3 2>&1; python3 --version 2>&1
flush

echo
echo "===================================================="
echo "DIAGNOSTIC COMPLETE.  *** WAIT for this line, then power off. ***"
echo "Log written to: $LOG"
echo "===================================================="
flush
sleep 2
sync 2>/dev/null || true
