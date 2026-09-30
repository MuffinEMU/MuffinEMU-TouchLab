#!/bin/bash
# Vendors this package into a MuffinEMU checkout as a local Swift package.
#
#   tools/export-to-muffinemu.sh /path/to/MuffinEMU
#
# Writes <MuffinEMU>/src/ios/Packages/MuffinTouchLab/ (replacing it wholesale) with the
# package manifest, the four source targets and the licence, plus VENDORED.md recording
# exactly which TouchLab commit it came from. Refuses to export uncommitted or unpushed
# work, so the recorded commit always exists on GitHub.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
DEST_ROOT="${1:?usage: $0 /path/to/MuffinEMU}"
DEST="$DEST_ROOT/src/ios/Packages/MuffinTouchLab"

[ -f "$DEST_ROOT/src/ios/project.yml" ] || { echo "error: $DEST_ROOT does not look like MuffinEMU (no src/ios/project.yml)"; exit 1; }

cd "$SRC"
if [ -n "$(git status --porcelain -- Package.swift Sources LICENSE.txt)" ]; then
  echo "error: TouchLab has uncommitted changes in Package.swift/Sources - commit and push first"; exit 1
fi
git fetch -q origin
if ! git merge-base --is-ancestor HEAD origin/main; then
  echo "error: TouchLab HEAD is not on origin/main - push first"; exit 1
fi
SHA=$(git rev-parse HEAD)

swift run -q touchlab-check >/dev/null || { echo "error: touchlab-check fails - not exporting"; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST"
cp Package.swift LICENSE.txt "$DEST/"
cp -R Sources "$DEST/Sources"
find "$DEST" -name .DS_Store -delete

cat > "$DEST/VENDORED.md" <<MD
# MuffinTouchLab (vendored)

The on-screen control schemes offered under Settings > On-screen Controls > Control style
(Zone, Float, Adaptive, Frame). Vendored from MuffinEMU-TouchLab at commit
\`$SHA\` by \`tools/export-to-muffinemu.sh\`.

Do not edit these files here. Change them in MuffinEMU-TouchLab, run its checks, and
re-export - otherwise the next export silently overwrites the change.

Checks: \`swift run --package-path src/ios/Packages/MuffinTouchLab touchlab-check\`
MD

echo "exported TouchLab $SHA -> $DEST"
