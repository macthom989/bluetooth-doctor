# bluetooth-doctor

A [Claude Code](https://claude.com/claude-code) skill — plus three standalone shell
tools — for diagnosing Linux Bluetooth adapters that **look** healthy but do not work.

The failure this exists for: a controller stuck on its on-chip ROM firmware still
answers HCI commands, reports a plausible Bluetooth version and vendor name, and shows
`UP RUNNING PSCAN ISCAN` in `hciconfig`. Every surface check passes. The radio does
nothing — scans return zero devices and no connection is ever possible.

The tools here tell you that in about ten seconds instead of an afternoon.

## Quick start

```bash
git clone https://github.com/macthom989/bluetooth-doctor
cd bluetooth-doctor
./scripts/bt-triage.sh            # read-only, no root required
```

The collector prints a verdict hint per adapter. Then follow the decision table in
[`SKILL.md`](SKILL.md).

## Install as a Claude Code skill

Per user, available in every project:

```bash
git clone https://github.com/macthom989/bluetooth-doctor \
  ~/.claude/skills/bluetooth-doctor
```

Per project, committed alongside the code:

```bash
git clone https://github.com/macthom989/bluetooth-doctor \
  .claude/skills/bluetooth-doctor
```

Claude then loads it automatically when a conversation matches the skill description —
"bluetooth not working", "scan finds nothing", "dongle not working", "pairing fails",
"audio stuttering", and similar.

The scripts are ordinary shell tools and work standalone; Claude Code is not required.

## What is here

| File | Purpose |
|---|---|
| [`SKILL.md`](SKILL.md) | triage procedure, decision table, 10 fixes (A–J), verification gates |
| [`reference.md`](reference.md) | firmware log signatures, btusb table internals, flag values, rollback |
| `scripts/bt-triage.sh` | one-pass evidence collector — read-only, no root |
| `scripts/bt-disable-adapter.sh` | persistently disable one adapter by USB ID |
| `scripts/bt-patch-btusb.sh` | add an unsupported USB ID to `btusb`, install via DKMS |
| `tests/test-detection.sh` | 24 assertions on the log-classification patterns; no hardware needed |
| `tests/test-integration.sh` | 12 assertions exercising both privileged install paths on real hardware |

## What it covers

| Symptom | Cause it identifies | Fix |
|---|---|---|
| Adapter present, scans find nothing, never worked | USB ID missing from `btusb`, no vendor firmware | A |
| Same, but log shows a *failed* firmware load | wrong/missing blob: `rtl8761b` vs `bu`, Broadcom `.hcd`, MediaTek | D |
| Device keeps attaching to the wrong adapter | two adapters competing for one bond | B |
| Audio crackles or stutters | CNVi Wi-Fi/Bluetooth RF coexistence | C |
| Works, then drops after minutes idle | USB autosuspend | E |
| Works until suspend, dead after resume | controller does not resume; needs module reload | F |
| Connects then disconnects instantly, or no A2DP | PipeWire/BlueZ race, missing SPA plugin | G |
| Headset mic sounds terrible | HFP is narrowband by design; needs mSBC + `wide-band-speech` | G |
| Must re-pair on every boot | bond persistence, dual-boot key rotation | H |
| Gamepad pairs then drops in 2–5s | ERTM incompatibility | I |
| Device refuses to pair at all | BlueZ needs `JustWorksRepairing` / `FastConnectable` | J |
| `No default controller available` | symptom of A, D, rfkill, or BIOS — not a cause | A/D |

The first two are where most "my dongle does not work on Linux" reports land, and they
look identical from the outside — `bt-triage.sh` separates them by whether firmware was
**never requested** or **requested and failed**.

## The two signals that matter

Everything else can lie. These do not:

```bash
hciconfig hci0 | grep 'RX bytes'                    # acl:0 = never carried a connection
journalctl -k -b | grep -iE 'RTL:|btintel|btmtk'    # no lines = firmware never loaded
```

An adapter reporting `acl:0` long after boot has never completed a single connection,
no matter how healthy it appears.

## Fixing an unsupported USB dongle

Many cheap Realtek dongles ship with a USB ID that is not in `btusb`'s quirks table.
The kernel then binds them through the generic Bluetooth-class rule with
`driver_info = 0`, the vendor flag is never set, the vendor module never runs, and the
firmware is never downloaded.

```bash
sudo ./scripts/bt-patch-btusb.sh 2c4e:0115        # your VID:PID from `lsusb`
```

The script resolves the correct kernel source tag, fetches `btusb.c` and the vendor
helpers, inserts the entry, builds, verifies the ID is present in the resulting object
and that `vermagic` matches, then installs through DKMS so it survives kernel upgrades.
It generates its own `Makefile` and `dkms.conf` — no third-party repository is cloned.

```bash
sudo ./scripts/bt-patch-btusb.sh VVVV:PPPP --build-only   # build and verify only
sudo ./scripts/bt-patch-btusb.sh --uninstall              # full rollback
```

Notes:
- `new_id` **cannot** substitute for this. It can only inherit `driver_info` from
  `btusb`'s primary table, and vendor quirks live in a secondary table that generates
  no modaliases. `reference.md` explains why.
- With Secure Boot enabled, DKMS must sign the module and the key must be enrolled, or
  the rebuilt `btusb` will not load. The script warns.
- Check whether your kernel already carries the ID before installing an override — many
  of these IDs are merged upstream eventually.

## Stopping one adapter from stealing a device

A bonded device reconnects to whichever adapter holds its bond, and desktop
environments re-pair it automatically.

```bash
./scripts/bt-disable-adapter.sh --list              # no root needed
sudo ./scripts/bt-disable-adapter.sh 8087:0033      # disable now and at every boot
sudo ./scripts/bt-disable-adapter.sh --undo 8087:0033
```

Uses the USB core `authorized` attribute, which is the only lever of the three that
holds:

| Method | Survives reboot | Survives module reload | Survives desktop BT toggle |
|---|---|---|---|
| `ATTR{authorized}="0"` | ✅ | ✅ | ✅ |
| driver `unbind` | ❌ | ❌ udev rebinds | ✅ |
| `rfkill block` | usually | ✅ | ❌ GNOME resets it |

Disabling a combo chip's Bluetooth does **not** affect its Wi-Fi — Wi-Fi is a separate
PCI device. The script refuses to disable the last remaining adapter.

## Requirements

Diagnostics need only `bash`, and use `hciconfig`, `busctl`, `journalctl`, `lsusb`,
`rfkill` and `dkms` when present, degrading gracefully when they are not.

Patching additionally needs a C toolchain, `make`, `dkms`, `curl`, `python3`, and this
kernel's headers. The script detects `apt`, `dnf`, `pacman` or `zypper` and prints the
matching install command.

`hciconfig` is deprecated and may not be installed by default on newer distributions —
look for a `bluez-deprecated` or `bluez-utils-compat` package. It remains the simplest
source of the `acl` counter.

Tested on Ubuntu with kernel 7.0 and BlueZ 5.85, against Realtek RTL8761BU and Intel
AX211 hardware. The logic is vendor-agnostic; reports from other combinations welcome.

## Testing

```bash
./tests/test-detection.sh                                   # no root, no hardware
sudo ./tests/test-integration.sh <DISABLE_ID> [PATCH_ID]    # real hardware
```

`test-detection.sh` asserts the log-classification patterns against fixtures taken from
real bug reports — in particular the split between firmware **never requested** (Fix A)
and **requested and failed** (Fix D), which is the distinction the whole decision table
rests on. It runs anywhere and is suitable for CI.

`test-integration.sh` exercises what unit tests cannot: it re-enables and re-disables a
real adapter through `bt-disable-adapter.sh`, checks the guard that refuses to disable
your last adapter, then removes any existing btusb DKMS package and reinstalls it with
`bt-patch-btusb.sh`, verifying that the module in RAM matches the patched module on disk
and that vendor firmware still loads. A failsafe re-enables `DISABLE_ID` if the run ends
with no Bluetooth adapters at all.

⚠️ It replaces the running `btusb` module and briefly drops Bluetooth connections. Run it
on a machine you can afford to disturb. Recovery commands are printed on failure.

Verified on Ubuntu 26.04, kernel 7.0.0-31, BlueZ 5.85, against a Realtek RTL8761BU
dongle (`2c4e:0115`) and an Intel AX211 (`8087:0033`): 24/24 unit, 12/12 integration.

## Safety

- `bt-triage.sh` is strictly read-only.
- `bt-disable-adapter.sh` writes one udev rule and refuses to disable your only adapter.
- `bt-patch-btusb.sh` prompts before installing (`--yes` to skip), keeps the distro
  module in place, and reverses cleanly with `--uninstall`.

Replacing a kernel module affects all Bluetooth on the machine. Read
[`SKILL.md`](SKILL.md) before running the patch tool, and know that a reboot alone will
not undo a DKMS install.

## Contributing

Useful additions: firmware log signatures for other vendors, distributions where tool
detection needs adjusting, and USB IDs confirmed working with a given quirk flag set.

## License

MIT — see [`LICENSE`](LICENSE).
