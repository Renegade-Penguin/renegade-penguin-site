#!/usr/bin/env bash
# Sourced by the fake executables. Records a leak (and never prints the marker)
# if this process's environment, or any file under the script's TMPDIR,
# contains a marker listed in $FAKE_DIR/markers.
fake_leakcheck() {
  local who=$1
  if tr '\0' '\n' </proc/$$/environ | grep -qFf "$FAKE_DIR/markers"; then
    printf '%s: marker in environment\n' "$who" >>"$FAKE_DIR/leak.log"
  fi
  if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && grep -rqFf "$FAKE_DIR/markers" "$TMPDIR" 2>/dev/null; then
    printf '%s: marker in a file under TMPDIR\n' "$who" >>"$FAKE_DIR/leak.log"
  fi
}
