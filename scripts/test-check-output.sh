#!/usr/bin/env bash
# Fixture-driven test for scripts/check-output.sh.
#
# Fixtures are tiny hand-made output trees under scripts/fixtures/:
#   clean/          a passing production tree
#   clean-staging/  a passing staging tree
#   bad-*/          an OVERLAY: only the files that differ. The test copies the
#                   chosen base tree, lays the overlay on top, and runs the checker.
# Each bad fixture must (1) fail with the check enabled, with a message naming the
# check, and (2) pass with SKIP_<NAME>=1, which proves it bites exactly that check.
# The dash fixtures are built at run time with chr() so no dash is committed.
# A final step builds the real site in production and staging and runs the checker.
# Case failures are collected and reported together; the exit code is non-zero if any.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK="scripts/check-output.sh"
FIX="scripts/fixtures"
HUGO="${HUGO:-hugo}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
soft() {
  echo "FAIL: $*" >&2
  FAILS=$((FAILS + 1))
}

[ -x "$CHECK" ] || fail "$CHECK missing or not executable"

TERMS="$WORK/terms.txt"
printf '%s\n' 'zzbannedtermzz' >"$TERMS"

stage() { # <base> [overlay-dir] -> echoes a fresh tree path
  # stage runs in a command substitution, so a counter would not persist; use mktemp.
  local d
  d="$(mktemp -d "$WORK/tree.XXXXXX")"
  cp -R "$FIX/$1/." "$d/"
  if [ -n "${2:-}" ]; then cp -R "$2/." "$d/"; fi
  echo "$d"
}

run_check() { # <dir> <env> [VAR=1 ...]; sets RC and OUT. Later VAR=... wins.
  local dir="$1" envn="$2"
  shift 2
  set +e
  OUT="$(env EXPECT_ENV="$envn" SCRUB_TERMS_FILE="$TERMS" "$@" "$CHECK" "$dir" 2>&1)"
  RC=$?
  set -e
}

expect_pass() { # <label> <tree> <env>
  run_check "$2" "$3"
  if [ "$RC" != "0" ]; then
    soft "$1: expected pass, got exit $RC: $OUT"
    return 0
  fi
  echo "ok: $1 passes"
}

bite() { # <label> <tree> <env> <check-name> <SKIP var>
  local label="$1" tree="$2" envn="$3" name="$4" skip="$5"
  run_check "$tree" "$envn"
  if [ "$RC" = "0" ]; then
    soft "$label: expected failure, got exit 0"
    return 0
  fi
  if ! grep -q "^FAIL $name:" <<<"$OUT"; then
    soft "$label: no 'FAIL $name:' line in: $OUT"
    return 0
  fi
  run_check "$tree" "$envn" "$skip=1"
  if [ "$RC" != "0" ]; then
    soft "$label: with $skip=1 expected pass, got exit $RC: $OUT"
    return 0
  fi
  echo "ok: $label fails on $name and passes with $skip=1"
}

# bite_terms <label> <tree> <termsfile|UNSET> <message fragment>
bite_terms() {
  local label="$1" tree="$2" tf="$3" frag="$4"
  set +e
  if [ "$tf" = UNSET ]; then
    OUT="$(env -u SCRUB_TERMS_FILE EXPECT_ENV=production "$CHECK" "$tree" 2>&1)"
  else
    OUT="$(env SCRUB_TERMS_FILE="$tf" EXPECT_ENV=production "$CHECK" "$tree" 2>&1)"
  fi
  RC=$?
  set -e
  if [ "$RC" = "0" ]; then
    soft "$label: expected failure, got exit 0"
    return 0
  fi
  if ! grep -q "^FAIL scrub_terms: .*$frag" <<<"$OUT"; then
    soft "$label: no scrub_terms line with '$frag' in: $OUT"
    return 0
  fi
  set +e
  if [ "$tf" = UNSET ]; then
    OUT="$(env -u SCRUB_TERMS_FILE SKIP_SCRUB_TERMS=1 EXPECT_ENV=production "$CHECK" "$tree" 2>&1)"
  else
    OUT="$(env SCRUB_TERMS_FILE="$tf" SKIP_SCRUB_TERMS=1 EXPECT_ENV=production "$CHECK" "$tree" 2>&1)"
  fi
  RC=$?
  set -e
  if [ "$RC" != "0" ]; then
    soft "$label: with SKIP_SCRUB_TERMS=1 expected pass, got exit $RC: $OUT"
    return 0
  fi
  echo "ok: $label fails on scrub_terms and passes with SKIP_SCRUB_TERMS=1"
}

expect_pass "clean (production)" "$(stage clean)" production
expect_pass "clean-staging (staging)" "$(stage clean-staging)" staging

run_check "$(stage clean)" bogus
if [ "$RC" = "0" ]; then soft "bogus EXPECT_ENV must fail"; else echo "ok: bogus EXPECT_ENV rejected"; fi

# b <label> <base> <overlay> <env> <check> <skip>
b() { bite "$1" "$(stage "$2" "$FIX/$3")" "$4" "$5" "$6"; }

