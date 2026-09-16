#!/usr/bin/env bash
# test-integration.sh — exercise the install paths of the two privileged scripts on
# real hardware. Needs root. Changes system state, then restores it.
#
# Usage: sudo ./tests/test-integration.sh <DISABLE_ID> [PATCH_ID]
#   DISABLE_ID  USB ID of an adapter you are willing to disable/re-enable (e.g. 8087:0033)
#   PATCH_ID    optional: USB ID whose btusb quirk to reinstall via bt-patch-btusb.sh
#
# Test 2 is skipped unless PATCH_ID is given, because it replaces the running btusb.
# A failsafe re-enables DISABLE_ID if Bluetooth ends up completely dead.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
[ "$(id -u)" -eq 0 ] || { echo "must run as root"; exit 1; }

DIS=${1:?usage: sudo $0 <DISABLE_ID> [PATCH_ID]}
PATCH=${2:-}
pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
hr()   { printf '\n=== %s ===\n' "$1"; }

adapters() { ls /sys/class/bluetooth 2>/dev/null | grep -c '^hci[0-9]'; }
bound_ids() {
  for i in /sys/bus/usb/drivers/btusb/*:*; do
    [ -e "$i" ] || continue
    n=$(basename "$i"); p=${n%%:*}
    printf '%s:%s\n' "$(cat /sys/bus/usb/devices/$p/idVendor 2>/dev/null)" \
                     "$(cat /sys/bus/usb/devices/$p/idProduct 2>/dev/null)"
  done | sort -u
}

hr "BASELINE"
BASE_ADAPTERS=$(adapters)
echo "  adapters: $BASE_ADAPTERS"
echo "  btusb-bound IDs: $(bound_ids | tr '\n' ' ')"
echo "  dkms: $(dkms status 2>/dev/null | tr '\n' ' ')"

# ---------------------------------------------------------------- test 1

hr "TEST 1 — bt-disable-adapter.sh (re-enable, then disable)"

./scripts/bt-disable-adapter.sh --undo "$DIS" >/dev/null 2>&1
sleep 2
if bound_ids | grep -q "^$DIS$"; then ok "--undo re-bound $DIS to btusb"
else no "--undo did not bring $DIS back (may need a replug on some hardware)"; fi
RULE_GONE=1; ls /etc/udev/rules.d/ 2>/dev/null | grep -q "disable-bt-${DIS/:/-}" && RULE_GONE=0
[ "$RULE_GONE" = 1 ] && ok "--undo removed its rule file" || no "--undo left its rule file behind"

OUT=$(./scripts/bt-disable-adapter.sh "$DIS" 2>&1); RC=$?
sleep 2
[ "$RC" = 0 ] && ok "disable exited 0" || { no "disable exited $RC"; printf '%s\n' "$OUT" | sed 's/^/        /'; }
RULEF="/etc/udev/rules.d/81-disable-bt-${DIS%%:*}-${DIS##*:}.rules"
[ -f "$RULEF" ] && ok "wrote $RULEF" || no "did not write $RULEF"
grep -q 'authorized' "$RULEF" 2>/dev/null && ok "rule uses ATTR{authorized}" || no "rule missing authorized attribute"
if bound_ids | grep -q "^$DIS$"; then no "$DIS is still bound to btusb"; else ok "$DIS no longer bound"; fi

hr "TEST 1 — refusal guard (must refuse to disable the last adapter)"
LAST=$(bound_ids | head -1)
if [ -n "$LAST" ] && [ "$(bound_ids | wc -l)" -eq 1 ]; then
  if ./scripts/bt-disable-adapter.sh "$LAST" >/dev/null 2>&1; then
    no "did NOT refuse to disable the only remaining adapter"
    ./scripts/bt-disable-adapter.sh --undo "$LAST" >/dev/null 2>&1
  else
    ok "refused to disable the only remaining adapter"
  fi
else
  echo "  skipped (more than one adapter bound)"
fi

# ---------------------------------------------------------------- test 2

if [ -z "$PATCH" ]; then
  hr "TEST 2 — skipped (no PATCH_ID given)"
else
  hr "TEST 2 — bt-patch-btusb.sh (full DKMS install path)"
  PRE_RTL=$(journalctl -k -b --no-pager 2>/dev/null | grep -ic 'RTL:\|btintel\|btmtk')
  echo "  removing any pre-existing btusb DKMS packages"
  dkms status 2>/dev/null | grep -oE '^[a-z0-9_-]+/[0-9.]+' | while read -r m; do
    echo "    dkms remove $m"; dkms remove "$m" --all >/dev/null 2>&1
  done
  depmod -a

  echo "  running bt-patch-btusb.sh $PATCH --yes"
  if ./scripts/bt-patch-btusb.sh "$PATCH" --yes 2>&1 | tail -25 | sed 's/^/        /'; then
    ok "bt-patch-btusb.sh completed"
  else
    no "bt-patch-btusb.sh failed"
  fi

  dkms status 2>/dev/null | grep -q 'btusb-quirk' && ok "btusb-quirk registered with dkms" \
    || no "btusb-quirk not in dkms status"

  RAM=$(cat /sys/module/btusb/srcversion 2>/dev/null)
  DISK=$(modinfo btusb 2>/dev/null | awk '/^srcversion/{print $2}')
  [ -n "$RAM" ] && [ "$RAM" = "$DISK" ] && ok "module in RAM matches patched module on disk" \
    || no "RAM=$RAM disk=$DISK — reload needed"

  modinfo btusb 2>/dev/null | grep -q 'updates/dkms' && ok "running module comes from updates/dkms" \
    || no "running module is not the DKMS one"

  sleep 3
  POST_RTL=$(journalctl -k -b --no-pager 2>/dev/null | grep -ic 'RTL:\|btintel\|btmtk')
  [ "$POST_RTL" -ge "$PRE_RTL" ] && ok "vendor firmware log lines present ($POST_RTL)" \
    || no "firmware lines went backwards ($PRE_RTL -> $POST_RTL)"
fi

# ------------------------------------------------------------- failsafe

hr "FAILSAFE"
NOW=$(adapters)
echo "  adapters now: $NOW (baseline was $BASE_ADAPTERS)"
if [ "$NOW" -eq 0 ]; then
  printf '  \033[31mno Bluetooth adapters left — re-enabling %s\033[0m\n' "$DIS"
  ./scripts/bt-disable-adapter.sh --undo "$DIS" >/dev/null 2>&1
  sleep 2
  echo "  adapters after rescue: $(adapters)"
fi

hr "RESULT"
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  cat <<EOF

  Recovery, if anything is broken:
    sudo dkms remove btusb-quirk/1.0 --all
    sudo depmod -a && sudo modprobe -r btusb && sudo modprobe btusb
    sudo ./scripts/bt-disable-adapter.sh --undo $DIS
EOF
fi
[ "$fail" -eq 0 ]
