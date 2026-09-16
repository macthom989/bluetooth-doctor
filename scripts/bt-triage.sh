#!/usr/bin/env bash
# bt-triage.sh — one-pass evidence collector for Linux Bluetooth adapter problems.
#
# Read-only. Requires no root. Makes no changes to the system.
# Portable across distributions; degrades gracefully when optional tools are absent.
#
# Usage: ./bt-triage.sh [--no-color]
#
# Exit codes: 0 always (this is a reporting tool, not a test).

set -uo pipefail

case "${1:-}" in
  -h|--help)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

if [ "${1:-}" = "--no-color" ] || [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then
  B=""; R=""; Y=""; G=""
else
  B=$'\033[1m'; R=$'\033[0m'; Y=$'\033[33m'; G=$'\033[32m'
fi

hr() { printf '\n%s======== %s ========%s\n' "$B" "$1" "$R"; }
have() { command -v "$1" >/dev/null 2>&1; }
note() { printf '  %s! %s%s\n' "$Y" "$1" "$R"; }

# ---------------------------------------------------------------- system

hr "SYSTEM"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "  distro  ${PRETTY_NAME:-${NAME:-unknown}}"
fi
echo "  kernel  $(uname -r)  ($(uname -m))"

bluez_ver=""
have bluetoothctl && bluez_ver=$(bluetoothctl --version 2>/dev/null | awk '{print $NF}')
[ -z "$bluez_ver" ] && have bluetoothd && bluez_ver=$(bluetoothd -v 2>/dev/null)
echo "  bluez   ${bluez_ver:-unknown}"
echo "  desktop ${XDG_CURRENT_DESKTOP:-none}  session ${XDG_SESSION_TYPE:-unknown}"

if have systemctl; then
  echo "  bluetooth.service: $(systemctl is-active bluetooth 2>/dev/null || echo unknown)"
fi

for t in hciconfig btmgmt bluetoothctl busctl rfkill lsusb dkms; do
  have "$t" || note "optional tool missing: $t (some sections will be reduced)"
done

# --------------------------------------------------------- presence

hr "ADAPTER PRESENCE"
echo "  (hardware seen by USB vs controllers BlueZ can use)"
# count controllers via glob; hciN:M entries are connections, not controllers
HCI_N=0
for h in /sys/class/bluetooth/hci*; do
  [ -e "$h" ] || continue
  case "${h##*/}" in hci*:*) continue ;; esac
  HCI_N=$((HCI_N+1))
