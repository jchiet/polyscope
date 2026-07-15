HectorScope USB Installer v2 (checksum-gated)
=============================================

This installer is safe for fragile units that cannot be recovered by hand:

  * PERSISTENCE: these units use an overlay root whose writable layer is in RAM
    and is wiped on every reboot, with the real storage mounted read-only
    underneath. This installer detects that, remounts the persistent lower
    layer read-write, and writes there so the scope SURVIVES a power cycle.
    (On a non-overlay unit it writes to / directly.)
  * It only replaces a firmware-407 UI file if that file matches the exact
    407 baseline checksum it expects. If your unit runs a slightly different
    407 build, the installer ABORTS without changing anything and prints the
    checksums it saw (in the log) so the package can be re-targeted.
  * Every replaced file is backed up (on the persistent layer AND copied to the
    USB at hector_scope_originals_backup/), every write is checksum-verified,
    and the patched Python is compile-checked. If anything fails, ALL changes
    are rolled back and the unit is left exactly as it was.
  * Because writes are now permanent, recover with the recovery USB if needed;
    it restores from the on-device backup, the USB backup, or pristine baseline
    originals it carries.

USB layout (copy everything to a FAT32 USB root):
  debug.sh
  README_USB_INSTALL.txt
  SHA256SUMS
  hector-scope-patch/
    install_scope.py
    payload/
      manifest.json
      files/      (patched module_info.py, show_widget.py, ingen_wrapper.py,
                   headless.py, qml/PatchBayEffect.qml, qml/Scope.qml)
      lv2/poly_scope.lv2/  (poly_scope.so, poly_scope.ttl, manifest.ttl)

Install:
  1. Boot Hector normally on firmware 407.
  2. Insert the USB drive.
  3. Settings -> QA CHECK -> Run debug. (Press it ONCE and wait.)
  4. Wait for the "SUCCESS ... installed and verified" message. The unit may
     NOT power off by itself in the QA debug context -- that is expected.
  5. Manually POWER OFF the unit, REMOVE the USB, then power on.
     (Do not boot with the USB inserted. Do not press Run debug repeatedly.)
  6. Add a "scope" module in the patch bay.

Note: the installer takes only a few seconds. It now uses a lock so that even
if the debug runner launches it more than once, only one instance runs and the
rest exit immediately. A completion marker makes repeat launches a no-op.

If it reports a checksum mismatch and aborts:
  Your unit is untouched. Copy /usb_flash/hector_scope_install.log off the USB
  and share it so the package can be re-targeted for your exact firmware.

Recovery (separate USB: hector-scope-recovery-usb-v2):
  Settings -> QA CHECK -> Run debug. Restores backups and removes the plugin.
