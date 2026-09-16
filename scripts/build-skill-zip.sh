#!/usr/bin/env bash
# build-skill-zip.sh — package the skill for upload to claude.ai (Settings -> Skills).
#
# Produces bluetooth-doctor.zip with SKILL.md at the archive root, which is what the
# uploader expects. Deliberately not committed to git: a checked-in binary drifts from
# the source it was built from. CI builds it on tag and attaches it to the release.
#
# Usage: ./scripts/build-skill-zip.sh [output.zip]

set -euo pipefail
cd "$(dirname "$0")/.."

OUT=${1:-bluetooth-doctor.zip}
NAME=bluetooth-doctor
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/$NAME"
cp SKILL.md reference.md LICENSE "$STAGE/$NAME/"
cp -r scripts "$STAGE/$NAME/"
rm -f "$STAGE/$NAME/scripts/build-skill-zip.sh"     # not useful inside the package
chmod +x "$STAGE/$NAME"/scripts/*.sh

# SKILL.md must exist at the package root for the uploader to recognise it
test -f "$STAGE/$NAME/SKILL.md"
grep -q '^name: bluetooth-doctor$' "$STAGE/$NAME/SKILL.md"

rm -f "$OUT"
( cd "$STAGE" && zip -qr "$OLDPWD/$OUT" "$NAME" )

printf 'built %s (%s bytes)\n' "$OUT" "$(wc -c < "$OUT")"
unzip -l "$OUT" | tail -n +4 | head -12
