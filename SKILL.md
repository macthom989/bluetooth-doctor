---
name: bluetooth-doctor
description: Diagnose and fix Linux Bluetooth adapters that look healthy but do not work - scans return nothing, pairing fails, a device will not connect, audio crackles or drops out, or the wrong adapter keeps grabbing a device. Use when hciconfig or bluetoothctl report an adapter UP RUNNING yet nothing works, when vendor firmware may not be loading (Realtek, Intel, MediaTek, Broadcom), when a USB dongle is missing from btusb's device table, or when two adapters compete for one device. Triggers - "bluetooth not working", "scan finds nothing", "no devices found", "dongle not working", "pairing fails", "bluetooth stuttering", "audio drops", "hci0 dead", "cannot pair headphones".
---

# Bluetooth Adapter Triage (Linux / BlueZ)

## The core trap — read before forming any theory

**`UP RUNNING` does not mean the radio works.** A controller stuck on its on-chip ROM
firmware still answers HCI commands, reports a plausible Bluetooth version and vendor
name, accepts `power on`, and shows `UP RUNNING PSCAN ISCAN`. Every surface check
passes. The antenna does nothing.

Never conclude an adapter is healthy from `hciconfig`, `bluetoothctl show`, or the
absence of errors. Two counters settle it, and both are cheap:

| Signal | Meaning |
|---|---|
| `acl:0` in `hciconfig` | this controller has **never** carried a connection |
| no vendor firmware lines in the kernel log | firmware never loaded → ROM mode |

## Phase 1 — collect evidence first

Run the bundled collector before theorising. It is read-only and needs no root:

```bash
scripts/bt-triage.sh
```

It reports adapters and their `acl` counters, vendor firmware log lines, USB IDs and
bind state, per-adapter discovery attribution, rfkill, module provenance, Secure Boot,
and prints verdict hints.

Equivalent manual commands:

```bash
hciconfig -a
journalctl -k -b | grep -iE 'RTL:|btrtl|btintel|ibt-|btmtk|btbcm|firmware'
lsusb | grep -i blue
busctl tree org.bluez | grep -E '/org/bluez/hci[0-9]+$'
rfkill list
```

### Rule: attribute every finding to a specific adapter

With more than one controller, `bluetoothctl`'s `[NEW] Device ...` lines **do not say
which adapter found the device**, and both controllers can be discovering at once.
Counting those lines and crediting the wrong adapter is the easiest way to misdiagnose
this class of fault.

Confirm per-adapter instead — this is unambiguous:

```bash
busctl tree org.bluez | grep 'hci0/dev_'      # devices THIS adapter actually found
busctl tree org.bluez | grep -c 'hci0/dev_'
```

### Decision table

Distinguish **firmware never attempted** from **firmware attempted and failed** — they
have different causes and different fixes. The collector prints both.

| Symptom | Firmware log | Conclusion |
|---|---|---|
| never works, `acl:0`, finds nothing | **no lines at all** | ID missing from btusb → **Fix A** |
| never works, `acl:0`, finds nothing | lines present, but `failed` / `-2` / `Opcode … failed` | wrong or missing firmware blob → **Fix D** |
| never works, `acl:0`, finds nothing | loaded cleanly | antenna, RF environment, or faulty unit |
| works, then dies after minutes | clean | USB autosuspend → **Fix E** |
| works until suspend, dead after resume | clean | resume breakage → **Fix F** |
| connects, then drops instantly; or no A2DP | clean | audio stack → **Fix G** |
| must re-pair on every boot | clean | bond persistence → **Fix H** |
| audio crackles or stutters while connected | clean | coexistence / power → **Fix C** |
| device keeps landing on the other adapter | any | adapter conflict → **Fix B** |

`acl:0` separates "never worked" from "worked and then broke". That split decides
which half of this table you are in; check it first.

## Phase 2 — fixes

### Fix A — vendor firmware never loads (USB ID missing from btusb)

`btusb` matches such a dongle only through its generic Bluetooth-class rule
(`usb:v*p*d*dc*dsc*dp*icE0isc01ip01in*`), so `driver_info` stays `0`, the vendor flag
is never set, the vendor module never runs, and the chip keeps executing ROM firmware.

Confirm the ID is absent from the kernel you are running, not from memory:

```bash
lsusb | grep -i blue                    # note the VVVV:PPPP
scripts/bt-patch-btusb.sh VVVV:PPPP --build-only   # reports if already supported
```

Two things that look like evidence but are not:
- `modinfo btusb` showing no vendor aliases. Vendor quirks live in a **secondary**
  table that generates no modaliases; its absence there is normal.
