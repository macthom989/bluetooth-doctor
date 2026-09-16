---
name: bluetooth-doctor
description: Diagnose and fix Linux Bluetooth adapters that look healthy but do not work - scans return nothing, pairing fails, a device will not connect, audio crackles or drops out, or the wrong adapter keeps grabbing a device. Use when hciconfig or bluetoothctl report an adapter UP RUNNING yet nothing works, when vendor firmware may not be loading (Realtek, Intel, MediaTek, Broadcom), when a USB dongle is missing from btusb's device table, or when two adapters compete for one device. Triggers - "bluetooth not working", "scan finds nothing", "no devices found", "dongle not working", "pairing fails", "bluetooth stuttering", "audio drops", "hci0 dead", "cannot pair headphones".
---

# Bluetooth Doctor (Linux / BlueZ)

**`UP RUNNING` does not mean the radio works.** A controller stuck on ROM firmware
answers HCI commands and reports a plausible version while the antenna does nothing.
Never judge health from `hciconfig` or `bluetoothctl show`.

Two signals cannot lie:

| Signal | Meaning |
|---|---|
| `acl:0` | this controller has **never** carried a connection |
| no vendor firmware lines in kernel log | firmware never loaded → ROM mode |

## 1. Collect evidence — before any theory

```bash
scripts/bt-triage.sh          # read-only, no root
```

Manually: `hciconfig -a`, `journalctl -k -b | grep -iE 'RTL:|btintel|btmtk|btbcm'`,
`lsusb | grep -i blue`, `rfkill list`.

**Attribute findings per adapter.** `bluetoothctl`'s `[NEW] Device` lines do not say
which adapter found the device, and both can scan at once. Use:

```bash
busctl tree org.bluez | grep -c 'hci0/dev_'
```

## 2. Classify

First check an adapter exists at all (`hciconfig`, or the collector's ADAPTER PRESENCE
section). With no `hciN` there is no `acl` to read and the rest of this table does not
apply. Otherwise `acl` splits "never worked" from "worked then broke".

| Symptom | Firmware log | Fix |
|---|---|---|
| **no `hciN` exists at all** | any | **K** — driver never bound |
| never worked, finds nothing | no lines at all | **A** — ID missing from btusb |
| never worked, finds nothing | lines, but `failed` / `-2` | **D** — wrong or missing blob |
| never worked, finds nothing | loaded cleanly | antenna / RF / faulty unit |
| works, dies after minutes | clean | **E** — USB autosuspend |
| dead after suspend | clean | **F** — resume breakage |
| drops instantly, or no A2DP | clean | **G** — audio stack |
| re-pair every boot | clean | **H** — bond persistence |
| crackles while connected | clean | **C** — RF coexistence |
| gamepad drops in 2–5s | clean | **I** — ERTM |
| refuses to pair at all | clean | **J** — BlueZ options |
| lands on the wrong adapter | any | **B** — adapter conflict |

`No default controller available` is a symptom, not a cause — work the top rows.

## 3. Fix

### A — USB ID missing from btusb

Device matches only btusb's generic class rule, so `driver_info = 0`, the vendor flag
is never set, firmware never downloads.

```bash
sudo scripts/bt-patch-btusb.sh VVVV:PPPP        # patch + DKMS, survives kernel upgrades
sudo scripts/bt-patch-btusb.sh --uninstall      # roll back
```

Then **confirm the patched module is the one in RAM** — udev often reloads the stock one:

```bash
cat /sys/module/btusb/srcversion     # must equal:
modinfo btusb | grep srcversion
# differ? systemctl stop bluetooth && modprobe -r btusb && modprobe btusb
```

**Check whether your kernel already carries the ID first** — see `reference.md`;
`2c4e:0115` for example landed in kernel 7.2, so on 7.2+ the right move is to upgrade,
not to patch.

Not evidence of anything: `modinfo` showing no vendor aliases (quirks live in a
secondary table). `new_id` cannot fix this — it only reads the primary table.
Secure Boot blocks unsigned modules: check `mokutil --sb-state`.

### B — two adapters competing

```bash
scripts/bt-disable-adapter.sh --list
sudo scripts/bt-disable-adapter.sh VVVV:PPPP
sudo scripts/bt-disable-adapter.sh --undo VVVV:PPPP
```

