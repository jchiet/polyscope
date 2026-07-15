#!/bin/bash
set -Eeuo pipefail
LOG="/usb_flash/hector_scope_recovery.log"
touch "$LOG" 2>/dev/null || LOG="/tmp/hector_scope_recovery.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== HectorScope recovery $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
[ "$(id -u)" -eq 0 ] || { echo "Must run as root."; exit 1; }

# Same single-instance guard as the installer.
LOCKDIR="/tmp/hector_scope_recovery.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "Another recovery run is already in progress; exiting."
  exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

# Target the persistent lower layer if this is an overlay-root unit.
LOWERDIR="$(awk '$2=="/" && $3=="overlay"{
    for (i=1;i<=NF;i++) if ($i ~ /lowerdir=/) {
      n=split($i,a,","); for (j=1;j<=n;j++) if (a[j] ~ /^lowerdir=/) {
        sub(/^lowerdir=/,"",a[j]); split(a[j],b,":"); print b[1]; }
    }}' /proc/mounts | head -n1)"
PERSIST=0
if [ -n "$LOWERDIR" ] && [ -d "$LOWERDIR/home/debian/UI" ]; then
  echo "Overlay root detected. Persistent layer: $LOWERDIR"
  mount -o remount,rw "$LOWERDIR" || { echo "ERROR: could not remount $LOWERDIR rw"; exit 1; }
  TARGET="$LOWERDIR"; PERSIST=1
else
  echo "No overlay root; operating on /."
  mount -o remount,rw / 2>/dev/null || true
  TARGET=""
fi
UI="${TARGET}/home/debian/UI"
LV2="${TARGET}/usr/lib/lv2"
remount_ro() { if [ "$PERSIST" = 1 ]; then mount -o remount,ro "$LOWERDIR" 2>/dev/null || true; fi; }

restored_any=0

# 1) Restore from the v2 on-device backups (true originals captured pre-patch).
B2="$UI/.hector_scope_backup_v2"
if [ -d "$B2" ]; then
  ( cd "$B2" && find . -type f ! -name '_lv2_*' | while read -r rel; do
      rel="${rel#./}"; mkdir -p "$(dirname "$UI/$rel")"; cp -a "$B2/$rel" "$UI/$rel"; echo "restored (v2 backup) $rel"; done )
  restored_any=1
fi

# 2) Fall back to the originals stashed on the USB by the installer.
USB_BAK="/usb_flash/hector_scope_originals_backup"
if [ "$restored_any" = 0 ] && [ -d "$USB_BAK" ]; then
  ( cd "$USB_BAK" && find . -type f | while read -r rel; do
      rel="${rel#./}"; mkdir -p "$(dirname "$UI/$rel")"; cp -a "$USB_BAK/$rel" "$UI/$rel"; echo "restored (USB backup) $rel"; done )
  restored_any=1
fi

# 3) Last resort: pristine baseline files carried on this recovery USB.
ORIG="/usb_flash/originals"
if [ "$restored_any" = 0 ] && [ -d "$ORIG" ]; then
  ( cd "$ORIG" && find . -type f | while read -r rel; do
      rel="${rel#./}"; mkdir -p "$(dirname "$UI/$rel")"; cp -a "$ORIG/$rel" "$UI/$rel"; echo "restored (USB originals) $rel"; done )
  restored_any=1
fi

# Remove scope additions and the marker.
rm -f "$UI/qml/Scope.qml" 2>/dev/null && echo "removed Scope.qml" || true
rm -f "$UI/qml/Polyscope.qml" 2>/dev/null && echo "removed Polyscope.qml" || true
rm -rf "$LV2/poly_scope.lv2" 2>/dev/null && echo "removed LV2 bundle" || true
rm -rf "$LV2/poly_scope2.lv2" 2>/dev/null && echo "removed LV2 bundle 2" || true
rm -f "$UI/.hector_scope_v2_done" 2>/dev/null || true

# Regenerate module_info.js from whatever module_info.py is now in place.
if [ -f "$UI/effect_proto_to_js.py" ]; then ( cd "$UI" && python3 effect_proto_to_js.py 2>/dev/null ) || true; fi

sync
remount_ro
echo "=========================================="
if [ "$restored_any" = 1 ]; then
  echo "Recovery complete. Original files restored on the persistent layer."
else
  echo "Recovery ran, but no backup source was found to restore from."
  echo "If the unit still misbehaves, reflash firmware 407."
fi
echo "Manually POWER OFF the unit, REMOVE the USB, then power on."
echo "=========================================="
shutdown -h now 2>/dev/null || poweroff 2>/dev/null || true