# Structural checks (HTML parser)
b "script tag" clean bad-no-script production no_script SKIP_NO_SCRIPT
b "uppercase SCRIPT" clean bad-script-upper production no_script SKIP_NO_SCRIPT
b "script split by newline" clean bad-script-split production no_script SKIP_NO_SCRIPT
b "inline handler" clean bad-inline-handler production inline_handler SKIP_INLINE_HANDLER
b "handler after a > in an attribute value" clean bad-handler-gt production inline_handler SKIP_INLINE_HANDLER
b "handler on its own line" clean bad-handler-newline production inline_handler SKIP_INLINE_HANDLER
b "external img src" clean bad-external-img production external_host SKIP_EXTERNAL_HOST
b "src with spaces around =" clean bad-src-spaces production external_host SKIP_EXTERNAL_HOST
b "second srcset candidate" clean bad-srcset production external_host SKIP_EXTERNAL_HOST
b "srcset candidate with a data: scheme" clean bad-srcset-data production unsafe_scheme SKIP_UNSAFE_SCHEME
b "srcset candidate with a javascript: scheme" clean bad-srcset-js production unsafe_scheme SKIP_UNSAFE_SCHEME
b "srcset candidate with an obfuscated javascript: scheme" clean bad-srcset-js-obfuscated production unsafe_scheme SKIP_UNSAFE_SCHEME
b "external link tag" clean bad-external-linktag production external_host SKIP_EXTERNAL_HOST
b "external css import" clean bad-external-css production external_host SKIP_EXTERNAL_HOST
b "style element url( )" clean bad-style-element production external_host SKIP_EXTERNAL_HOST
b "style attribute url( )" clean bad-style-attr production external_host SKIP_EXTERNAL_HOST
b "style element @import" clean bad-style-import production external_host SKIP_EXTERNAL_HOST
b "video src" clean bad-iframe production external_host SKIP_EXTERNAL_HOST
b "form action" clean bad-form-action production external_host SKIP_EXTERNAL_HOST
b "anchor without noopener" clean bad-external-anchor production external_host SKIP_EXTERNAL_HOST
b "anchor split across lines" clean bad-anchor-split production external_host SKIP_EXTERNAL_HOST

# Denylist: every file, case-insensitive
b "term in body" clean bad-scrub-body production scrub_terms SKIP_SCRUB_TERMS
b "term in title" clean bad-scrub-title production scrub_terms SKIP_SCRUB_TERMS
b "term in alt" clean bad-scrub-alt production scrub_terms SKIP_SCRUB_TERMS
b "term in sitemap.xml" clean bad-scrub-sitemap production scrub_terms SKIP_SCRUB_TERMS
b "mixed-case term in an extensionless file" clean bad-scrub-extless production scrub_terms SKIP_SCRUB_TERMS

# Denylist file handling (required, comments and blanks stripped, never empty)
CLEANTREE="$(stage clean)"
BADTREE="$(stage clean "$FIX/bad-scrub-body")"
: >"$WORK/empty.txt"
printf '%s\n' '# only a comment' '' '   ' >"$WORK/comments.txt"
printf '%s\n' '' '# a comment' '' 'zzbannedtermzz' '' >"$WORK/mixed.txt"
bite_terms "SCRUB_TERMS_FILE unset" "$CLEANTREE" UNSET "SCRUB_TERMS_FILE required"
bite_terms "SCRUB_TERMS_FILE unreadable" "$CLEANTREE" "$WORK/does-not-exist" "SCRUB_TERMS_FILE required"
bite_terms "empty terms file" "$CLEANTREE" "$WORK/empty.txt" "no patterns"
bite_terms "comments-only terms file" "$CLEANTREE" "$WORK/comments.txt" "no patterns"
bite_terms "blank line plus one pattern (bad tree)" "$BADTREE" "$WORK/mixed.txt" "denylisted"
set +e
OUT="$(env SCRUB_TERMS_FILE="$WORK/mixed.txt" EXPECT_ENV=production "$CHECK" "$CLEANTREE" 2>&1)"
RC=$?
set -e
if [ "$RC" != "0" ]; then soft "blank line plus pattern must pass a clean tree: $OUT"; else echo "ok: blank line plus pattern passes a clean tree"; fi

# Indexing signals
b "noindex in production" clean bad-noindex-production production noindex SKIP_NOINDEX
b "staging missing noindex" clean-staging bad-staging-no-noindex staging noindex SKIP_NOINDEX
b "noindex only in prose (staging)" clean-staging bad-staging-noindex-prose staging noindex SKIP_NOINDEX
b "staging robots allows" clean-staging bad-staging-no-disallow staging robots SKIP_ROBOTS
b "staging robots no User-agent" clean-staging bad-robots-no-useragent staging robots SKIP_ROBOTS
b "staging robots Googlebot only" clean-staging bad-robots-googlebot staging robots SKIP_ROBOTS
b "staging robots Disallow /private" clean-staging bad-robots-private staging robots SKIP_ROBOTS
b "production robots blocks everything" clean bad-robots-prod-blocks production robots SKIP_ROBOTS
for envn in staging production; do
  base=clean
  [ "$envn" = staging ] && base=clean-staging
  t="$(stage "$base")"
  rm "$t/robots.txt"
  bite "robots.txt missing ($envn)" "$t" "$envn" robots SKIP_ROBOTS
done