| Method | Reboot | Module reload | Desktop BT toggle |
|---|---|---|---|
| `ATTR{authorized}="0"` | ✅ | ✅ | ✅ |
| driver `unbind` | ❌ | ❌ udev rebinds | ✅ |
| `rfkill block` | usually | ✅ | ❌ GNOME resets it |

Writing the rule by hand: `authorized` and `idVendor` live on the **usb_device** (plain
`ATTR{}`). An *unbind* rule needs `ATTRS{}` on the **usb_interface** — `unbind` only
accepts names like `1-14:1.0`. Mixing these up fails silently. The rule fires on
`ACTION=="add"`, so apply it to the running system too.

Disabling a combo chip's Bluetooth does not affect its Wi-Fi (separate PCI device).

### C — crackles, stutters, drops

CNVi parts share one RF front-end between Wi-Fi and Bluetooth. Architectural, not
config. A separate USB dongle with independent RF often beats a newer shared radio.

```bash
echo 'options iwlwifi power_save=0 bt_coex_active=0' | sudo tee /etc/modprobe.d/iwlwifi-bt.conf
# then move Wi-Fi to 5GHz; if it persists, use a USB dongle
```

### D — firmware requested but fails

```
Direct firmware load for rtl_bt/rtl8761bu_fw.bin failed with error -2
```

```bash
journalctl -k -b | grep -iE 'Direct firmware load|loading rtl_bt'
ls -l /lib/firmware/rtl_bt/ | grep 8761
```

1. Update `linux-firmware` — usually just outdated.
2. Symlink the variant the driver asks for (`rtl8761b` vs `rtl8761bu` is the classic
   trap), then replug. Files may be `.zst`; link like for like.
3. Newer kernel — variant selection has been fixed repeatedly.

**Broadcom** needs a per-model `.hcd` the log names; get it from
`winterheart/broadcom-bt-firmware`, or convert the vendor `.hex` with `hex2hcd` into
`/lib/firmware/brcm`. **Combo chips** (BCM4354/4356) need Wi-Fi firmware first or
Bluetooth never initialises. **MediaTek** often lacks the `btmtk` module or a symlink.

### E — works, then dies after minutes

```bash
cat /sys/module/btusb/parameters/enable_autosuspend      # Y = suspect
echo 'options btusb enable_autosuspend=0' | sudo tee /etc/modprobe.d/btusb-noautosuspend.conf
```

Immediate, per device: `echo on > /sys/bus/usb/devices/<busid>/power/control`.

### F — dead after suspend/resume

```bash
sudo modprobe -r btusb && sudo modprobe btusb      # recovery
```

Automate with a sleep hook:

```bash
sudo tee /usr/lib/systemd/system-sleep/bluetooth-reload >/dev/null <<'EOF'
#!/bin/sh
[ "$1" = "post" ] || exit 0
modprobe -r btusb 2>/dev/null; modprobe btusb 2>/dev/null
EOF
sudo chmod +x /usr/lib/systemd/system-sleep/bluetooth-reload
```

Workaround for a kernel race; recheck after upgrades.

### G — drops instantly, or no A2DP

```bash
pgrep -x pipewire wireplumber pulseaudio     # exactly one stack
pw-cli list-objects Node | grep bluez_       # zero nodes = SPA plugin missing
```

- PipeWire/WirePlumber racing BlueZ → `systemctl --user restart wireplumber pipewire pipewire-pulse`
- Missing `libspa-0.2-bluetooth` (or `pulseaudio-module-bluetooth`) → pairs, no audio
- Both PipeWire and PulseAudio running → pick one
- Weak signal demotes the link — test at close range first

**Mic sounds terrible** is protocol, not a fault: A2DP is output-only, the mic needs
narrowband HSP/HFP. Best available is mSBC, which needs `wide-band-speech` on the
controller — hence `BTUSB_WIDEBAND_SPEECH` in Fix A.

### H — re-pair every boot

```bash
sudo ls -la /var/lib/bluetooth/*/
```

Check the filesystem is writable, not a tmpfs, and that the adapter MAC is stable — a
changing address gets a fresh directory and loses every bond. Dual-booting rewrites the
device's key, so each OS must be paired separately.

### I — gamepad pairs then drops in 2–5s (ERTM)

