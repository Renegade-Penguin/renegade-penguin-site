#!/usr/bin/env bash
# Derive the plain scrub terms file from the owner's category:term list (issue #9).
#
# Usage: scripts/derive-scrub-terms.sh < list > terms
#   stdin:  lines of employer:TERM, hostname:TERM, serial:TERM, allow:TOKEN and # comments
#   stdout: one plain term per line, no category prefix (the SCRUB_TERMS_FILE format)
#   stderr: per-category counts on success; on failure only a category name or a line NUMBER
#
# Rules:
#   - blank lines, # comment lines and allow: lines are dropped (allow tokens exempt the WordPress
#     converter, not this build gate);
#   - for employer:, hostname: and serial: the prefix is removed and the rest is kept as written
#     (colons, spaces and dots stay); only one trailing CR is trimmed;
#   - a term that starts with PLACEHOLDER (any case) is dropped and counted: it matches nothing real;
#   - FAIL CLOSED (non-zero exit, no output) on an unknown or missing category prefix, an empty term,
#     a NUL byte, or when employer, hostname or serial has no real term left, so the gate can never
#     run with a category that is effectively unchecked.
# No term is ever printed to stderr. On failure stdout stays empty.
set -eu

# A NUL cannot be part of a term; map it to SOH so awk sees it and fails closed on that line.
tr '\000' '\001' | LC_ALL=C awk '
function bad(msg) {
  printf "derive-scrub-terms: %s\n", msg > "/dev/stderr"
  failed = 1
  exit 1
}
{
  line = $0
  sub(/\r$/, "", line)
  if (index(line, "\001") > 0) bad("line " NR ": contains a NUL byte")
  if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/) next
  colon = index(line, ":")
  if (colon == 0) bad("line " NR ": no category prefix")
  category = tolower(substr(line, 1, colon - 1))
  term = substr(line, colon + 1)
  if (category != "employer" && category != "hostname" && category != "serial" && category != "allow") {
    bad("line " NR ": unknown category")
  }
  if (term ~ /^[ \t]*$/) bad("line " NR ": empty term")
  if (category == "allow") next
  if (tolower(substr(term, 1, 11)) == "placeholder") {
    placeholders[category]++
    next
  }
  real[category]++
  n++
  terms[n] = term
}
END {
  if (failed) exit 1
  split("employer hostname serial", cats, " ")
  missing = 0
  for (i = 1; i <= 3; i++) {
    c = cats[i]
    if (real[c] + 0 == 0) {
      printf "derive-scrub-terms: category %s has no real term (placeholders dropped: %d); refusing to continue\n", c, placeholders[c] + 0 > "/dev/stderr"
      missing = 1
    }
  }
  if (missing) exit 1
  for (i = 1; i <= n; i++) print terms[i]
  printf "derive-scrub-terms: employer=%d hostname=%d serial=%d placeholders=%d\n", real["employer"], real["hostname"], real["serial"], placeholders["employer"] + placeholders["hostname"] + placeholders["serial"] > "/dev/stderr"
}
'