# Headers
b "missing CSP" clean bad-csp production csp SKIP_CSP
b "script-src * unsafe-inline" clean bad-csp-script-wild production csp SKIP_CSP
b "default-src * alone" clean bad-csp-default-wild production csp SKIP_CSP
b "no frame-ancestors" clean bad-csp-no-frame-ancestors production csp SKIP_CSP
b "no base-uri" clean bad-csp-no-base-uri production csp SKIP_CSP
b "no form-action" clean bad-csp-no-form-action production csp SKIP_CSP
b "style-src unsafe-inline" clean bad-csp-unsafe-inline production csp SKIP_CSP
b "script-src unsafe-eval" clean bad-csp-unsafe-eval production csp SKIP_CSP
b "connect-src https:" clean bad-csp-https production csp SKIP_CSP
b "default-src data:" clean bad-csp-data production csp SKIP_CSP
b "style-src host source" clean bad-csp-host production csp SKIP_CSP
b "no default-src at all" clean bad-csp-no-default production csp SKIP_CSP
b "script-src-elem *" clean bad-csp-script-elem production csp SKIP_CSP
b "frame-src host" clean bad-csp-frame-src production csp SKIP_CSP
b "object-src data:" clean bad-csp-object-data production csp SKIP_CSP

# Contact page Turnstile exception (issue #4): one script tag, on contact/index.html only,
# and the Turnstile origins only in a contact route CSP that detaches the all-routes one.
expect_pass "contact page with the one Turnstile script" "$(stage clean "$FIX/ok-turnstile")" production
expect_pass "contact page with the Turnstile script without async" "$(stage clean "$FIX/ok-turnstile-noasync")" production
expect_pass "contact CSP block with the Turnstile origins" "$(stage clean "$FIX/ok-turnstile-csp-contact")" production
b "Turnstile script on the home page" clean bad-turnstile-home production no_script SKIP_NO_SCRIPT
b "Turnstile script on another page" clean bad-turnstile-other-page production no_script SKIP_NO_SCRIPT
b "second script on the contact page" clean bad-turnstile-second production no_script SKIP_NO_SCRIPT
b "script from another allowed origin on the contact page" clean bad-turnstile-origin production no_script SKIP_NO_SCRIPT
b "inline script on the contact page" clean bad-turnstile-inline production no_script SKIP_NO_SCRIPT
b "extra attribute on the Turnstile script" clean bad-turnstile-attr production no_script SKIP_NO_SCRIPT
# A different path on the Turnstile host trips both the script allowlist and the host check.
run_check "$(stage clean "$FIX/bad-turnstile-path")" production
if [ "$RC" = "0" ] || ! grep -q "^FAIL no_script:" <<<"$OUT" || ! grep -q "^FAIL external_host:" <<<"$OUT"; then
  soft "other path on the Turnstile host: expected no_script and external_host failures, got exit $RC: $OUT"
else
  run_check "$(stage clean "$FIX/bad-turnstile-path")" production SKIP_NO_SCRIPT=1 SKIP_EXTERNAL_HOST=1
  if [ "$RC" != "0" ]; then
    soft "other path on the Turnstile host: expected pass with both skips, got exit $RC: $OUT"
  else
    echo "ok: other path on the Turnstile host fails no_script and external_host"
  fi
fi
b "Turnstile origins in the all-routes CSP" clean bad-turnstile-csp-star production csp SKIP_CSP
b "extra host in the contact CSP" clean bad-turnstile-csp-contact-host production csp SKIP_CSP
b "Turnstile origin in connect-src of the contact CSP" clean bad-turnstile-csp-contact-connect production csp SKIP_CSP
b "contact CSP without detaching the all-routes CSP" clean bad-turnstile-csp-no-detach production csp SKIP_CSP
b "Turnstile CSP on a route other than contact" clean bad-turnstile-csp-other-route production csp SKIP_CSP
b "contact CSP detached after it is set" clean bad-turnstile-csp-detach-last production csp SKIP_CSP
b "contact CSP detached and never set" clean bad-turnstile-csp-detach-only production csp SKIP_CSP
b "contact CSP set twice" clean bad-turnstile-csp-two-sets production csp SKIP_CSP
b "Turnstile origin in a sandbox directive" clean bad-turnstile-csp-sandbox production csp SKIP_CSP
b "Turnstile origin in a trusted-types directive" clean bad-turnstile-csp-trusted-types production csp SKIP_CSP
b "Turnstile origin where a directive name belongs" clean bad-turnstile-csp-standalone production csp SKIP_CSP
b "unknown CSP directive" clean bad-csp-unknown-directive production csp SKIP_CSP
b "value on a no-value CSP directive" clean bad-csp-novalue-token production csp SKIP_CSP
b "Turnstile script with an inline body" clean bad-turnstile-src-body production no_script SKIP_NO_SCRIPT
b "self-closing Turnstile script" clean bad-turnstile-selfclosing production no_script SKIP_NO_SCRIPT
b "self-closing script on the home page" clean bad-script-selfclosing production no_script SKIP_NO_SCRIPT
b "Turnstile script inside a template element" clean bad-turnstile-template production no_script SKIP_NO_SCRIPT
b "Turnstile script inside svg foreignObject" clean bad-turnstile-svg production no_script SKIP_NO_SCRIPT
b "Turnstile script inside math" clean bad-turnstile-math production no_script SKIP_NO_SCRIPT
b "Turnstile script after a self-closing template" clean bad-turnstile-template-selfclosing production no_script SKIP_NO_SCRIPT
b "Turnstile script in a textarea after stray end tags of other elements" clean bad-turnstile-stray-endtag production no_script SKIP_NO_SCRIPT
# Elements whose content a browser treats as text or inactive: the parser still reports the tag.
for el in noscript title textarea xmp noembed style plaintext; do
  b "Turnstile script inside $el" clean "bad-turnstile-ctx-$el" production no_script SKIP_NO_SCRIPT