- The `new_id` sysfs interface. It can only inherit `driver_info` from the **primary**
  table, which these entries are not in. It cannot fix this.

Apply the fix — patches `btusb`, builds, and installs via DKMS so it survives kernel
upgrades. It fetches kernel sources at the matching tag and generates its own build
files; no third-party repository is involved:

```bash
sudo scripts/bt-patch-btusb.sh VVVV:PPPP
sudo scripts/bt-patch-btusb.sh VVVV:PPPP --quirks "BTUSB_REALTEK"   # non-default flags
sudo scripts/bt-patch-btusb.sh --uninstall                          # roll back
```

`BTUSB_WIDEBAND_SPEECH` is included by default alongside the vendor flag; it enables
mSBC so HFP call audio is not downgraded to narrowband.

**Always confirm the patched module is the one in RAM.** udev frequently reloads the
stock module during installation, which makes a successful patch look like a total
failure:

```bash
cat /sys/module/btusb/srcversion     # module in RAM
modinfo btusb | grep srcversion      # module on disk
# differ? reload:
sudo systemctl stop bluetooth && sudo modprobe -r btusb && sudo modprobe btusb
sudo systemctl start bluetooth
```

Check Secure Boot first — an unsigned out-of-tree module will not load while it is
enabled unless the signing key is enrolled: `mokutil --sb-state`.

### Fix B — two adapters competing for one device

A bonded device reconnects to whichever adapter holds its bond, and desktop
environments re-pair it automatically. Removing the bond is not enough on its own; the
adapter you do not want must be genuinely unavailable.

```bash
scripts/bt-disable-adapter.sh --list             # see candidates, no root needed
sudo scripts/bt-disable-adapter.sh VVVV:PPPP     # disable now + persist
sudo scripts/bt-disable-adapter.sh --undo VVVV:PPPP
```

**Use the strongest lever that holds**, in this order:

| Method | Survives reboot | Survives module reload | Survives desktop BT toggle |
|---|---|---|---|
| `ATTR{authorized}="0"` udev rule | ✅ | ✅ | ✅ |
| driver `unbind` | ❌ | ❌ udev rebinds it | ✅ |
| `rfkill block` | usually | ✅ | ❌ GNOME resets it |

Two traps when writing such a rule by hand:
- `authorized` and `idVendor` live on the **usb_device**, so plain `ATTR{}` is correct.
  An *unbind* rule instead needs `ATTRS{}` on the **usb_interface**, because
  `/sys/bus/usb/drivers/btusb/unbind` accepts only interface names like `1-14:1.0`. A
  rule that mixes these up **fails silently**.
- The rule fires on `ACTION=="add"`, so it does nothing to an already-enumerated
  device. Apply it to the running system too.

Disabling a combo chip's Bluetooth **does not** affect its Wi-Fi — Wi-Fi is a separate
PCI device. Confirm with `lspci | grep -i network`.

### Fix C — audio stutters, crackles or drops

On **CNVi** parts (many recent Intel wireless modules) Wi-Fi and Bluetooth share one
RF front-end, so busy or 2.4GHz Wi-Fi starves Bluetooth audio. This is architectural,
not a misconfiguration.

Do not assume a separate USB dongle is a downgrade because its Bluetooth version
number is lower — independent RF often beats a newer shared radio for audio stability.

```bash
# Intel: disable power saving and BT coexistence arbitration
echo 'options iwlwifi power_save=0 bt_coex_active=0' | sudo tee /etc/modprobe.d/iwlwifi-bt.conf
# then move Wi-Fi to 5GHz; if it persists, move Bluetooth to a separate USB dongle
```

### Fix D — firmware is requested but fails to load

The driver asks for a blob that is absent or wrongly named. Unlike Fix A there **are**
vendor log lines — they just end in failure:

```
Direct firmware load for rtl_bt/rtl8761bu_fw.bin failed with error -2
Bluetooth: hci0: Opcode 0x0c03 failed: -110
```

Realtek's `8761b` and `8761bu` blobs are a well-known trap: some dongles are driven by
code requesting the `bu` variant while the distribution ships only the plain `b` files,
or the reverse. Check which the driver asked for, then check what exists:

```bash
journalctl -k -b | grep -iE 'Direct firmware load|loading rtl_bt'
ls -l /lib/firmware/rtl_bt/ | grep 8761
```

