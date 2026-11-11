#!/bin/bash
set -euo pipefail

ROOT="$(mktemp -d /tmp/termosaic-updater-test.XXXXXX)"
cleanup() {
  chflags -R nouchg "$ROOT" 2>/dev/null || true
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

# A cleanup failure is visible but cannot roll back a partially removed backup.
CLEANUP="$ROOT/cleanup"
mkdir "$CLEANUP"
ditto "$APP" "$CLEANUP/Installed.app"
ditto "$APP" "$CLEANUP/Staged.app"
printf 'retained old backup evidence\n' > "$CLEANUP/Installed.app/undeletable"
chflags uchg "$CLEANUP/Installed.app/undeletable"
if TERMOSAIC_UPDATE_SKIP_LAUNCH=1 "$HELPER" 999999 "$CLEANUP/Staged.app" "$CLEANUP/Installed.app" "$CLEANUP/Backup.app" "$CLEANUP/cleanup.log"; then
  echo "Backup cleanup failure unexpectedly reported success" >&2
  exit 1
fi
codesign --verify --deep --strict "$CLEANUP/Installed.app"
test -f "$CLEANUP/Backup.app/undeletable"
test ! -e "$CLEANUP/Installed.app/undeletable"
test ! -e "$CLEANUP/Staged.app"
grep -q "Update failed: installed application retained; cleanup failed" "$CLEANUP/cleanup.log"
if grep -q "Restored existing application\|Update installed and" "$CLEANUP/cleanup.log"; then
  echo "Cleanup failure must not report success or restore a partial backup" >&2
  exit 1
fi
chflags nouchg "$CLEANUP/Backup.app/undeletable"

# Replace only open's executable in a temporary source copy. This exercises the
# normal recovery path without ever launching the real application.
python3 -I - "$ROOT" "Sources/UpdateInstaller.swift" <<'PY'
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
source = pathlib.Path(sys.argv[2]).read_text()
stub = root / "record-open"
stub.write_text('#!/bin/sh\nprintf \'%s\\n\' "$@" >> "$(dirname "$0")/open-calls"\nexit 0\n')
stub.chmod(0o700)
assert '"/usr/bin/open"' in source
(root / "RecordingInstaller.swift").write_text(source.replace('"/usr/bin/open"', '"' + str(stub) + '"'))
PY
RECORDING_HELPER="$ROOT/RecordingInstaller"
swiftc -parse-as-library "$ROOT/RecordingInstaller.swift" -o "$RECORDING_HELPER"
OPEN_CALLS="$ROOT/open-calls"
for failure in missing-stage existing-backup failed-move; do
  CASE="$ROOT/$failure"
  mkdir "$CASE"
  ditto "$APP" "$CASE/Installed.app"
  BACKUP="$CASE/Backup.app"
  if [ "$failure" != missing-stage ]; then ditto "$APP" "$CASE/Staged.app"; fi
  if [ "$failure" = existing-backup ]; then ditto "$APP" "$BACKUP"; fi
  if [ "$failure" = failed-move ]; then BACKUP="$CASE/missing-parent/Backup.app"; fi
  : > "$OPEN_CALLS"
  if TERMOSAIC_UPDATE_SKIP_LAUNCH=0 "$RECORDING_HELPER" 999999 "$CASE/Staged.app" "$CASE/Installed.app" "$BACKUP" "$CASE/failure.log"; then
    echo "$failure unexpectedly succeeded" >&2
    exit 1
  fi
  codesign --verify --deep --strict "$CASE/Installed.app"
  test "$(< "$OPEN_CALLS")" = "$CASE/Installed.app"
  grep -q "Relaunched existing application" "$CASE/failure.log"
  if [ "$failure" = existing-backup ]; then codesign --verify --deep --strict "$BACKUP"; fi
  : > "$OPEN_CALLS"
  if TERMOSAIC_UPDATE_SKIP_LAUNCH=1 "$RECORDING_HELPER" 999999 "$CASE/Staged.app" "$CASE/Installed.app" "$BACKUP" "$CASE/skipped.log"; then
    echo "$failure unexpectedly succeeded with skip-launch" >&2
    exit 1
  fi
  test ! -s "$OPEN_CALLS"
done
echo "Update installer tests passed (success, rollback, retained backup, cleanup failure, precondition recovery, skip-launch; no real launches)."