done
# iframe is also an active_embed finding of its own, so both checks are skipped together.
run_check "$(stage clean "$FIX/bad-turnstile-ctx-iframe")" production
if [ "$RC" = "0" ] || ! grep -q "^FAIL no_script:" <<<"$OUT"; then
  soft "Turnstile script inside iframe: expected a no_script failure, got exit $RC: $OUT"
else
  run_check "$(stage clean "$FIX/bad-turnstile-ctx-iframe")" production SKIP_NO_SCRIPT=1 SKIP_ACTIVE_EMBED=1
  if [ "$RC" != "0" ]; then
    soft "Turnstile script inside iframe: expected pass with both skips, got exit $RC: $OUT"
  else
    echo "ok: Turnstile script inside iframe fails no_script"
  fi
fi
expect_pass "report-to with a group name" "$(stage clean "$FIX/ok-csp-report-to-group")" production

# Unsafe schemes and meta refresh
b "javascript: href" clean bad-scheme-js production unsafe_scheme SKIP_UNSAFE_SCHEME
b "obfuscated javascript: href" clean bad-scheme-js-obfuscated production unsafe_scheme SKIP_UNSAFE_SCHEME
b "data: src" clean bad-scheme-data production unsafe_scheme SKIP_UNSAFE_SCHEME
b "vbscript: form action" clean bad-scheme-vbscript production unsafe_scheme SKIP_UNSAFE_SCHEME
b "meta refresh" clean bad-meta-refresh production meta_refresh SKIP_META_REFRESH

b "missing about link" clean bad-about-link production about_link SKIP_ABOUT_LINK

# Round 1 hardening: document detection, headers, embeds, base, anchors, denylist forms.
b "uppercase .HTML with a script" clean bad-upper-ext production no_script SKIP_NO_SCRIPT
b "extensionless html with a handler" clean bad-extless-html production inline_handler SKIP_INLINE_HANDLER
b ".xhtml with a script" clean bad-xhtml production no_script SKIP_NO_SCRIPT
b ".svg with a script" clean bad-svg-script production no_script SKIP_NO_SCRIPT
b "staging .HTML without noindex" clean-staging bad-staging-upper-no-noindex staging noindex SKIP_NOINDEX

b "CSP only under a non-/* route" clean bad-csp-route-only production csp SKIP_CSP
b "CSP also set in another block" clean bad-csp-other-block production csp SKIP_CSP
b "required header differs in another block" clean bad-headers-differ production csp SKIP_CSP
b "required header detached in another block" clean bad-headers-detach production csp SKIP_CSP
b "two CSP lines in /*" clean bad-csp-two production csp SKIP_CSP
b "report-uri off-site" clean bad-csp-report-uri production csp SKIP_CSP
b "report-to off-site" clean bad-csp-report-to production csp SKIP_CSP
expect_pass "report-uri with a relative path" "$(stage clean "$FIX/ok-csp-report-uri")" production

b "term as a numeric character reference" clean bad-scrub-charref production scrub_terms SKIP_SCRUB_TERMS
b "term as a character reference inside an attribute" clean bad-scrub-charref-alt production scrub_terms SKIP_SCRUB_TERMS
b "term split across elements" clean bad-scrub-split production scrub_terms SKIP_SCRUB_TERMS
b "term double-encoded" clean bad-scrub-double production scrub_terms SKIP_SCRUB_TERMS

# snippet_case <label> <html snippet put before </main>> <env> <check> <SKIP var>
snippet_tree() { # <snippet> -> echoes a clean tree with the snippet in index.html
  local t
  t="$(stage clean)"
  python3 -I -c '
import sys
p = sys.argv[1] + "/index.html"
s = open(p, encoding="utf-8").read()
s = s.replace("</main>", sys.argv[2] + "</main>")
open(p, "w", encoding="utf-8").write(s)
' "$t" "$1"
  echo "$t"
}
snippet_case() {
  bite "$1" "$(snippet_tree "$2")" "$3" "$4" "$5"
}
snippet_case "iframe element" '<iframe src="/x/"></iframe>' production active_embed SKIP_ACTIVE_EMBED
snippet_case "object element" '<object data="/x.bin"></object>' production active_embed SKIP_ACTIVE_EMBED
snippet_case "embed element" '<embed src="/x.bin">' production active_embed SKIP_ACTIVE_EMBED
snippet_case "frame element" '<frame src="/x/">' production active_embed SKIP_ACTIVE_EMBED
snippet_case "frameset element" '<frameset></frameset>' production active_embed SKIP_ACTIVE_EMBED
snippet_case "applet element" '<applet></applet>' production active_embed SKIP_ACTIVE_EMBED
snippet_case "srcdoc attribute" '<p srcdoc="hello">x</p>' production active_embed SKIP_ACTIVE_EMBED
snippet_case "base element" '<base href="/">' production base_element SKIP_BASE_ELEMENT
snippet_case "anchor to chiefgyk3d.com without rel" '<a href="https://chiefgyk3d.com/x">x</a>' production external_host SKIP_EXTERNAL_HOST
snippet_case "anchor to github.com with target and no rel" '<a href="https://github.com/x" target="_blank">x</a>' production external_host SKIP_EXTERNAL_HOST
expect_pass "anchor to the site own host without rel" "$(snippet_tree '<a href="https://renegadepenguinllc.com/x">x</a><a href="/y">y</a>')" production