Fix, in order of preference:
1. **Update `linux-firmware`** — the blob is usually just outdated or missing.
2. **Symlink the variant** the driver asks for to the one you have, then replug:
   ```bash
   cd /lib/firmware/rtl_bt
   sudo ln -sf rtl8761b_fw.bin     rtl8761bu_fw.bin       # adapt to your filenames
   sudo ln -sf rtl8761b_config.bin rtl8761bu_config.bin
   ```
   Note the files may be `.zst`-compressed on newer distributions; link like for like.
3. **Newer kernel** — the variant selection logic has been corrected repeatedly.

**Broadcom needs a per-model `.hcd` blob** that is often absent from `linux-firmware`,
especially on MacBooks and older laptops. The log names the file it wants:

```
Bluetooth: hci0: BCM: firmware patch brcm/BCM20702A1-0a5c-21e6.hcd not found
```

Community collections package these (`winterheart/broadcom-bt-firmware`), or it can be
converted from the vendor's Windows driver: find the hardware ID in the driver's `.inf`,
then convert the matching `.hex` with `hex2hcd`. Place the result in `/lib/firmware/brcm`
and replug.

**Combo Wi-Fi/Bluetooth chips (e.g. BCM4354, BCM4356) need their Wi-Fi firmware first** —
without it the Bluetooth side never initialises. Fix Wi-Fi before concluding Bluetooth
is broken.

**MediaTek** commonly fails with a missing `btmtk` module or an unlinked firmware
variant; the same symlink approach applies.

### Fix E — works, then drops after minutes of idle

USB autosuspend powers down the radio. Classic signature: a mouse or headset that
"disconnects randomly" after 5–15 minutes but reconnects when you interact with it.

```bash
cat /sys/module/btusb/parameters/enable_autosuspend      # Y means suspect it
echo 'options btusb enable_autosuspend=0' | sudo tee /etc/modprobe.d/btusb-noautosuspend.conf
sudo modprobe -r btusb && sudo modprobe btusb            # or reboot
```

For a single device without touching the module, set its power control to `on`:
`echo on | sudo tee /sys/bus/usb/devices/<busid>/power/control`.

### Fix F — Bluetooth dead after suspend/resume

The controller does not come back. Toggling Bluetooth and restarting `bluetooth.service`
both fail; only a module reload recovers it. Known to affect several Intel and Realtek
controllers depending on kernel and firmware.

Immediate recovery:
```bash
sudo modprobe -r btusb && sudo modprobe btusb
```

Make it automatic with a systemd sleep hook:
```bash
sudo tee /usr/lib/systemd/system-sleep/bluetooth-reload >/dev/null <<'EOF'
#!/bin/sh
[ "$1" = "post" ] || exit 0
modprobe -r btusb 2>/dev/null
modprobe btusb 2>/dev/null
EOF
sudo chmod +x /usr/lib/systemd/system-sleep/bluetooth-reload
```

This is a workaround for a kernel-side race between the PM notifier's HCI shutdown and
USB teardown. Re-check after kernel upgrades and remove it once it is no longer needed.

### Fix G — connects then disconnects instantly, or no A2DP profile

The adapter is fine; the audio stack is the problem. Symptoms: the device connects and
drops within a second or two, or only HSP/HFP is offered and A2DP never appears.

```bash
pgrep -x pipewire wireplumber pulseaudio     # exactly one stack should be running
pw-cli list-objects Node | grep bluez_       # zero nodes = BlueZ SPA plugin missing
busctl tree org.bluez | grep '/fd[0-9]'      # an active A2DP transport
```

Common causes:
- **PipeWire/WirePlumber racing BlueZ at startup** — WirePlumber releases the media
  transport before BlueZ is ready. Restart the user audio stack after BlueZ is up:
  `systemctl --user restart wireplumber pipewire pipewire-pulse`.
- **BlueZ audio plugin not installed** — the package is typically
  `libspa-0.2-bluetooth` (PipeWire) or `pulseaudio-module-bluetooth`. Without it the
  device pairs but produces no audio nodes at all.
- **Both PipeWire and PulseAudio running** — pick one.
- **Weak signal** demoting the link so A2DP drops to a lower mode; test at close range
  before chasing software.

**Headset microphone sounds terrible.** This is protocol, not a fault: A2DP is
output-only and high quality, while the mic requires HSP/HFP, which is narrowband by
design. The best available improvement is mSBC (wideband speech):

```bash
# PipeWire (wireplumber): ensure mSBC is enabled
#   bluez5.enable-msbc = true   in a wireplumber bluetooth config drop-in
systemctl --user restart wireplumber
```

