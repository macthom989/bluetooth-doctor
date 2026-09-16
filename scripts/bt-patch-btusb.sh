#!/usr/bin/env bash
# bt-patch-btusb.sh — add an unsupported USB Bluetooth ID to btusb and install the
# rebuilt module via DKMS, so it survives kernel upgrades.
#
# For adapters whose VID:PID is missing from btusb's quirks table. Such a device binds
# only through btusb's generic Bluetooth-class rule with driver_info = 0, so the
# vendor flag (BTUSB_REALTEK etc.) is never set, the vendor module never runs, the
# firmware is never downloaded, and the controller stays on its ROM image: it looks
# UP RUNNING and reports a plausible version, but the radio does nothing.
#
# Self-contained — fetches kernel sources at the matching tag and generates its own
# Makefile and dkms.conf. No third-party repository required.
#
# Usage:
#   sudo ./bt-patch-btusb.sh VVVV:PPPP [options]
#
# Options:
#   --quirks "A|B"   driver_info flags (default: BTUSB_REALTEK|BTUSB_WIDEBAND_SPEECH)
#   --tag vX.Y       override the kernel source tag (default: derived from uname -r)
#   --workdir DIR    build directory (default: a temporary directory)
#   --build-only     build and verify, do not install
#   --uninstall      remove the DKMS module, restore the distro's btusb
#   --yes            do not prompt
#
# Examples:
#   sudo ./bt-patch-btusb.sh 2c4e:0115
#   sudo ./bt-patch-btusb.sh 0bda:8771 --quirks "BTUSB_REALTEK"
#   sudo ./bt-patch-btusb.sh --uninstall

set -euo pipefail

PKG=btusb-quirk
PKGVER=1.0
QUIRKS="BTUSB_REALTEK|BTUSB_WIDEBAND_SPEECH"
TAG=""; WORKDIR=""; BUILD_ONLY=0; UNINSTALL=0; ASSUME_YES=0; USBID=""
KREL=$(uname -r)
BASEURL="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/bluetooth"
VENDOR_SRC="btintel btbcm btrtl btmtk"

die()  { printf 'error: %s\n' "$1" >&2; exit 1; }
step() { printf '\n==> %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)   usage 0 ;;
    --quirks)    QUIRKS=${2:?}; shift 2 ;;
    --tag)       TAG=${2:?}; shift 2 ;;
    --workdir)   WORKDIR=${2:?}; shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    -*)          die "unknown option: $1" ;;
    *)           USBID=$1; shift ;;
  esac
done

# ------------------------------------------------------------------ uninstall

if [ "$UNINSTALL" = 1 ]; then
  [ "$(id -u)" -eq 0 ] || die "must run as root"
  step "Removing DKMS module $PKG/$PKGVER"
  have dkms && dkms remove "$PKG/$PKGVER" --all 2>/dev/null || info "not registered with dkms"
  rm -rf "/usr/src/$PKG-$PKGVER"
  find /lib/modules -path '*/updates/dkms/btusb.ko*' -delete 2>/dev/null || true
  depmod -a
  if have systemctl; then systemctl stop bluetooth 2>/dev/null || true; fi
  modprobe -r btusb 2>/dev/null || true
  modprobe btusb 2>/dev/null || true
  if have systemctl; then systemctl start bluetooth 2>/dev/null || true; fi
  info "restored: $(modinfo btusb 2>/dev/null | awk '/^filename/{print $2}')"
  exit 0
fi

[ -n "$USBID" ] || usage 1
case "$USBID" in
  [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
  *) die "expected USB ID as VVVV:PPPP (e.g. 2c4e:0115), got '$USBID'" ;;
esac
VID=$(printf '%s' "${USBID%%:*}" | tr 'A-Z' 'a-z')
PID=$(printf '%s' "${USBID##*:}" | tr 'A-Z' 'a-z')

[ "$(id -u)" -eq 0 ] || [ "$BUILD_ONLY" = 1 ] || die "must run as root (or pass --build-only)"

# ------------------------------------------------------- prerequisite checks

step "Checking prerequisites"

for t in curl make gcc python3; do
  have "$t" || MISSING="${MISSING:-} $t"
done
[ "$BUILD_ONLY" = 1 ] || have dkms || MISSING="${MISSING:-} dkms"

KBUILD=/lib/modules/$KREL/build
[ -d "$KBUILD" ] || MISSING="${MISSING:-} kernel-headers-for-$KREL"

if [ -n "${MISSING:-}" ]; then
  printf 'error: missing prerequisites:%s\n\n' "$MISSING" >&2
  printf 'Install them with your distribution'"'"'s package manager, for example:\n' >&2
  if   have apt;    then printf '  sudo apt install -y build-essential dkms curl python3 linux-headers-$(uname -r)\n' >&2
  elif have dnf;    then printf '  sudo dnf install -y @development-tools dkms curl python3 kernel-devel-$(uname -r)\n' >&2
  elif have pacman; then printf '  sudo pacman -S --needed base-devel dkms curl python3 linux-headers\n' >&2
  elif have zypper; then printf '  sudo zypper install -y -t pattern devel_basis && sudo zypper install -y dkms curl python3 kernel-devel\n' >&2
  else                  printf '  (install: a C toolchain, make, dkms, curl, python3, and this kernel'"'"'s headers)\n' >&2
  fi
  exit 1
