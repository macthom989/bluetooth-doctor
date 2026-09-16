# Reference — Bluetooth adapter triage

Supporting detail for `SKILL.md`. Nothing here is specific to one machine; substitute
your own `VVVV:PPPP`, `hciN` and sysfs bus IDs throughout.

## Vendor firmware log signatures

Presence of these lines in `journalctl -k -b` means the vendor module ran and the
controller left ROM mode. **Absence, for a chip of that vendor, is the diagnosis.**

**Realtek** (`btrtl`)
```
Bluetooth: hciN: RTL: examining hci_ver=0a hci_rev=000b lmp_ver=0a lmp_subver=8761
Bluetooth: hciN: RTL: rom_version status=0 version=1
Bluetooth: hciN: RTL: loading rtl_bt/rtl8761bu_fw.bin
Bluetooth: hciN: RTL: fw version 0x........
```

**Intel** (`btintel`)
```
Bluetooth: hciN: Found device firmware: intel/ibt-....sfi
Bluetooth: hciN: Firmware loaded in ...... usecs
Bluetooth: hciN: Firmware timestamp ....
```

**MediaTek** (`btmtk`) — `Bluetooth: hciN: Firmware version = ...`, `dev=79xx`
**Broadcom** (`btbcm`) — `Bluetooth: hciN: BCM: chip id ...`, `patch brcm/BCM....hcd`

Firmware blobs normally ship in `linux-firmware`; check the expected file exists, e.g.
`ls /lib/firmware/rtl_bt/ | grep 8761`. A present blob plus no log lines points at the
driver never asking for it — not at a missing file.

## ROM-mode signature (Realtek RTL8761 family, illustrative)

```
HCI Version: 5.1 (0xa)   Revision: 0xb
LMP Version: 5.1 (0xa)   Subversion: 0x8761
Manufacturer: Realtek Semiconductor Corporation (93)
```

`lmp_subver` identifies the family (`0x8761`, `0x8822`, `0x8852`, …). The controller
reports all of this **from ROM**, so a plausible version string proves nothing about
whether firmware loaded.

## btusb table internals

`btusb` uses two tables:

| Table | Role | Generates modaliases |
|---|---|---|
| `btusb_table` | primary USB match, incl. the generic Bluetooth-class rule | yes |
| `blacklist_table` (newer kernels: `quirks_table`) | VID:PID → `driver_info` quirks | **no** |

Consequences:

- `modinfo btusb` listing no vendor aliases is **expected**, not evidence of missing
  vendor support.
- `new_id` accepts `vendor product [class refVendor refProduct]` and can only inherit
  `driver_info` from an entry in the **primary** table. Vendor quirks are not there,
  so there is nothing to reference — `new_id` cannot fix an unsupported dongle.
- Patching the module is the only route short of a kernel that carries the ID.

### Flag values (kernel 6.x / 7.x, `drivers/bluetooth/btusb.c`)

```c
#define BTUSB_INTEL_COMBINED   BIT(8)
#define BTUSB_REALTEK          BIT(16)
#define BTUSB_MEDIATEK         BIT(20)
#define BTUSB_WIDEBAND_SPEECH  BIT(21)
```

These shift between versions. Never hardcode a numeric `driver_info`; always use the
symbolic name and verify it is `#define`d in the source you fetched.

## Kernel source tag pitfall

`uname -r | cut -d- -f1` yields e.g. `7.0.0`, but upstream tags an x.y.0 release as
`vX.Y` — `vX.Y.0` returns HTTP 404. Stable point releases *are* `vX.Y.Z`. Scripts that
derive the tag naively fetch nothing and silently leave stale sources in place.

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' \
  "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/bluetooth/btusb.c?h=v7.0"
```

Fetch `btusb.c` and the vendor helpers (`bt{intel,bcm,rtl,mtk}.{c,h}`) at the **same**
tag — mixing versions breaks the build. `bt-patch-btusb.sh` resolves and verifies the
tag automatically.

Distribution kernels carry extra patches, so upstream sources at the matching tag are
an approximation. It normally builds cleanly; if it does not, use your distribution's
kernel source package instead.

## Verifying a patched module before trusting it

```bash
modinfo ./btusb.ko | grep -E 'vermagic|srcversion'   # vermagic must equal uname -r

# the ID must be present in the built object (little-endian u16 pairs)
python3 - <<'PY'
vid, pid = '2c4e', '0115'          # substitute yours
blob = open('btusb.ko','rb').read()
print(blob.count(bytes.fromhex(vid[2:4]+vid[0:2]+pid[2:4]+pid[0:2])))   # expect >= 1
PY
```

Compare against the distro module — it should contain zero occurrences.

## Disabling an adapter — udev rule details

The strength ordering of the three methods is in `SKILL.md` (Fix B). What follows is the
rule syntax, which is where people go wrong.

Correct rule — `authorized` and `idVendor` both live on the `usb_device`:

```
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="VVVV", ATTR{idProduct}=="PPPP", ATTR{authorized}="0"
```

An unbind rule needs the **interface** and parent attributes instead; plain
`ATTR{idVendor}` will never match there:

```
ACTION=="bind", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_interface", DRIVER=="btusb", \
  ATTRS{idVendor}=="VVVV", ATTRS{idProduct}=="PPPP", \
  RUN+="/bin/sh -c 'echo %k > /sys/bus/usb/drivers/btusb/unbind'"
```

Find the bus id for immediate application without hardcoding it:

```bash
for d in /sys/bus/usb/devices/*; do
  [ -r "$d/idVendor" ] || continue
  [ "$(cat $d/idVendor):$(cat $d/idProduct)" = "VVVV:PPPP" ] && echo "$d"
done
```

## Rollback

```bash
# re-enable a deauthorized device (by USB ID, no hardcoded paths)
sudo scripts/bt-disable-adapter.sh --undo VVVV:PPPP

# remove the DKMS override and restore the distribution's btusb
sudo scripts/bt-patch-btusb.sh --uninstall

# rebind an unbound interface
echo 1-14:1.0 | sudo tee /sys/bus/usb/drivers/btusb/bind    # use your own interface id
```

A reboot reverses `unbind`, `rfkill` and a soft `power off` on its own. It does **not**
reverse a udev rule or a DKMS installation.

## Useful one-liners

```bash
bluetoothctl --timeout 60 scan on             # holds discovery open; expect "Discovery started"
busctl tree org.bluez | grep 'hci0/dev_'      # per-adapter attribution
busctl get-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Discovering
busctl get-property org.bluez /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF org.bluez.Device1 Connected
busctl call org.bluez /org/bluez/hci0 org.bluez.Adapter1 RemoveDevice o \
  /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF       # drop a bond
busctl set-property org.bluez /org/bluez/hci1 org.bluez.Adapter1 Powered b false
pw-cli list-objects Node | grep -i bluez      # PipeWire audio nodes
```

`hciconfig` is deprecated and may not be installed by default on newer distributions —
it usually lives in a `bluez-deprecated` / `bluez-utils-compat` package. It remains the
simplest source of the `acl` counter.