mSBC needs support on **both** ends — the controller must advertise
`wide-band-speech` in its kernel feature flags. A controller whose quirks entry lacks
`BTUSB_WIDEBAND_SPEECH` will never offer it, which is why that flag is included by
default when patching in a new USB ID (Fix A).

**"No default controller available"** in `bluetoothctl` is a symptom, not a cause: it
means BlueZ sees no usable adapter. Work the top half of the decision table — it is
almost always Fix A, Fix D, a blocked rfkill, or Bluetooth disabled in BIOS/UEFI.

### Fix H — must re-pair on every boot

Bonds live in `/var/lib/bluetooth/<adapter-mac>/<device-mac>/info`. If they vanish, the
keys are not being persisted.

```bash
sudo ls -la /var/lib/bluetooth/*/            # bonds present?
sudo journalctl -u bluetooth -b | grep -i 'key\|bond\|storage'
```

Check the filesystem is writable and not full, that `/var/lib/bluetooth` is not on a
volatile tmpfs, and that the adapter's MAC is stable — an adapter whose address changes
between boots gets a fresh directory each time and loses every bond. Dual-booting also
invalidates keys: pairing under another OS rewrites the device's key, so each OS must
be re-paired unless the keys are copied across.

### Fix I — gamepad pairs but disconnects after 2–5 seconds (ERTM)

Xbox, PS4/PS5 and many third-party controllers ship an L2CAP implementation that is
incompatible with the kernel's Enhanced Retransmission Mode. The pad pairs, then the
link dies within seconds on reconnect, or shows "connected" while sending no input.

```bash
# test immediately (reverts on reboot)
echo Y | sudo tee /sys/module/bluetooth/parameters/disable_ertm
# persist
echo 'options bluetooth disable_ertm=1' | sudo tee /etc/modprobe.d/bluetooth-noertm.conf
```

Keep `UserspaceHID=true` in `/etc/bluetooth/input.conf` while doing this, so the input
device is still created. ERTM affects only reliability-mode negotiation; audio devices
are unaffected.

### Fix J — device refuses to pair or re-pair at all

Some devices need BlueZ behaviour relaxed. Edit `/etc/bluetooth/main.conf`, then
`sudo systemctl restart bluetooth`:

```ini
[General]
JustWorksRepairing = always   # devices that silently rotate keys
FastConnectable = true        # slow reconnects
Privacy = device
Experimental = true           # battery reporting, LE Audio, newer features
```

`Experimental = true` is also what enables battery-level reporting for many headsets.
Change one setting at a time — these interact.

## Verification gates — do not report success without these

```bash
journalctl -k -b | grep -iE 'RTL:|btintel|btmtk'   # firmware lines present
hciconfig hciN | grep 'RX bytes'                   # acl > 0 after connecting
busctl tree org.bluez | grep -c 'hciN/dev_'        # this adapter found devices
```

`acl` climbing above 0 is the proof that matters. Every other indicator can lie.

## Anti-patterns

- Treating `UP RUNNING`, or a clean `bluetoothctl show`, as evidence of a working radio.
- Crediting scan results to an adapter without `busctl tree ... | grep hciN/dev_`.
- `printf 'scan on\n' | bluetoothctl` — bluetoothctl exits on stdin EOF **before
  discovery returns anything**, producing a false "found nothing". Use
  `bluetoothctl --timeout N scan on` and confirm `Discovery started` appears.
- Grepping the whole `busctl tree` for a device — it matches **cached** objects on
  other adapters. Always scope to `hciN/`.
- Asking the user to press a pairing button repeatedly before ruling out the adapter.
  Pairing mode expires in roughly five minutes: open the scan window **first**, then ask.
- Declaring a dongle dead because two local adapters cannot discover each other —
  BlueZ controllers on one host do not reliably see one another. Compare against a
  real external device.
- Guessing a numeric `driver_info` for `new_id`. Flag values shift between kernel
  versions, and `new_id` cannot reach the quirks table anyway.

## Pairing mechanics worth knowing

- A bonded headset advertises as *connectable*, not *discoverable*. Disconnecting does
  not make it visible; the pairing button is required.
- Headsets advertise BLE and BR/EDR under **different addresses**. A2DP audio needs
  the **classic** address — seeing only an entry suffixed `-LE` means it is not in
  pairing mode yet.
- Removing the host-side bond does not clear the *headset's* memory of that host. A
  factory reset (often both volume buttons for ~5s) forces it to re-advertise.

## Reference

`reference.md` — vendor firmware log signatures, ROM-mode chip signatures, btusb table
internals and flag values, kernel source tag pitfalls, udev rule syntax, and rollback
commands.