# UTF-16 and non-UTF-8 text files, built at run time (binary content).
t="$(stage clean)"
python3 -I -c '
import sys
p = sys.argv[1] + "/utf16.html"
s = "<!doctype html><html><body><p>zzbannedtermzz</p></body></html>"
open(p, "wb").write(s.encode("utf-16"))
' "$t"
bite "term in a UTF-16 html file" "$t" production scrub_terms SKIP_SCRUB_TERMS
t="$(stage clean)"
python3 -I -c '
import sys
open(sys.argv[1] + "/notes.dat", "wb").write(bytes([0xff, 0xfe, 0xfd, 0x80]))
' "$t"
bite "non-UTF-8 text file" "$t" production scrub_terms SKIP_SCRUB_TERMS
t="$(stage clean)"
python3 -I -c '
import sys
open(sys.argv[1] + "/pic.PNG", "wb").write(bytes([0x89, 0xff, 0xfe, 0x80]))
' "$t"
expect_pass "non-UTF-8 bytes in a known binary type" "$t" production

# Round 2: effective headers, duplicate attributes, invisible characters, NULs, sniffing.
b "CSP set then detached in /*" clean bad-csp-detach-same production csp SKIP_CSP
b "protected header detached in /*" clean bad-headers-detach-star production csp SKIP_CSP
b "duplicate protected header in /*" clean bad-headers-dup-star production csp SKIP_CSP
b "invalid protected header value in /*" clean bad-headers-bad-value production csp SKIP_CSP
b "duplicate protected header in another block" clean bad-headers-dup-other production csp SKIP_CSP

snippet_case "duplicate http-equiv" '<meta http-equiv="x" http-equiv="y" content="z">' production duplicate_attr SKIP_DUPLICATE_ATTR
snippet_case "duplicate src" '<img src="/a.png" src="/b.png" alt="x">' production duplicate_attr SKIP_DUPLICATE_ATTR
snippet_case "duplicate href" '<a href="/a" href="/b">x</a>' production duplicate_attr SKIP_DUPLICATE_ATTR
snippet_case "duplicate rel" '<a href="/a" rel="noreferrer" rel="noopener">x</a>' production duplicate_attr SKIP_DUPLICATE_ATTR
snippet_case "duplicate attribute, different case" '<img SRC="/a.png" src="/b.png" alt="x">' production duplicate_attr SKIP_DUPLICATE_ATTR

# file_case <label> <check> <SKIP var> <relative name> <python expression giving bytes>
# The expression is a literal from this test file, never external input (eval is safe here).
file_case() {
  local label="$1" check="$2" skip="$3" name="$4" expr="$5" t
  t="$(stage clean)"
  python3 -I -c '
import sys
data = eval(sys.argv[3])  # evaluated first: the expression may read the file it replaces
open(sys.argv[1] + "/" + sys.argv[2], "wb").write(data)
' "$t" "$name" "$expr"
  bite "$label" "$t" production "$check" "$skip"
}
file_case "term split by U+200B" scrub_terms SKIP_SCRUB_TERMS zw.html '("<p>zzbanned" + chr(0x200b) + "termzz</p>").encode()'
file_case "term split by U+00AD" scrub_terms SKIP_SCRUB_TERMS shy.html '("<p>zzbanned" + chr(0xad) + "termzz</p>").encode()'
file_case "term split by U+FEFF" scrub_terms SKIP_SCRUB_TERMS bom.html '("<p>zzbanned" + chr(0xfeff) + "termzz</p>").encode()'
file_case "term split by U+202E" scrub_terms SKIP_SCRUB_TERMS rlo.html '("<p>zzbanned" + chr(0x202e) + "termzz</p>").encode()'
file_case "term split by U+FE0F" scrub_terms SKIP_SCRUB_TERMS vs.html '("<p>zzbanned" + chr(0xfe0f) + "termzz</p>").encode()'
file_case "banned claim in a page" claims SKIP_CLAIMS claim.html 'b"<p>100% guaranteed</p>"'
file_case "bare dollar figure in a page" claims SKIP_CLAIMS price.html '("<p>from " + chr(36) + "5,000</p>").encode()'
file_case "BOM-less UTF-16LE text" scrub_terms SKIP_SCRUB_TERMS notes.dat '"zzbannedtermzz".encode("utf-16-le")'
file_case "BOM-less UTF-16BE text" scrub_terms SKIP_SCRUB_TERMS notes2.dat '"zzbannedtermzz".encode("utf-16-be")'
file_case "extensionless html after 1025 spaces" no_script SKIP_NO_SCRIPT page2 '(" " * 1025 + "<html><body><script>var x=1</script></body></html>").encode()'
file_case "extensionless html after comments" no_script SKIP_NO_SCRIPT page3 '("<!-- a -->" * 300 + "<div><script>var x=1</script></div>").encode()'

