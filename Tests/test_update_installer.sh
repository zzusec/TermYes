#!/bin/bash
set -euo pipefail

ROOT="$(mktemp -d /tmp/termosaic-updater-test.XXXXXX)"
cleanup() {
  find "$ROOT" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

APP="build/TermYes.app"
HELPER="$ROOT/TermYesUpdateInstaller"
swiftc -parse-as-library Sources/UpdateInstaller.swift -o "$HELPER"
ditto "$APP" "$ROOT/Installed.app"
ditto "$APP" "$ROOT/Staged.app"

TERMOSAIC_UPDATE_SKIP_LAUNCH=1 "$HELPER" \
  999999 \
  "$ROOT/Staged.app" \
  "$ROOT/Installed.app" \
  "$ROOT/Backup.app" \
  "$ROOT/update.log"

test -d "$ROOT/Installed.app"
test ! -e "$ROOT/Staged.app"
test ! -e "$ROOT/Backup.app"
codesign --verify --deep --strict "$ROOT/Installed.app"
grep -q "Update installed" "$ROOT/update.log"
# A failed precondition must never remove the application before it was backed up.
if TERMOSAIC_UPDATE_SKIP_LAUNCH=1 "$HELPER" 999999 "$ROOT/Missing.app" "$ROOT/Installed.app" "$ROOT/Backup.app" "$ROOT/missing.log"; then
  echo "Missing staged application unexpectedly succeeded" >&2
  exit 1
fi
test -d "$ROOT/Installed.app"
codesign --verify --deep --strict "$ROOT/Installed.app"
grep -q "Update failed" "$ROOT/missing.log"

# Invalid signatures must roll back; skip-launch applies to the recovery path too.
ditto "$APP" "$ROOT/Invalid.app"
printf '\ninvalid-signature-test\n' >> "$ROOT/Invalid.app/Contents/MacOS/TermYes"
if TERMOSAIC_UPDATE_SKIP_LAUNCH=1 "$HELPER" 999999 "$ROOT/Invalid.app" "$ROOT/Installed.app" "$ROOT/Backup.app" "$ROOT/rollback.log"; then
  echo "Invalid staged signature unexpectedly succeeded" >&2
  exit 1
fi
codesign --verify --deep --strict "$ROOT/Installed.app"
test ! -e "$ROOT/Backup.app"
grep -q "Restored existing application" "$ROOT/rollback.log"

# A previous recovery backup is evidence, not disposable scratch space.
ditto "$APP" "$ROOT/Backup.app"
if TERMOSAIC_UPDATE_SKIP_LAUNCH=1 "$HELPER" 999999 "$ROOT/Invalid.app" "$ROOT/Installed.app" "$ROOT/Backup.app" "$ROOT/existing-backup.log"; then
  echo "Existing backup unexpectedly overwritten" >&2
  exit 1
fi
codesign --verify --deep --strict "$ROOT/Installed.app"
codesign --verify --deep --strict "$ROOT/Backup.app"
echo "Update installer tests passed (success, missing stage, signature rollback, preserved backup; no launches)."