fi
info "toolchain OK, headers at $KBUILD"

# Secure Boot would silently reject an unsigned out-of-tree module.
SB=""
if have mokutil; then SB=$(mokutil --sb-state 2>/dev/null | head -1 || true); fi
case "$SB" in
  *enabled*) printf '\nWARNING: Secure Boot appears ENABLED (%s).\n' "$SB"
             printf 'DKMS must sign the module and the key must be enrolled (mokutil --import),\n'
             printf 'otherwise the rebuilt btusb will not load.\n' ;;
  *)         [ -n "$SB" ] && info "Secure Boot: $SB" ;;
esac

# ------------------------------------------------------ resolve source tag

step "Resolving kernel source tag"

# uname -r gives e.g. 7.0.0-31-generic -> semver 7.0.0. Upstream tags an x.y.0 release
# as vX.Y (no trailing .0), so vX.Y.0 would 404. Try the plausible forms in order.
SEMVER=${KREL%%-*}
IFS=. read -r KMAJ KMIN KPAT <<EOF
$SEMVER
EOF
KPAT=${KPAT:-0}

if [ -n "$TAG" ]; then
  CANDIDATES="$TAG"
elif [ "$KPAT" = "0" ]; then
  CANDIDATES="v$KMAJ.$KMIN v$KMAJ.$KMIN.0"
else
  CANDIDATES="v$KMAJ.$KMIN.$KPAT v$KMAJ.$KMIN"
fi

RESOLVED=""
for t in $CANDIDATES; do
  code=$(curl -fsS -o /dev/null -w '%{http_code}' "$BASEURL/btusb.c?h=$t" 2>/dev/null || echo 000)
  info "$t -> HTTP $code"
  [ "$code" = "200" ] && { RESOLVED=$t; break; }
done
[ -n "$RESOLVED" ] || die "no usable kernel tag found (tried: $CANDIDATES). Pass --tag explicitly."
info "using $RESOLVED"

# ------------------------------------------------------------- fetch sources

if [ -z "$WORKDIR" ]; then
  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/bt-patch-btusb.XXXXXX")
  CLEANUP=$WORKDIR
fi
mkdir -p "$WORKDIR"
cd "$WORKDIR"
step "Fetching kernel Bluetooth sources at $RESOLVED into $WORKDIR"

FILES="btusb.c"
for v in $VENDOR_SRC; do FILES="$FILES $v.c $v.h"; done
for f in $FILES; do
  if curl -fsS -o "$f" "$BASEURL/$f?h=$RESOLVED"; then
    info "$(printf '%-12s %8s bytes' "$f" "$(wc -c < "$f")")"
  else
    # Not every vendor helper exists in every kernel version; btusb.c is mandatory.
    [ "$f" = "btusb.c" ] && die "could not fetch btusb.c at $RESOLVED"
    info "$(printf '%-12s skipped (absent at this tag)' "$f")"
  fi
done

# --------------------------------------------------------------- patch source

step "Adding $VID:$PID to the btusb quirks table"

rc=0
# `set -e` would abort on a non-zero exit before we could interpret it, so guard the call.
# Exit 3 from the patcher means the ID is already present in this kernel.
python3 - "$VID" "$PID" "$QUIRKS" <<'PY' || rc=$?
import re, sys
vid, pid, quirks = sys.argv[1], sys.argv[2], sys.argv[3]
path = 'btusb.c'
src = open(path, encoding='utf-8', errors='surrogateescape').read()

if f'0x{vid}' in src and f'0x{pid}' in src:
    for line in src.splitlines():
        if f'0x{vid}' in line and f'0x{pid}' in line:
            print(f'    already present: {line.strip()}')
            sys.exit(3)

# The vendor quirks live in a secondary table, named blacklist_table historically and
# quirks_table in newer kernels. Insert before its terminating empty entry.
name = next((n for n in ('blacklist_table', 'quirks_table')
             if re.search(rf'usb_device_id\s+{n}\s*\[\s*\]\s*=\s*{{', src)), None)
if not name:
    sys.exit('could not locate the btusb quirks table in btusb.c')

start = re.search(rf'usb_device_id\s+{name}\s*\[\s*\]\s*=\s*{{', src).end()
term = re.search(r'\n\t\{\s*\}\s*/\*\s*Terminating entry\s*\*/', src[start:])
if not term:
    sys.exit(f'could not locate the terminator of {name}')
pos = start + term.start()

flags = ' |\n\t\t\t\t\t\t     '.join(q.strip() for q in quirks.split('|'))
entry = (f'\n\t/* Added by bt-patch-btusb.sh */\n'
         f'\t{{ USB_DEVICE(0x{vid}, 0x{pid}), .driver_info = {flags} }},\n')