# Round 3: every protected header required, strict values, default-ignorable characters.
b "protected headers missing from /*" clean bad-headers-missing production csp SKIP_CSP
b "empty Permissions-Policy" clean bad-permissions-empty production csp SKIP_CSP
b "Permissions-Policy that allows a feature" clean bad-permissions-allow production csp SKIP_CSP
b "HSTS not-max-age lookalike" clean bad-hsts-lookalike production csp SKIP_CSP
b "HSTS duplicate max-age" clean bad-hsts-duplicate production csp SKIP_CSP
b "HSTS max-age too low" clean bad-hsts-low production csp SKIP_CSP
b "HSTS quoted max-age" clean bad-hsts-quoted production csp SKIP_CSP
file_case "HSTS overlong digit string" csp SKIP_CSP _headers 'open(sys.argv[1] + "/_headers", "rb").read().replace(b"max-age=31536000", b"max-age=" + b"9" * 5000)'
# The overlong value must be rejected by the rule itself, not by a crash.
python3 -I -c '
import sys
s = open(sys.argv[1] + "/_headers", encoding="utf-8").read()
open(sys.argv[2], "w", encoding="utf-8").write(s.replace("max-age=31536000", "max-age=" + "9" * 5000))
' "$FIX/clean" "$WORK/overlong-headers"
set +e
OUT="$(python3 -I scripts/check-headers.py "$WORK/overlong-headers" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ] && grep -q 'strict-transport-security has an unacceptable value' <<<"$OUT"; then
  echo "ok: overlong HSTS digits rejected by the rule, no crash"
else
  soft "overlong HSTS digits: expected a finding with exit 0, got exit $RC: $OUT"
fi
file_case "term split by U+17B4" scrub_terms SKIP_SCRUB_TERMS khmer.html '("<p>zzbanned" + chr(0x17b4) + "termzz</p>").encode()'
file_case "term split by U+FFF0" scrub_terms SKIP_SCRUB_TERMS fff0.html '("<p>zzbanned" + chr(0xfff0) + "termzz</p>").encode()'
file_case "term split by U+1D173" scrub_terms SKIP_SCRUB_TERMS music.html '("<p>zzbanned" + chr(0x1d173) + "termzz</p>").encode()'
file_case "term split by U+E0001" scrub_terms SKIP_SCRUB_TERMS tag.html '("<p>zzbanned" + chr(0xe0001) + "termzz</p>").encode()'

# Every row of the default-ignorable table: first and last code point of each range.
# (U+00AD, U+17B4, U+200B, U+202E, U+FE0F, U+FEFF, U+FFF0 and U+1D173 are tested above.)
for cp in 034F 061C 115F 1160 17B5 180B 180F 200F 202A 2060 206F 3164 FE00 FFA0 FFF8 1BCA0 1BCA3 1D17A E0000 E0FFF; do
  file_case "term split by U+$cp" scrub_terms SKIP_SCRUB_TERMS "ign-$cp.html" "(\"<p>zzbanned\" + chr(0x$cp) + \"termzz</p>\").encode()"
done

# _headers grammar: plain LF, space indentation, bare route lines, each route once.
file_case "_headers with CRLF line endings" csp SKIP_CSP _headers 'open(sys.argv[1] + "/_headers", "rb").read().replace(b"\n", b"\r\n")'
file_case "_headers with tab indentation" csp SKIP_CSP _headers 'open(sys.argv[1] + "/_headers", "rb").read().replace(b"\n  ", b"\n\t")'
file_case "_headers route line with a trailing space" csp SKIP_CSP _headers 'open(sys.argv[1] + "/_headers", "rb").read().replace(b"/*\n", b"/* \n", 1)'
file_case "_headers route line with text after the path" csp SKIP_CSP _headers 'open(sys.argv[1] + "/_headers", "rb").read() + b"\n/docs/* extra\n  X-Robots-Tag: all\n"'
file_case "_headers with /* repeated" csp SKIP_CSP _headers 'open(sys.argv[1] + "/_headers", "rb").read() + b"\n/*\n  X-Frame-Options: DENY\n"'

# Opt-in owner-token check: a page holding an unresolved owner placeholder fails only when
# REQUIRE_NO_OWNER_TOKENS=1 (the deploy workflow sets it); CI keeps placeholders green.
tok_tree="$(stage clean)"
python3 -I -c '
import sys
open(sys.argv[1] + "/owner.html", "w").write("<p>stance: " + chr(123) * 2 + "OWNER:state it" + chr(125) * 2 + "</p>")
' "$tok_tree"
run_check "$tok_tree" production
if [ "$RC" = "0" ]; then echo "ok: owner token passes when the check is not enabled"; else soft "owner token must pass when not enabled: $OUT"; fi
run_check "$tok_tree" production REQUIRE_NO_OWNER_TOKENS=1
if [ "$RC" != "0" ] && grep -q '^FAIL owner_tokens:' <<<"$OUT"; then echo "ok: owner token fails when REQUIRE_NO_OWNER_TOKENS=1"; else soft "owner token must fail when enabled: rc=$RC $OUT"; fi
run_check "$tok_tree" production REQUIRE_NO_OWNER_TOKENS=1 SKIP_OWNER_TOKENS=1
if [ "$RC" = "0" ]; then echo "ok: SKIP_OWNER_TOKENS=1 disables the owner token check"; else soft "SKIP_OWNER_TOKENS=1 must pass: $OUT"; fi
run_check "$(stage clean)" production REQUIRE_NO_OWNER_TOKENS=1
if [ "$RC" = "0" ]; then echo "ok: clean tree passes with REQUIRE_NO_OWNER_TOKENS=1"; else soft "clean tree must pass with the check enabled: $OUT"; fi

