#!/usr/bin/env bash
# test-detection.sh — verify the log-classification patterns against real-world lines.
#
# The collector's value rests on one distinction: firmware NEVER REQUESTED (Fix A)
# versus REQUESTED AND FAILED (Fix D). Getting that backwards sends the user to the
# wrong fix. These fixtures are taken from real bug reports and forum threads.
#
# Usage: ./tests/test-detection.sh      (no root, no hardware required)

set -uo pipefail
pass=0; fail=0

# Patterns must stay in sync with scripts/bt-triage.sh.
FWPAT='RTL:|btrtl|rtl[0-9]{4}|btintel|ibt-|btmtk|mt[0-9]{4}|btbcm|BCM[:_ 0-9]|hci[0-9]+: .*[Ff]irmware'
FAILPAT='Direct firmware load.*failed|failed to load|no support for firmware file|failed:? *\(?-[0-9]+|timed? ?out'

check() { # check <description> <expect:yes|no> <pattern> <line>
  local desc=$1 expect=$2 pat=$3 line=$4 got
  if printf '%s' "$line" | grep -qiE "$pat"; then got=yes; else got=no; fi
  if [ "$got" = "$expect" ]; then
    printf '  ok    %s\n' "$desc"; pass=$((pass+1))
  else
    printf '  FAIL  %s\n        expected %s, got %s\n        line: %s\n' "$desc" "$expect" "$got" "$line"
    fail=$((fail+1))
  fi
}

echo "== firmware ACTIVITY detection (any vendor line at all) =="
check "realtek probe"      yes "$FWPAT" 'Bluetooth: hci0: RTL: examining hci_ver=0a hci_rev=000b lmp_ver=0a lmp_subver=8761'
check "realtek load"       yes "$FWPAT" 'Bluetooth: hci0: RTL: loading rtl_bt/rtl8761bu_fw.bin'
check "intel sfi"          yes "$FWPAT" 'Bluetooth: hci0: Found device firmware: intel/ibt-1040-0041.sfi'
check "intel loaded"       yes "$FWPAT" 'Bluetooth: hci0: Firmware loaded in 1358420 usecs'
check "mediatek"           yes "$FWPAT" 'Bluetooth: hci0: btmtk: Firmware version = 1'
check "broadcom patch"     yes "$FWPAT" 'Bluetooth: hci0: BCM: chip id 94'
check "unrelated usb line" no  "$FWPAT" 'usb 1-1: new full-speed USB device number 2 using xhci_hcd'
check "generic btusb reg"  no  "$FWPAT" 'usbcore: registered new interface driver btusb'

echo
echo "== firmware FAILURE detection (requested but failed -> Fix D, not Fix A) =="
check "direct load -2"     yes "$FAILPAT" 'bluetooth hci0: Direct firmware load for rtl_bt/rtl8761bu_fw.bin failed with error -2'
check "opcode failed"      yes "$FAILPAT" 'Bluetooth: hci0: Opcode 0x0c03 failed: -110'
check "opcode c77"         yes "$FAILPAT" 'Bluetooth: hci0: Opcode 0xc77 failed: -56'
check "no support for fw"  yes "$FAILPAT" 'Bluetooth: hci0: RTL: no support for firmware file'
check "timeout -110"       yes "$FAILPAT" 'Bluetooth: hci0: Reading supported features failed (-110)'
check "successful load"    no  "$FAILPAT" 'Bluetooth: hci0: RTL: fw version 0xdfc6d922'
check "successful intel"   no  "$FAILPAT" 'Bluetooth: hci0: Firmware loaded in 1358420 usecs'
check "clean probe"        no  "$FAILPAT" 'Bluetooth: hci0: RTL: rom_version status=0 version=1'
check "fw filename w/ dash" no "$FAILPAT" 'Bluetooth: hci1: Found device firmware: intel/ibt-1040-0041.sfi'
check "fw version line"     no "$FAILPAT" 'Bluetooth: hci1: Firmware Version: 202-5.26'
check "ddc params ok"       no "$FAILPAT" 'Bluetooth: hci1: Found Intel DDC parameters: intel/ibt-1040-0041.ddc'
check "intel addr failed"  yes "$FAILPAT" 'Bluetooth: hci1: Reading Intel device address failed (-110)'
check "event mask failed"  yes "$FAILPAT" 'Bluetooth: hci1: Setting Intel event mask failed (-110)'

echo
echo "== the decisive split: same symptom, different fix =="
FIXA='Bluetooth: hci0: RTL: examining'      # present => firmware machinery ran
NOFW='usbcore: registered new interface driver btusb'
printf '  Fix A scenario (ID missing): vendor lines=%s failures=%s\n' \
  "$(printf '%s' "$NOFW" | grep -qiE "$FWPAT" && echo yes || echo no)" \
  "$(printf '%s' "$NOFW" | grep -qiE "$FAILPAT" && echo yes || echo no)"
printf '  Fix D scenario (blob wrong) : vendor lines=%s failures=%s\n' \
  "$(printf '%s' "$FIXA" | grep -qiE "$FWPAT" && echo yes || echo no)" \
  "$(printf '%s' 'Direct firmware load for rtl_bt/rtl8761bu_fw.bin failed with error -2' | grep -qiE "$FAILPAT" && echo yes || echo no)"

echo
echo "== USB ID little-endian encoding used to verify a built module =="
for id in 2c4e:0115 8087:0033 0bda:8771; do
  v=${id%%:*}; p=${id##*:}
  enc=$(python3 -c "print(bytes.fromhex('$v'[2:4]+'$v'[0:2]+'$p'[2:4]+'$p'[0:2]).hex())" 2>/dev/null)
  exp=$(python3 -c "
import struct;print(struct.pack('<HH', 0x$v, 0x$p).hex())" 2>/dev/null)
  if [ -n "$enc" ] && [ "$enc" = "$exp" ]; then
    printf '  ok    %s -> %s\n' "$id" "$enc"; pass=$((pass+1))
  else
    printf '  FAIL  %s encoding mismatch (%s vs %s)\n' "$id" "$enc" "$exp"; fail=$((fail+1))
  fi
done

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
