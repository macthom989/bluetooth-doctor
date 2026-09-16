#!/usr/bin/env bash
# bt-disable-adapter.sh — persistently disable one USB Bluetooth adapter by USB ID.
#
# Uses the USB core `authorized` attribute, which survives reboots, module reloads
# and desktop Bluetooth toggles. Weaker levers (rfkill, driver unbind) are undone by
# GNOME and by udev respectively — see reference.md.
#
# Disabling a combo chip's Bluetooth interface does NOT affect its Wi-Fi: Wi-Fi is a
# separate PCI device. Verify with: lspci | grep -i network
#
# Usage:
#   sudo ./bt-disable-adapter.sh VVVV:PPPP          disable now + persist via udev
#   sudo ./bt-disable-adapter.sh --undo VVVV:PPPP   re-enable and remove the rule
#        ./bt-disable-adapter.sh --list             show USB Bluetooth devices, no root
#
# Example: sudo ./bt-disable-adapter.sh 8087:0033

set -euo pipefail

RULE_DIR=/etc/udev/rules.d
prog=$(basename "$0")

die()  { printf 'error: %s\n' "$1" >&2; exit 1; }
info() { printf '  %s\n' "$1"; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# Find every /sys/bus/usb/devices entry matching VID:PID (a device may appear once,
# but enumerate defensively — the same dongle model can be plugged in twice).
find_devices() {
  local vid=$1 pid=$2 d
  for d in /sys/bus/usb/devices/*; do
    [ -r "$d/idVendor" ] && [ -r "$d/idProduct" ] || continue
    [ "$(cat "$d/idVendor")"  = "$vid" ] || continue
    [ "$(cat "$d/idProduct")" = "$pid" ] || continue
    printf '%s\n' "$d"
  done
}

list_devices() {
  printf 'USB Bluetooth devices (one line per device, not per interface):\n'
  local seen=0 d n parent shown=" " state

  # Devices with at least one interface bound to btusb — deduplicated by parent,
  # since a Bluetooth dongle normally exposes two interfaces (HCI + isochronous).
  for i in /sys/bus/usb/drivers/btusb/*:*; do
    [ -e "$i" ] || continue
    n=$(basename "$i"); parent=${n%%:*}
    case "$shown" in *" $parent "*) continue ;; esac
    shown="$shown$parent "
    d=/sys/bus/usb/devices/$parent
    printf '  %s:%s  %-10s authorized=%-2s active   %s\n' \
      "$(cat "$d/idVendor" 2>/dev/null)" "$(cat "$d/idProduct" 2>/dev/null)" \
      "$parent" "$(cat "$d/authorized" 2>/dev/null)" \
      "$(cat "$d/product" 2>/dev/null || echo '')"
    seen=1
  done

  # Deauthorized devices have no bound interfaces, so list them separately.
  for d in /sys/bus/usb/devices/*; do
    [ -r "$d/authorized" ] || continue
    [ "$(cat "$d/authorized")" = "0" ] || continue
    parent=$(basename "$d")
    case "$shown" in *" $parent "*) continue ;; esac
    shown="$shown$parent "
    state="disabled"
    printf '  %s:%s  %-10s authorized=0  %-8s %s\n' \
      "$(cat "$d/idVendor" 2>/dev/null)" "$(cat "$d/idProduct" 2>/dev/null)" \
      "$parent" "$state" "$(cat "$d/product" 2>/dev/null || echo '')"
    seen=1
  done

  [ "$seen" = 0 ] && printf '  (none found)\n'
  return 0
}

parse_id() {
  case "$1" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
    *) die "expected USB ID as VVVV:PPPP (e.g. 8087:0033), got '$1'" ;;
  esac
  VID=$(printf '%s' "${1%%:*}" | tr 'A-Z' 'a-z')
  PID=$(printf '%s' "${1##*:}" | tr 'A-Z' 'a-z')
  RULE="$RULE_DIR/81-disable-bt-$VID-$PID.rules"
}

need_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $prog $*)"; }

UNDO=0
case "${1:-}" in
  ''|-h|--help) usage 0 ;;
  --list)       list_devices; exit 0 ;;
  --undo)       UNDO=1; shift; [ $# -ge 1 ] || die "--undo needs a USB ID" ;;
esac

parse_id "$1"
need_root "$@"

if [ "$UNDO" = 1 ]; then
  printf 'Re-enabling %s:%s\n' "$VID" "$PID"
  if [ -f "$RULE" ]; then rm -f "$RULE"; info "removed $RULE"; else info "no rule file at $RULE"; fi
  n=0
  while read -r d; do
    [ -n "$d" ] || continue
    printf 1 > "$d/authorized" 2>/dev/null && info "authorized=1 on $(basename "$d")" || true
    n=$((n+1))
  done < <(find_devices "$VID" "$PID")
  [ "$n" = 0 ] && info "device not currently present (rule removal still applies at next boot)"
  command -v udevadm >/dev/null && udevadm control --reload-rules 2>/dev/null || true
  printf '\nDone. If the adapter does not reappear, replug it or reboot.\n'
  exit 0
fi

# --- disable -----------------------------------------------------------------

printf 'Disabling USB Bluetooth adapter %s:%s\n' "$VID" "$PID"

mapfile -t DEVS < <(find_devices "$VID" "$PID")
if [ "${#DEVS[@]}" -eq 0 ]; then
  info "warning: no device with that ID is present right now"
  info "the udev rule will still be written and will apply when it appears"
else
  for d in "${DEVS[@]}"; do
    info "found $(basename "$d")  $(cat "$d/product" 2>/dev/null || echo '')"
  done
fi

# Refuse to disable the last remaining Bluetooth adapter — that would leave the
# machine with no Bluetooth at all, which is almost never the intent.
total=0; targeted=0
for i in /sys/bus/usb/drivers/btusb/*:*; do
  [ -e "$i" ] || continue
  n=$(basename "$i"); parent=${n%%:*}; dd=/sys/bus/usb/devices/$parent
  [ -r "$dd/idVendor" ] || continue
  id="$(cat "$dd/idVendor"):$(cat "$dd/idProduct")"
  case " $(printf '%s ' "${SEEN_PARENTS:-}")" in *" $parent "*) continue;; esac
  SEEN_PARENTS="${SEEN_PARENTS:-} $parent"
  total=$((total+1))
  [ "$id" = "$VID:$PID" ] && targeted=$((targeted+1))
done
if [ "$total" -gt 0 ] && [ "$total" -eq "$targeted" ]; then
  die "refusing: $VID:$PID is the only Bluetooth adapter bound to btusb.
       Disabling it would leave no working Bluetooth. Override deliberately with:
         echo 0 > /sys/bus/usb/devices/<busid>/authorized"
fi

cat > "$RULE" <<EOF
# Disable USB Bluetooth adapter $VID:$PID at the USB core layer.
# Written by $prog. Remove with: $prog --undo $VID:$PID
#
# 'authorized' lives on the usb_device, so plain ATTR{} is correct here.
# Note: an *unbind* rule would need ATTRS{} on the usb_interface instead, because
# /sys/bus/usb/drivers/btusb/unbind only accepts interface names (e.g. 1-14:1.0).
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="$VID", ATTR{idProduct}=="$PID", ATTR{authorized}="0"
EOF
info "wrote $RULE"

command -v udevadm >/dev/null && udevadm control --reload-rules 2>/dev/null || true

# Apply to the running system — the rule alone only fires on ACTION=="add",
# so an already-enumerated device would otherwise stay active until reboot.
for d in "${DEVS[@]:-}"; do
  [ -n "${d:-}" ] || continue
  if printf 0 > "$d/authorized" 2>/dev/null; then
    info "authorized=0 applied to $(basename "$d")"
  else
    info "warning: could not write $d/authorized"
  fi
done

printf '\nVerify:\n'
printf '  ls /sys/bus/usb/drivers/btusb/     # target interfaces should be gone\n'
printf '  hciconfig                          # its hciN should have disappeared\n'
printf '\nUndo with: %s --undo %s:%s\n' "$prog" "$VID" "$PID"