# tok_case <label> <file name> <html>: the page must fail with REQUIRE_NO_OWNER_TOKENS=1 and pass without it.
tok_case() {
  local t
  t="$(stage clean)"
  printf '%s' "$3" >"$t/$2"
  run_check "$t" production REQUIRE_NO_OWNER_TOKENS=1
  if [ "$RC" = "0" ] || ! grep -q '^FAIL owner_tokens:' <<<"$OUT"; then
    soft "$1: expected FAIL owner_tokens when enabled, rc=$RC: $OUT"
    return 0
  fi
  run_check "$t" production
  if [ "$RC" != "0" ]; then
    soft "$1: expected pass when the check is not enabled, rc=$RC: $OUT"
    return 0
  fi
  echo "ok: $1 is caught only when REQUIRE_NO_OWNER_TOKENS=1"
}
tok_case "decimal-entity braces" dec.html '<p>&#123;&#123;OWNER:x}}</p>'
tok_case "hex-entity braces" hex.html '<p>&#x7b;&#x7b;OWNER:x}}</p>'
tok_case "named-entity braces (lbrace)" lbrace.html '<p>&lbrace;&lbrace;OWNER:x}}</p>'
tok_case "named-entity braces (lcub)" lcub.html '<p>&lcub;&lcub;OWNER:x}}</p>'
tok_case "token split by inline tags" split.html '<p>{{<b>OWN</b><i>ER</i>:x}}</p>'
tok_case "token in an attribute" attr.html '<a href="/x" title="{{OWNER:x}}">link</a>'
tok_case "token in a self-closing tag attribute" selfclose.html '<img src="/a.png" alt="{{OWNER:x}}" />'
tok_case "token in the title" title.html '<title>{{OWNER:x}}</title><p>body</p>'
tok_case "token in meta content" meta.html '<meta name="description" content="{{OWNER:x}}"><p>body</p>'
tok_case "token in an HTML comment" comment.html '<!-- {{OWNER:x}} --><p>body</p>'
tok_case "token with spaced braces" spaced.html '<p>{ { OWNER: x} }</p>'
tok_case "lowercase token" lower.html '<p>{{owner:x}}</p>'
tok_case "token in a .HTML file" UPPER.HTML '<p>{{OWNER:x}}</p>'

# Near misses must not trip the check (proves the marker is not shortened or loosened).
near="$(stage clean)"
printf '%s' '<p>{{OWNED}} the OWNER: field, {OWNER:x} and {{ONER:x}}</p>' >"$near/near.html"
run_check "$near" production REQUIRE_NO_OWNER_TOKENS=1
if [ "$RC" = "0" ]; then echo "ok: near-miss text passes with REQUIRE_NO_OWNER_TOKENS=1"; else soft "near-miss text must pass: rc=$RC $OUT"; fi

# REQUIRE_NO_OWNER_TOKENS: unset, empty and 0 skip; 1 runs; anything else fails closed.
tok_tree="$(stage clean)"
printf '%s' '<p>{{OWNER:x}}</p>' >"$tok_tree/owner.html"
run_check "$tok_tree" production REQUIRE_NO_OWNER_TOKENS=0
if [ "$RC" = "0" ]; then echo "ok: REQUIRE_NO_OWNER_TOKENS=0 skips the check"; else soft "REQUIRE_NO_OWNER_TOKENS=0 must skip: $OUT"; fi
run_check "$tok_tree" production REQUIRE_NO_OWNER_TOKENS=
if [ "$RC" = "0" ]; then echo "ok: empty REQUIRE_NO_OWNER_TOKENS skips the check"; else soft "empty REQUIRE_NO_OWNER_TOKENS must skip: $OUT"; fi
for v in true yes 2 TRUE ' 1' 01; do
  for tree in "$(stage clean)" "$tok_tree"; do
    run_check "$tree" production "REQUIRE_NO_OWNER_TOKENS=$v"
    if [ "$RC" != "0" ] && grep -q '^FAIL owner_tokens: REQUIRE_NO_OWNER_TOKENS' <<<"$OUT"; then
      echo "ok: REQUIRE_NO_OWNER_TOKENS='$v' fails closed"
    else
      soft "REQUIRE_NO_OWNER_TOKENS='$v' must fail closed, rc=$RC: $OUT"
    fi
  done
done

# check-owner-tokens.py with a directory that does not exist must not read as a pass.
set +e
OUT="$(python3 -I scripts/check-owner-tokens.py "$WORK/no-such-dir" 2>&1)"
RC=$?
set -e
if [ "$RC" = "2" ]; then echo "ok: check-owner-tokens.py rejects a missing directory"; else soft "check-owner-tokens.py on a missing directory: expected exit 2, got $RC: $OUT"; fi

