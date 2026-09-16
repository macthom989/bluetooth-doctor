# bluetooth-doctor

[![CI](https://github.com/macthom989/bluetooth-doctor/actions/workflows/ci.yml/badge.svg)](https://github.com/macthom989/bluetooth-doctor/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Diagnose and fix Linux Bluetooth adapters that **look** healthy but do not work.

A controller stuck on its ROM firmware still answers HCI commands, reports a plausible
version and vendor, and shows `UP RUNNING` in `hciconfig`. Every surface check passes.
The radio does nothing.

Two signals cannot lie, and both are one command away:

```bash
hciconfig hci0 | grep 'RX bytes'                    # acl:0 = never carried a connection
journalctl -k -b | grep -iE 'RTL:|btintel|btmtk'    # no lines = firmware never loaded
```

A [Claude Code](https://claude.com/claude-code) skill, plus three shell tools that work
standalone.

## Quick start

```bash
git clone https://github.com/macthom989/bluetooth-doctor
cd bluetooth-doctor
./scripts/bt-triage.sh          # read-only, no root
```

It prints a verdict hint per adapter. Then follow the decision table in
[`SKILL.md`](SKILL.md).

## Install

```bash
npx skills add macthom989/bluetooth-doctor -g
```

Installs for Claude Code, Cursor, Codex, Copilot and ~20 other agents via
[`npx skills`](https://github.com/vercel-labs/skills). Drop `-g` to install into the
current project instead.

Or clone directly:

```bash
git clone https://github.com/macthom989/bluetooth-doctor ~/.claude/skills/bluetooth-doctor
```

For **claude.ai** (Settings → Skills), download `bluetooth-doctor.zip` from the
[latest release](https://github.com/macthom989/bluetooth-doctor/releases/latest), or
build it yourself with `./scripts/build-skill-zip.sh`.

Claude loads the skill automatically on "bluetooth not working", "scan finds nothing",
"dongle not working", "pairing fails", "audio stuttering" and similar.

## What it covers

| Symptom | Cause | Fix |
|---|---|---|
| **No `hciN` node exists at all** | driver never bound: module, rfkill, BIOS | K |
| Never worked, scans find nothing, no firmware log | USB ID missing from `btusb` | A |
| Same, but log shows a *failed* firmware load | wrong blob: `rtl8761b`/`bu`, Broadcom `.hcd`, MediaTek | D |
| Device lands on the wrong adapter | two adapters competing for one bond | B |
| Crackles or stutters | CNVi Wi-Fi/Bluetooth RF coexistence | C |
| Works, dies after minutes idle | USB autosuspend | E |
| Dead after suspend/resume | controller does not resume | F |
| Drops instantly, or no A2DP | PipeWire/BlueZ race, missing SPA plugin | G |
| Mic sounds terrible | HFP is narrowband; needs mSBC + `wide-band-speech` | G |
| Re-pair on every boot | bond persistence, dual-boot key rotation | H |
| Gamepad drops in 2–5s | ERTM incompatibility | I |
| Refuses to pair at all | BlueZ `JustWorksRepairing` / `FastConnectable` | J |
| `No default controller available` | symptom of A, D, rfkill or BIOS — not a cause | A/D |

The first two land most "my dongle does not work on Linux" reports and look identical
from outside. `bt-triage.sh` separates them by whether firmware was **never requested**
or **requested and failed**.

**Scope:** the tooling targets **USB adapters driven by `btusb`**. Diagnosis applies to
any controller, but `bt-patch-btusb.sh` and `bt-disable-adapter.sh` do not work on
UART/serial Bluetooth — Raspberry Pi and most ARM boards use `hci_uart`, where there
is no USB ID to patch and no `authorized` attribute. `bt-triage.sh` reports how many
UART controllers it sees so you know when you are in that territory.

## Tools

```bash
./scripts/bt-triage.sh                            # evidence collector, read-only

sudo ./scripts/bt-patch-btusb.sh VVVV:PPPP        # add an unsupported USB ID, install via DKMS
sudo ./scripts/bt-patch-btusb.sh --uninstall

./scripts/bt-disable-adapter.sh --list
sudo ./scripts/bt-disable-adapter.sh VVVV:PPPP    # disable one adapter, persists across boots
sudo ./scripts/bt-disable-adapter.sh --undo VVVV:PPPP
```

`bt-patch-btusb.sh` resolves the right kernel source tag, fetches `btusb.c` and the
vendor helpers, inserts the entry, verifies the ID is in the built object and that
`vermagic` matches, then installs through DKMS. It generates its own `Makefile` and
`dkms.conf` — nothing third-party is cloned.

**It checks whether your kernel already has the ID and stops if so.** Most of these land
upstream eventually — `2c4e:0115`, the dongle this was built for, was merged in kernel
7.2 — and an override you forget about pins `btusb` to an old revision forever. When
your kernel catches up, run `--uninstall`.

`bt-disable-adapter.sh` uses the USB `authorized` attribute, the only lever that
survives reboots, module reloads **and** the desktop Bluetooth toggle. It refuses to
disable your last adapter. Disabling a combo chip's Bluetooth does not affect its Wi-Fi.

## Testing

```bash
./tests/test-detection.sh                                   # no root, no hardware
sudo ./tests/test-integration.sh <DISABLE_ID> [PATCH_ID]    # real hardware
```

The unit tests assert the log-classification patterns against fixtures from real bug
reports — mainly the split between firmware **never requested** (A) and **requested and
failed** (D), which the whole decision table rests on. Suitable for CI.

The integration tests exercise what unit tests cannot: they re-enable and re-disable a
real adapter, check the guard that refuses to disable your last one, then reinstall the
btusb quirk and verify the module in RAM matches the patched module on disk.

⚠️ Integration tests replace the running `btusb` and briefly drop Bluetooth. A failsafe
re-enables `DISABLE_ID` if the run would leave no adapters; recovery commands print on
failure.

Verified on Ubuntu 26.04, kernel 7.0.0-31, BlueZ 5.85, against a Realtek RTL8761BU
dongle (`2c4e:0115`) and an Intel AX211 (`8087:0033`): 24/24 unit, 12/12 integration.

## Requirements

Diagnostics need `bash`; they use `hciconfig`, `busctl`, `journalctl`, `lsusb`, `rfkill`
and `dkms` when present and degrade when not. `hciconfig` is deprecated on newer
distributions — look for `bluez-deprecated` or `bluez-utils-compat`. It is still the
simplest source of the `acl` counter.

Patching also needs a C toolchain, `make`, `dkms`, `curl`, `python3` and this kernel's
headers. The script detects `apt`, `dnf`, `pacman` or `zypper` and prints the matching
install command. With Secure Boot on, DKMS must sign the module and the key must be
enrolled.

## Safety

`bt-triage.sh` is read-only. `bt-disable-adapter.sh` writes one udev rule and refuses to
disable your only adapter. `bt-patch-btusb.sh` prompts before installing, keeps the
distro module, and reverses with `--uninstall`.

Replacing a kernel module affects all Bluetooth on the machine, and a reboot does not
undo a DKMS install. Read [`SKILL.md`](SKILL.md) first.

## Contributing

Useful: firmware log signatures for other vendors, distributions needing different tool
detection, and USB IDs confirmed working with a given quirk flag set.

## License

MIT — see [`LICENSE`](LICENSE). See also [`reference.md`](reference.md) for vendor
firmware signatures, btusb table internals and rollback commands.