```bash
echo Y | sudo tee /sys/module/bluetooth/parameters/disable_ertm          # test
echo 'options bluetooth disable_ertm=1' | sudo tee /etc/modprobe.d/bluetooth-noertm.conf
```

Keep `UserspaceHID=true` in `/etc/bluetooth/input.conf`. Audio devices are unaffected.

### J — refuses to pair

`/etc/bluetooth/main.conf`, then `systemctl restart bluetooth`. Change one at a time:

```ini
[General]
JustWorksRepairing = always
FastConnectable = true
Experimental = true       # also enables battery reporting
```

### K — no adapter appears at all

`lsusb` shows Bluetooth hardware but `hciconfig` is empty, or `bluetoothctl` says
`No default controller available`. No driver bound, so there is nothing to diagnose yet.

```bash
lsmod | grep -E 'btusb|btrtl|btintel|btmtk|btbcm'    # driver loaded?
sudo modprobe btusb
rfkill list                                          # Hard blocked: yes = physical switch or BIOS
dmesg | grep -iE 'bluetooth|btusb' | tail -20
```

Work through, in order:

1. **Driver not loaded** — `modprobe btusb`; a missing vendor module (`btmtk` is the
   common one) also prevents the controller from ever appearing.
2. **Hard rfkill** — cannot be cleared in software. Physical switch, Fn key, or BIOS.
3. **Disabled in BIOS/UEFI** — check there before anything else on laptops.
4. **Kernel too old for the hardware** — newer adapters need newer kernels.
5. **Deliberately disabled** — a previous `ATTR{authorized}="0"` rule (see Fix B):
   `scripts/bt-disable-adapter.sh --list` shows disabled devices.

Note: a device whose USB ID is missing from btusb still usually appears as `hciN` via
the generic class rule — that is **Fix A**, not this. Fix K is when nothing appears.

## Scope

This toolkit targets **USB adapters driven by `btusb`**. Diagnosis (the decision table,
`acl`, firmware logs) applies to any controller, but `bt-patch-btusb.sh` and
`bt-disable-adapter.sh` do not work on non-USB hardware.

**UART/serial controllers** — onboard Bluetooth on Raspberry Pi and most ARM boards uses
`hci_uart` with `btbcm`/`hci_bcm`, not `btusb`. There is no `authorized` attribute and no
USB ID to patch. For those: firmware still comes from `/lib/firmware/brcm/*.hcd`
(Fix D applies), attachment is via `btattach`/`hciattach` or a device-tree overlay, and
disabling is done with `rfkill` or by removing the overlay. The collector reports how
many UART controllers it sees so you know you are in this territory.

## 4. Verify — no success report without these

```bash
journalctl -k -b | grep -iE 'RTL:|btintel|btmtk'   # firmware lines present
hciconfig hciN | grep 'RX bytes'                   # acl > 0 after connecting
busctl tree org.bluez | grep -c 'hciN/dev_'        # this adapter found devices
```

`acl` climbing above 0 is the only proof that matters.

## Anti-patterns

- Treating `UP RUNNING` or a clean `bluetoothctl show` as a working radio.
- Crediting scan results to an adapter without `grep hciN/dev_`.
- `printf 'scan on\n' | bluetoothctl` — exits on stdin EOF before discovery returns
  anything, giving a false "found nothing". Use `bluetoothctl --timeout N scan on`.
- Grepping the whole `busctl tree` for a device — matches cached objects on other
  adapters. Always scope to `hciN/`.
- Asking the user to press the pairing button before ruling out the adapter. Pairing
  mode expires in ~5 min: open the scan window **first**, then ask.
- Concluding a dongle is dead because two local adapters cannot see each other — BlueZ
  controllers on one host do not reliably discover one another.
- Guessing a numeric `driver_info` for `new_id`. Flags shift between kernel versions.

## Pairing notes

A bonded headset advertises as *connectable*, not *discoverable* — the button is
required. BLE and BR/EDR use **different addresses**; an entry suffixed `-LE` is not
usable for A2DP. Clearing the host bond does not clear the headset's own list; a factory
reset does.

## Reference

`reference.md` — firmware log signatures per vendor, ROM-mode signatures, btusb table
internals and flag values, kernel tag pitfalls, udev syntax, rollback.