done
USB_BT=0
if [ -d /sys/bus/usb/devices ]; then
  for d in /sys/bus/usb/devices/*; do
    [ -r "$d/bDeviceClass" ] || continue
    # class E0 / subclass 01 / protocol 01 is the Bluetooth radio interface
    [ "$(cat "$d/bDeviceClass" 2>/dev/null)" = "e0" ] && USB_BT=$((USB_BT+1))
  done
fi
UART_BT=0
for h in /sys/class/bluetooth/hci*; do
  [ -e "$h" ] || continue
  case "$(basename "$h")" in *:*) continue ;; esac   # skip connection objects
  case "$(readlink -f "$h" 2>/dev/null)" in *serial*|*tty*|*uart*) UART_BT=$((UART_BT+1));; esac
done
echo "  hci nodes        : $HCI_N"
echo "  USB BT devices   : $USB_BT"
echo "  UART/serial hci  : $UART_BT"
if [ "$HCI_N" -eq 0 ] && [ "$USB_BT" -gt 0 ]; then
  printf '  %sUSB Bluetooth hardware present but NO hci node exists -> Fix K%s\n' "$Y" "$R"
  echo "    driver did not bind at all. Check: lsmod | grep -E 'btusb|btmtk|btrtl'"
  echo "    rfkill hard block, or Bluetooth disabled in BIOS/UEFI."
elif [ "$HCI_N" -eq 0 ]; then
  printf '  %sno Bluetooth controllers at all -> Fix K%s\n' "$Y" "$R"
  echo "    no USB BT hardware detected either. Check BIOS/UEFI, rfkill, and whether"
  echo "    this machine uses a UART adapter (common on Raspberry Pi and ARM boards)."
fi
if [ "$UART_BT" -gt 0 ]; then
  printf '  %snote: %s UART/serial controller(s) — this toolkit targets USB (btusb).%s\n' "$Y" "$UART_BT" "$R"
  echo "    Diagnosis still applies; bt-patch-btusb.sh and bt-disable-adapter.sh do not."
fi

# ---------------------------------------------------------- adapters

hr "ADAPTERS"
if have hciconfig; then
  hciconfig -a 2>/dev/null | grep -E \
    'hci[0-9]+:|BD Address|UP|DOWN|RX bytes|TX bytes|HCI Version|LMP Version|Manufacturer' \
    | sed 's/^/  /'
else
  note "hciconfig absent (deprecated in newer BlueZ; often in a 'bluez-deprecated' package)"
  for h in /sys/class/bluetooth/hci*; do
    [ -e "$h" ] || continue
    case "$(basename "$h")" in *:*) continue ;; esac
    echo "  $(basename "$h")  address=$(cat "$h/address" 2>/dev/null)"
  done
fi

# --------------------------------------------------- vendor firmware

hr "VENDOR FIRMWARE LOG"
echo "  (zero lines for a vendor chip means firmware never loaded -> ROM mode)"
FWPAT='RTL:|btrtl|rtl[0-9]{4}|btintel|ibt-|btmtk|mt[0-9]{4}|btbcm|BCM[:_ 0-9]|hci[0-9]+: .*[Ff]irmware'
if have journalctl; then
  n=$(journalctl -k -b --no-pager 2>/dev/null | grep -icE "$FWPAT" || true)
  echo "  matching lines this boot: ${n:-0}"
  journalctl -k -b --no-pager 2>/dev/null | grep -iE "$FWPAT" | tail -20 | sed 's/^/  /'
elif have dmesg; then
  n=$(dmesg 2>/dev/null | grep -icE "$FWPAT" || true)
  echo "  matching lines: ${n:-0}  (dmesg may need root)"
  dmesg 2>/dev/null | grep -iE "$FWPAT" | tail -20 | sed 's/^/  /'
else
  note "no journalctl or dmesg available"
fi

echo "  -- firmware load FAILURES (attempted but failed != never attempted) --"
FAILPAT='Direct firmware load.*failed|failed to load|no support for firmware file|failed:? *\(?-[0-9]+|timed? ?out'
if have journalctl; then
  # scope to Bluetooth lines first, otherwise unrelated USB/ACPI timeouts look like hits
  fails=$(journalctl -k -b --no-pager 2>/dev/null | grep -iE 'bluetooth|btusb|hci[0-9]' | grep -iE "$FAILPAT" | tail -10)
  [ -n "$fails" ] && printf '%s\n' "$fails" | sed 's/^/    /' || echo "    (none)"
fi

# --------------------------------------------------- power management

hr "POWER MANAGEMENT"
echo "  (USB autosuspend is a very common cause of 'works, then dies after minutes')"
echo "  btusb enable_autosuspend module parameter:"
ap=$(cat /sys/module/btusb/parameters/enable_autosuspend 2>/dev/null || echo "?")
case "$ap" in
  Y|y|1) printf '    %s%s — autosuspend ENABLED; suspect it if devices drop when idle%s\n' "$Y" "$ap" "$R" ;;
  N|n|0) echo "    $ap — autosuspend disabled" ;;
  *)     echo "    unknown" ;;
esac
echo "  per-device USB power control:"
shown_pm=" "
for i in /sys/bus/usb/drivers/btusb/*:*; do
  [ -e "$i" ] || continue
  n=$(basename "$i"); parent=${n%%:*}; d=/sys/bus/usb/devices/$parent
  [ -d "$d/power" ] || continue
  case "$shown_pm" in *" $parent "*) continue ;; esac
  shown_pm="$shown_pm$parent "
  printf '    %-10s control=%s autosuspend_delay_ms=%s\n' "$parent" \
    "$(cat "$d/power/control" 2>/dev/null)" \
    "$(cat "$d/power/autosuspend_delay_ms" 2>/dev/null)"
done
for f in /etc/modprobe.d/*.conf; do
  [ -r "$f" ] || continue
  grep -l 'btusb' "$f" >/dev/null 2>&1 && echo "    modprobe config: $f -> $(grep -h btusb "$f" | head -2 | tr '\n' ' ')"
done

# ------------------------------------------------ suspend/resume health

hr "SUSPEND / RESUME"
if have journalctl; then
  nsusp=$(journalctl -b --no-pager 2>/dev/null | grep -ic 'PM: suspend exit\|Resuming from\|systemd-sleep' || true)
  echo "  resume events this boot: ${nsusp:-0}"
  if [ "${nsusp:-0}" -gt 0 ]; then
    echo "  bluetooth errors logged after the most recent resume:"
    journalctl -b --no-pager 2>/dev/null \
      | awk '/PM: suspend exit|Resuming from/{buf=""} {buf=buf"\n"$0} END{print buf}' \
      | grep -iE 'bluetooth|btusb|hci[0-9]' | grep -iE 'error|fail|timeout|-110|-19' \
      | tail -8 | sed 's/^/    /' || true
    echo "    (empty above = resume looks clean)"
  fi
fi
for hook in /usr/lib/systemd/system-sleep/*blue* /lib/systemd/system-sleep/*blue*; do
  [ -e "$hook" ] && echo "  sleep hook: $hook"
done

# ------------------------------------------------------- audio stack

hr "AUDIO STACK (for headset problems)"
running=""
for p in pipewire wireplumber pulseaudio; do
  pgrep -x "$p" >/dev/null 2>&1 && running="$running $p"
done
echo "  running:${running:-  none}"
case "$running" in
  *pipewire*pulseaudio*|*pulseaudio*pipewire*) note "both PipeWire and PulseAudio appear to be running — expect conflicts" ;;
esac
if printf '%s' "$running" | grep -q pipewire; then
  if have pw-cli; then
    n=$(pw-cli list-objects Node 2>/dev/null | grep -c 'bluez_' || true)
    echo "  PipeWire bluez nodes: ${n:-0}"
    [ "${n:-0}" = 0 ] && note "no bluez audio nodes — the BlueZ SPA plugin may be missing (libspa-0.2-bluetooth)"
  fi
fi
if have busctl; then
  t=$(busctl tree org.bluez 2>/dev/null | grep -c '/fd[0-9]' || true)
  echo "  active A2DP transports: ${t:-0}"
fi

# ---------------------------------------------------- bond persistence

hr "BOND PERSISTENCE"
echo "  (bonds live in /var/lib/bluetooth; losing them means re-pairing every boot)"
if [ -r /var/lib/bluetooth ]; then
  find /var/lib/bluetooth -maxdepth 2 -name 'info' 2>/dev/null | wc -l | sed 's/^/  stored bonds: /'
else
  echo "  /var/lib/bluetooth not readable as this user (normal) — re-run with sudo to inspect"
fi

# ------------------------------------------------------ usb hardware

hr "BLUETOOTH USB HARDWARE"
if have lsusb; then
  lsusb 2>/dev/null | grep -iE 'blue|bluetooth' | sed 's/^/  /' || echo "  (no USB Bluetooth device matched by name)"
else
  note "lsusb absent; listing from sysfs instead"
fi

echo "  -- USB devices whose interfaces bind btusb --"
if [ -d /sys/bus/usb/drivers/btusb ]; then
  found=0
  for i in /sys/bus/usb/drivers/btusb/*:*; do
    [ -e "$i" ] || continue
    n=$(basename "$i"); parent=${n%%:*}
    d=/sys/bus/usb/devices/$parent
    printf '    %-12s %s:%s  authorized=%s  %s\n' \
      "$n" \
      "$(cat "$d/idVendor" 2>/dev/null || echo ????)" \
      "$(cat "$d/idProduct" 2>/dev/null || echo ????)" \
      "$(cat "$d/authorized" 2>/dev/null || echo ?)" \
      "$(cat "$d/product" 2>/dev/null || echo '')"
    found=1
  done
  [ "$found" = 0 ] && echo "    (none bound)"
else
  note "btusb driver not present in sysfs — module not loaded?"
fi

echo "  -- deauthorized USB devices (a deliberately disabled adapter shows here) --"
any=0
for d in /sys/bus/usb/devices/*; do
  [ -r "$d/authorized" ] || continue
  [ "$(cat "$d/authorized" 2>/dev/null)" = "0" ] || continue
  printf '    %-10s %s:%s %s\n' "$(basename "$d")" \
    "$(cat "$d/idVendor" 2>/dev/null)" "$(cat "$d/idProduct" 2>/dev/null)" \
    "$(cat "$d/product" 2>/dev/null || echo '')"
  any=1
done
[ "$any" = 0 ] && echo "    (none)"

# ------------------------------------------- per-adapter attribution

hr "PER-ADAPTER DEVICE ATTRIBUTION"
echo "  (the only trustworthy count — bluetoothctl's [NEW] lines do not name the adapter)"
if have busctl; then
  mapfile -t ADAPTERS < <(busctl tree org.bluez 2>/dev/null \
    | grep -oE '/org/bluez/hci[0-9]+$' | grep -oE 'hci[0-9]+' | sort -u)
  if [ "${#ADAPTERS[@]}" -eq 0 ]; then
    note "no adapters exposed on D-Bus (is bluetoothd running?)"
  fi
  for h in "${ADAPTERS[@]}"; do
    p=/org/bluez/$h
    addr=$(busctl get-property org.bluez "$p" org.bluez.Adapter1 Address 2>/dev/null | cut -d'"' -f2)
    pw=$(busctl get-property org.bluez "$p" org.bluez.Adapter1 Powered 2>/dev/null | awk '{print $2}')
    disc=$(busctl get-property org.bluez "$p" org.bluez.Adapter1 Discovering 2>/dev/null | awk '{print $2}')
    cnt=$(busctl tree org.bluez 2>/dev/null | grep -c "$h/dev_")
    printf '  %-6s %-18s Powered=%-5s Discovering=%-5s devices_seen=%s\n' \
      "$h" "${addr:-?}" "${pw:-?}" "${disc:-?}" "$cnt"
  done
else
  note "busctl absent — cannot attribute discoveries per adapter"
fi

# ------------------------------------------------- paired / connected

hr "PAIRED / CONNECTED DEVICES"
if have busctl; then
  any=0
  while read -r p; do
    [ -n "$p" ] || continue
    pa=$(busctl get-property org.bluez "$p" org.bluez.Device1 Paired 2>/dev/null | awk '{print $2}')
    co=$(busctl get-property org.bluez "$p" org.bluez.Device1 Connected 2>/dev/null | awk '{print $2}')
    [ "$pa" = "true" ] || [ "$co" = "true" ] || continue
    al=$(busctl get-property org.bluez "$p" org.bluez.Device1 Alias 2>/dev/null | cut -d'"' -f2)
    ic=$(busctl get-property org.bluez "$p" org.bluez.Device1 Icon 2>/dev/null | cut -d'"' -f2)
    printf '  %s\n    alias=%s icon=%s Paired=%s Connected=%s\n' "$p" "${al:-?}" "${ic:-?}" "$pa" "$co"
    any=1
  done < <(busctl tree org.bluez 2>/dev/null | grep -oE '/org/bluez/hci[0-9]+/dev_[0-9A-F_]+$' | sort -u)
  [ "$any" = 0 ] && echo "  (none)"
fi

# --------------------------------------------------------------- rfkill

hr "RFKILL"
if have rfkill; then rfkill list 2>/dev/null | sed 's/^/  /'; else note "rfkill absent"; fi

# --------------------------------------------------- module provenance

hr "MODULE PROVENANCE"
echo "  (after a DKMS install, RAM and disk must match — udev often reloads the stock module)"
ram=$(cat /sys/module/btusb/srcversion 2>/dev/null || echo "btusb not loaded")
disk=$(modinfo btusb 2>/dev/null | awk '/^srcversion/{print $2}')
file=$(modinfo btusb 2>/dev/null | awk '/^filename/{print $2}')
echo "  RAM   : $ram"
echo "  disk  : ${disk:-?}"
echo "  file  : ${file:-?}"
if [ -n "$disk" ] && [ "$ram" != "btusb not loaded" ] && [ "$ram" != "$disk" ]; then
  printf '  %sMISMATCH — the module in RAM is not the one on disk. Reload it.%s\n' "$Y" "$R"
fi
if have dkms; then
  echo "  -- dkms status --"
  dkms status 2>/dev/null | sed 's/^/    /' || true
fi

# -------------------------------------------------------------- verdict

hr "VERDICT HINTS"
if [ "$HCI_N" -eq 0 ]; then
  printf '  %sno controllers to judge — see ADAPTER PRESENCE above (Fix K).%s\n' "$Y" "$R"
elif have hciconfig; then
  for h in /sys/class/bluetooth/hci*; do
    [ -e "$h" ] || continue
    case "$(basename "$h")" in *:*) continue ;; esac
    n=$(basename "$h")
    acl=$(hciconfig "$n" 2>/dev/null | grep -oE 'acl:[0-9]+' | head -1 | cut -d: -f2)
    [ -n "$acl" ] || continue
    if [ "$acl" = "0" ]; then
      printf '  %s%s: acl:0 — has NEVER carried a connection.%s Check the firmware log above (Fix A).\n' "$Y" "$n" "$R"
      echo "        Before patching, check your kernel already lacks the ID:"
      echo "          grep '0xVVVV, 0xPPPP' /usr/src/linux-headers-\$(uname -r)/drivers/bluetooth/btusb.c"
      echo "        Many of these are merged upstream; an override you forget is worse than none."
    else
      printf '  %s%s: acl:%s — radio has carried real traffic;%s look beyond the adapter.\n' "$G" "$n" "$acl" "$R"
    fi
  done
else
  note "cannot read the acl counter without hciconfig — install your distro's bluez-deprecated package"
fi

sb="unknown"
if have mokutil; then
  sb=$(mokutil --sb-state 2>/dev/null | head -1)
elif [ -d /sys/firmware/efi ]; then
  f=$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -1)
  [ -n "$f" ] && sb="SecureBoot byte=$(od -An -t u1 "$f" 2>/dev/null | awk '{print $5}') (1=on, 0=off)"
else
  sb="not an EFI system"
fi
echo "  Secure Boot: $sb  (if enabled, unsigned out-of-tree modules will not load)"

lockdown=$(cat /sys/kernel/security/lockdown 2>/dev/null || echo "")
[ -n "$lockdown" ] && echo "  Kernel lockdown: $lockdown"

printf '\n%sNext:%s read SKILL.md — match the table on acl / firmware lines / scan result.\n' "$B" "$R"