# The owner token helper crashing must fail the build when the check is enabled.
stub="$(mktemp -d "$WORK/stub.XXXXXX")"
cp -R scripts/. "$stub/"
printf '%s\n' 'raise RuntimeError("stub crash")' >"$stub/check-owner-tokens.py"
set +e
OUT="$(env EXPECT_ENV=production SCRUB_TERMS_FILE="$TERMS" REQUIRE_NO_OWNER_TOKENS=1 "$stub/check-output.sh" "$(stage clean)" 2>&1)"
RC=$?
set -e
if [ "$RC" != "0" ] && grep -q '^FAIL owner_tokens:' <<<"$OUT"; then echo "ok: crashing check-owner-tokens.py fails the build"; else soft "crashing check-owner-tokens.py must fail the build: rc=$RC $OUT"; fi

# A crashing helper must fail the build (fail closed): swap one helper for a stub.
for helper in check-headers.py check-html.py check-scrub.py find-dashes.py check-claims.py; do
  stub="$(mktemp -d "$WORK/stub.XXXXXX")"
  cp -R scripts/. "$stub/"
  printf '%s\n' 'raise RuntimeError("stub crash")' >"$stub/$helper"
  set +e
  OUT="$(env EXPECT_ENV=production SCRUB_TERMS_FILE="$TERMS" "$stub/check-output.sh" "$(stage clean)" 2>&1)"
  RC=$?
  set -e
  if [ "$RC" = "0" ]; then
    soft "crashing $helper must fail the build, got exit 0"
  elif ! grep -q '^FAIL ' <<<"$OUT"; then
    soft "crashing $helper gave no FAIL line: $OUT"
  else
    echo "ok: crashing $helper fails the build"
  fi
done

# Each helper catches its own unexpected exceptions and exits 70 (here: missing arguments).
for helper in check-headers.py check-html.py check-scrub.py find-dashes.py check-claims.py check-owner-tokens.py; do
  set +e
  OUT="$(python3 -I "scripts/$helper" 2>&1)"
  RC=$?
  set -e
  if [ "$RC" != "70" ]; then
    soft "$helper with no arguments: expected exit 70, got $RC: $OUT"
  elif grep -q 'Traceback' <<<"$OUT"; then
    soft "$helper printed a traceback: $OUT"
  else
    echo "ok: $helper reports an unexpected error with exit 70"
  fi
done

# check-contrast.py: inject an unexpected exception into a copy and expect exit 70.
cstub="$WORK/check-contrast-stub.py"
python3 -I -c '
import sys
s = open(sys.argv[1], encoding="utf-8").read()
old = "    paths = list(argv)\n"
assert old in s
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(old, "    raise RuntimeError(\"stub\")\n" + old, 1))
' scripts/check-contrast.py "$cstub"
set +e
OUT="$(python3 -I "$cstub" assets/css/tokens.css 2>&1)"
RC=$?
set -e
if [ "$RC" != "70" ]; then
  soft "check-contrast.py with an injected exception: expected exit 70, got $RC: $OUT"
else
  echo "ok: check-contrast.py reports an unexpected error with exit 70"
fi

# Dash fixtures are generated so the characters never appear in the repo.
dash_case() { # <codepoint> <file that receives the dash>
  local cp="$1" file="$2" t
  t="$(stage clean)"
  python3 -I -c '
import sys
p = sys.argv[1] + "/" + sys.argv[2]
d = chr(int(sys.argv[3], 16))
s = open(p, encoding="utf-8").read()
if p.endswith(".html"):
    s = s.replace("</main>", "<p>a" + d + "b</p></main>")
else:
    s = s + "a" + d + "b\n"
open(p, "w", encoding="utf-8").write(s)
' "$t" "$file" "$cp"
  bite "dash U+${cp#0x} in $file" "$t" production dashes SKIP_DASHES
}
dash_case 0x2014 index.html
dash_case 0x2013 index.html
dash_case 0x2014 sitemap.xml
dash_case 0x2013 css/site.css
dash_case 0x2014 robots.txt

# Real build, production and staging.
HUGO_OUT="$WORK/real"
mkdir -p "$HUGO_OUT/prod" "$HUGO_OUT/stg"
"$HUGO" --minify --destination "$HUGO_OUT/prod" >/dev/null || fail "production hugo build failed"
HUGO_PARAMS_ENVIRONMENT=staging "$HUGO" --minify --destination "$HUGO_OUT/stg" >/dev/null || fail "staging hugo build failed"
expect_pass "real production build" "$HUGO_OUT/prod" production
expect_pass "real staging build" "$HUGO_OUT/stg" staging

# Independent assertions on the real builds (not through check-output.sh).
if grep -rliE 'noindex' "$HUGO_OUT/prod" --include='*.html' | grep -q .; then soft "production build contains noindex"; fi
pages=$(find "$HUGO_OUT/stg" -name '*.html' | wc -l)
[ "$pages" -ge 1 ] || fail "staging build produced no html"
withidx=$(grep -rliE 'noindex' "$HUGO_OUT/stg" --include='*.html' | wc -l)
[ "$pages" = "$withidx" ] || soft "staging: $withidx of $pages html pages carry noindex"
grep -qx 'Disallow: /' "$HUGO_OUT/stg/robots.txt" || soft "staging robots.txt lacks 'Disallow: /'"
run_check "$HUGO_OUT/prod" staging
if [ "$RC" = "0" ]; then soft "production build must fail the staging expectation"; fi
echo "checked: real builds carry the right indexing signals"

if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS case(s)" >&2
  exit 1
fi
echo "PASS: check-output tests"