open(path, 'w', encoding='utf-8', errors='surrogateescape').write(src[:pos] + entry + src[pos:])
print(f'    inserted into {name}: USB_DEVICE(0x{vid}, 0x{pid}) = {quirks}')
PY
if [ "$rc" = 3 ]; then
  info "nothing to do — this kernel already supports the device"
  info "no override needed; if one is installed, remove it with --uninstall"
  exit 0
fi
[ "$rc" = 0 ] || die "patching failed"

for q in $(printf '%s' "$QUIRKS" | tr '|' ' '); do
  grep -q "define $q" btusb.c || die "flag $q is not defined in this kernel's btusb.c"
done
info "quirk flags verified against this kernel's btusb.c"

# -------------------------------------------------------------- build module

step "Building btusb.ko for $KREL"

cat > Makefile <<'EOF'
obj-m := btusb.o
KDIR  := /lib/modules/$(shell uname -r)/build
PWD   := $(shell pwd)
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
EOF

make -s 2>&1 | sed 's/^/    /' || die "build failed"
[ -f btusb.ko ] || die "build produced no btusb.ko"

VM=$(modinfo ./btusb.ko | awk '/^vermagic/{print $2}')
[ "$VM" = "$KREL" ] || die "vermagic mismatch: built $VM, running $KREL"
info "built OK, vermagic $VM"

python3 - "$VID" "$PID" <<'PY'
import sys
vid, pid = sys.argv[1], sys.argv[2]
blob = open('btusb.ko','rb').read()
# usb_device_id stores idVendor/idProduct as little-endian u16, adjacent.
needle = bytes.fromhex(vid[2:4]+vid[0:2]+pid[2:4]+pid[0:2])
n = blob.count(needle)
print(f'    device ID present in built object: {n} occurrence(s)')
sys.exit(0 if n else 'ID not found in the built module — patch did not take effect')
PY

if [ "$BUILD_ONLY" = 1 ]; then
  step "Build-only mode"
  info "module at $WORKDIR/btusb.ko (not installed)"
  exit 0
fi

# --------------------------------------------------------------- dkms install

if [ "$ASSUME_YES" != 1 ]; then
  printf '\nInstall this module via DKMS (replaces the distro btusb for all kernels)? [y/N] '
  read -r ans; case "$ans" in y|Y|yes) ;; *) die "aborted by user";; esac
fi

step "Installing via DKMS as $PKG/$PKGVER"

SRC=/usr/src/$PKG-$PKGVER
rm -rf "$SRC"; mkdir -p "$SRC"
cp -a ./*.c ./*.h Makefile "$SRC"/ 2>/dev/null || true

cat > "$SRC/dkms.conf" <<EOF
PACKAGE_NAME="$PKG"
PACKAGE_VERSION="$PKGVER"
BUILT_MODULE_NAME[0]="btusb"
DEST_MODULE_NAME[0]="btusb"
DEST_MODULE_LOCATION[0]="/kernel/drivers/bluetooth"
MAKE[0]="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"
CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"
AUTOINSTALL="yes"
EOF

dkms remove "$PKG/$PKGVER" --all 2>/dev/null || true
dkms add    "$PKG/$PKGVER"
dkms build  "$PKG/$PKGVER"
dkms install "$PKG/$PKGVER" --force
depmod -a

# --------------------------------------------------------- reload and verify

step "Reloading btusb"
# depmod ordering means modules.dep now points at updates/dkms, but a module already
# resident in RAM is not replaced until it is unloaded. udev can also re-load the
# stock module during install, so an explicit reload is required, not optional.
have systemctl && systemctl stop bluetooth 2>/dev/null || true
modprobe -r btusb 2>/dev/null || info "could not unload btusb (in use?) — a reboot will apply it"
modprobe btusb 2>/dev/null || true
have systemctl && systemctl start bluetooth 2>/dev/null || true

RAM=$(cat /sys/module/btusb/srcversion 2>/dev/null || echo "not loaded")
DISK=$(modinfo btusb 2>/dev/null | awk '/^srcversion/{print $2}')
FILE=$(modinfo btusb 2>/dev/null | awk '/^filename/{print $2}')
printf '\n    RAM  : %s\n    disk : %s\n    file : %s\n' "$RAM" "$DISK" "$FILE"

if [ "$RAM" = "$DISK" ]; then
  printf '\n    module in RAM matches the patched module on disk\n'
else
  printf '\n    RAM and disk differ — reboot, or stop bluetooth and reload btusb manually\n'
fi

cat <<EOF

Verify the fix took effect:

  journalctl -k -b | grep -iE 'RTL:|btintel|btmtk'   # vendor firmware must load now
  hciconfig <hciN> | grep 'RX bytes'                 # acl must climb above 0 once connected
  bluetoothctl --timeout 30 scan on                  # must actually find devices

Roll back with:  $(basename "$0") --uninstall

After a kernel upgrade DKMS rebuilds these sources automatically. If that build ever
fails against newer headers, re-run this script so it fetches sources at the new tag.
EOF

[ -n "${CLEANUP:-}" ] && rm -rf "$CLEANUP"
exit 0
