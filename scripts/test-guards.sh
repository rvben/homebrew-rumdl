#!/usr/bin/env bash
# Tests for the guard scripts themselves.
#
#   scripts/test-guards.sh
#
# Every check in verify-formula.sh exists because a specific broken formula once
# passed it. Those proofs were one-off experiments, which means the checks could
# be weakened or reordered later and nothing would notice: a script that exits 1
# on everything, or 0 on everything, passes an eye test just as well as a correct
# one. Each case below breaks the formula in exactly one way and requires the
# guard to reject it *with the message belonging to the check under test*, so a
# mutation caught by the wrong check is a failure rather than a pass.
#
# Two-sided, deliberately. Case 1 requires the unmodified formula to clear every
# structural check and reach the download stage, so "reject everything" cannot
# pass this suite.
#
# Hermetic and offline: each case runs the real script against a scratch copy of
# the repository, and `curl` is stubbed to fail immediately, so nothing here
# touches the network, Homebrew, or the working tree. That bounds what this suite
# can prove to the structural invariants - the download half (does each pin match
# its artifact, does each archive hold an installable binary of the right
# architecture) is checked against the real published assets by every run of
# verify-formula.sh itself, which is what the `pins` CI job does.

set -uo pipefail

# No `set -e` here: every case below runs a script that is expected to fail, and
# reads its exit code. So `cd` carries its own guard.
cd "$(dirname "$0")/.." || exit 1
FORMULA="Formula/rumdl.rb"
[ -f "$FORMULA" ] || { echo "error: $FORMULA not found" >&2; exit 1; }

WORK="$(mktemp -d)"
# There is no `set -e` here, so a failed mktemp is not fatal by itself: $WORK ends
# up empty, every case builds its scratch tree at /case-N, mkdir is denied, and
# twelve guard failures get reported for a scratch directory that was never
# created. Observed for real in a sandbox with no writable temporary directory,
# which reported "FAILED: 5 of 5 guard tests" and said nothing about mktemp. The
# other scripts here run under `set -e` and abort on their own.
if [ -z "${WORK:-}" ] || [ ! -d "$WORK" ]; then
  echo "error: could not create a temporary directory (mktemp -d failed)." >&2
  echo "       Every case needs one. Refusing to report guard failures for it." >&2
  exit 1
fi
trap 'rm -rf "$WORK"' EXIT

# Read from the formula rather than written in here. A mutation built from a
# literal version or a literal hash stops matching the moment the tap moves to
# the next release: the case then receives an unmodified formula, the guard
# correctly accepts it, and the case fails - turning CI red on a routine version
# bump, in the job that runs before pin verification. Verified by bumping a
# scratch copy of the formula and re-running this suite.
CUR_VERSION="$(sed -n 's|.*/releases/download/v\([0-9][0-9.]*\)/.*|\1|p' "$FORMULA" | sort -u | head -1)"
FIRST_SHA="$(sed -n 's/^[[:space:]]*sha256 "\([^"]*\)".*/\1/p' "$FORMULA" | head -1)"
if [ -z "$CUR_VERSION" ] || [ -z "$FIRST_SHA" ]; then
  echo "error: could not read the current version and first pin from $FORMULA" >&2
  exit 1
fi
# Any version that is not the current one, derived so it cannot collide with it.
OTHER_VERSION="${CUR_VERSION%.*}.$((${CUR_VERSION##*.} + 1))"

# The guard against the failure above, applied to every mutation: a sed or python
# program that matches nothing produces the formula unchanged, and a case fed an
# unchanged formula is testing nothing while blaming the guard for it.
assert_mutated() { # assert_mutated <file>
  if cmp -s "$1" "$FORMULA"; then
    echo "HARNESS FAILURE: the mutation for the next case changed nothing." >&2
    echo "                 It would test an unmodified formula and report the" >&2
    echo "                 guard as broken. Fix the mutation, not the guard." >&2
    exit 1
  fi
}

# Two cases build their mutation with python3, and a missing interpreter is the
# one failure `assert_mutated` cannot see: the heredoc writes an EMPTY file, which
# differs from the formula, so the mutation looks real. verify-formula.sh then
# exits 1 on "no url/sha256 pairs found" and the case reports the guard as broken
# for want of the message it expected. Failing closed while naming the wrong cause
# is how this suite would mislead a contributor, so say it plainly instead. This
# repository has already paid for that pattern once: a receipt parse written in
# python3 silently concluded "nothing is installed" on a Homebrew image that had
# none.
command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required by this suite and is not on PATH." >&2
  echo "       Two cases build their mutated formula with it. Without it they" >&2
  echo "       would test an empty file and blame the guard under test." >&2
  exit 1
}

# A curl that cannot succeed, so the structural checks are all that runs. Exit 6
# is curl's own "could not resolve host", which is what an offline run would give
# anyway.
mkdir -p "$WORK/stub"
printf '#!/bin/sh\nexit 6\n' > "$WORK/stub/curl"
chmod +x "$WORK/stub/curl"
export PATH="$WORK/stub:$PATH"

pass=0
fail=0

# case <name> <expect_exit|any> <expect_substring> <script> [args...] -- reads the
# mutated formula on stdin.
case_run() {
  local name="$1" want_code="$2" want_text="$3" script="$4"; shift 4
  local dir="$WORK/case-$((pass + fail + 1))"
  mkdir -p "$dir/Formula" "$dir/scripts"
  cat > "$dir/Formula/rumdl.rb"
  cp scripts/verify-formula.sh scripts/update-formula.sh "$dir/scripts/"
  chmod +x "$dir/scripts"/*.sh

  local out code
  out="$(cd "$dir" && "./scripts/$script" "$@" 2>&1)"
  code=$?

  local why=""
  if [ "$want_code" != "any" ] && [ "$code" != "$want_code" ]; then
    why="expected exit $want_code, got $code"
  elif ! printf '%s' "$out" | grep -qF -- "$want_text"; then
    why="expected message not found: $want_text"
  fi

  if [ -z "$why" ]; then
    pass=$((pass + 1))
    printf 'ok    %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n' "$name"
    printf '      %s\n' "$why"
    printf '%s\n' "$out" | sed 's/^/      | /' | head -12
  fi
}

echo "Guard tests (offline; curl stubbed to fail)"
echo

# 1. The positive control. The unmodified formula must clear every structural
#    check and reach the download stage, which this line marks. Without this a
#    guard that rejected everything would pass every other case here.
case_run "unmodified formula clears every structural check" any \
  "Verifying Formula/rumdl.rb at version" verify-formula.sh < "$FORMULA"

# 2. Arguments are rejected rather than ignored, so `verify-formula.sh 0.2.77`
#    cannot report the committed version's pins as if they were 0.2.77's.
case_run "an argument is refused, not discarded" 2 \
  "takes no arguments" verify-formula.sh 0.2.77 < "$FORMULA"

# 3. The four correct assets arranged in the wrong Hardware::CPU branches. Every
#    other check in the script is satisfied by this formula, which hands Intel
#    Macs an arm64-only binary.
python3 - "$FORMULA" <<'PY' > "$WORK/macswap.rb"
import re, sys
t = open(sys.argv[1]).read()
pairs = re.findall(r'( *url "[^"]*apple-darwin\.tar\.gz"\n *sha256 "[^"]*"\n)', t)
assert len(pairs) == 2, f"expected 2 macOS url/sha256 pairs, found {len(pairs)}"
a, b = pairs
out = t.replace(a, "@@A@@").replace(b, "@@B@@").replace("@@A@@", b).replace("@@B@@", a)
assert out != t and out.count("apple-darwin") == t.count("apple-darwin")
sys.stdout.write(out)
PY
assert_mutated "$WORK/macswap.rb"
case_run "macOS pairs swapped between the intel and arm branches" 1 \
  "the macos:intel branch must carry x86_64-apple-darwin" \
  verify-formula.sh < "$WORK/macswap.rb"

# 4. A platform dropped entirely. The url, sha256 and pair counts all stay in
#    agreement, so no count check sees it. The expected-platform list is what
#    rejects it, and the branch-exactly-once check further down independently
#    rejects it too - verified by neutralising the list, which left the run
#    failing on "does not declare each platform branch exactly once". That is why
#    this case asserts the list's own message: a mutation caught only by the
#    backstop would otherwise read as proof of a check that is no longer there.
#
#    awk rather than `sed '/x86_64-apple-darwin/,+1d'`: the `,+N` address range is
#    a GNU extension with no POSIX equivalent, and this suite runs on whatever sed
#    the runner has. It does work on this macOS (Darwin 25.5 BSD sed deletes both
#    lines), so nothing was broken - but a mutation that silently becomes a no-op
#    on some other sed would feed the case an unmodified formula and blame the
#    guard for accepting it, which is the failure assert_mutated exists to catch.
awk '
  /x86_64-apple-darwin/ { skip = 2 }
  skip > 0 { skip--; dropped++; next }
  { print }
  END {
    if (dropped != 2) {
      print "mutation: expected to drop a url and its pin, dropped " dropped > "/dev/stderr"
      exit 1
    }
  }
' "$FORMULA" > "$WORK/dropped.rb"
assert_mutated "$WORK/dropped.rb"
case_run "a platform removed with its pin" 1 \
  "does not ship the expected set of platforms" \
  verify-formula.sh < "$WORK/dropped.rb"

# 5. A url pointing somewhere other than rumdl's releases. A host serving bytes
#    that match the pin satisfies every hash check there is.
sed 's|github.com/rvben/rumdl/releases|github.com/someone/else/releases|' "$FORMULA" > "$WORK/origin.rb"
assert_mutated "$WORK/origin.rb"
case_run "a url that does not fetch from rumdl's releases" 1 \
  "does not fetch from rumdl's own releases" \
  verify-formula.sh < "$WORK/origin.rb"

# 6. A half-rewritten formula: one platform moved to a new release, the rest left
#    behind. The version is scanned from the urls, so they have to agree.
awk -v cur="v$CUR_VERSION" -v other="v$OTHER_VERSION" '
  /^[[:space:]]*url "/ && /aarch64-unknown-linux-musl\.tar\.gz/ {
    n = gsub(cur, other)
    if (n != 2) {
      print "mutation: expected 2 version mentions in the url, changed " n > "/dev/stderr"
      exit 1
    }
  }
  { print }
' "$FORMULA" > "$WORK/mixed.rb"
assert_mutated "$WORK/mixed.rb"
case_run "urls naming two different versions" 1 \
  "name more than one version" \
  verify-formula.sh < "$WORK/mixed.rb"

# 7. A url that sits in no CPU branch at all, so nothing decides which machine
#    gets it.
sed '/Hardware::CPU.intel?/d' "$FORMULA" > "$WORK/unbound.rb"
assert_mutated "$WORK/unbound.rb"
case_run "a url outside any Hardware::CPU branch" 1 \
  "sits in no recognised platform branch" \
  verify-formula.sh < "$WORK/unbound.rb"

# 8. A sha256 with no url above it. The url/sha/pair counts can still agree on
#    this, which is how it once reached the download loop and was reported as a
#    malformed pin instead of a malformed formula.
python3 - "$FORMULA" <<'PY' > "$WORK/unpaired.rb"
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r'( *)sha256 "([^"]*)"\n', t)
assert m, "no sha256 line found"
# A second sha256 directly below the first, and one url removed so the counts
# still balance.
t = t[:m.end()] + f'{m.group(1)}sha256 "{m.group(2)}"\n' + t[m.end():]
t = re.sub(r' *url "[^"]*aarch64-unknown-linux-musl\.tar\.gz"\n', '', t, count=1)
sys.stdout.write(t)
PY
assert_mutated "$WORK/unpaired.rb"
case_run "a sha256 with no url above it" 1 \
  "has no url above it" \
  verify-formula.sh < "$WORK/unpaired.rb"

# 9. A pin that is not a sha256 at all. Checked before the download, so a
#    placeholder left in the formula fails by name rather than as a hash
#    mismatch.
sed "s|sha256 \"$FIRST_SHA\"|sha256 \"PLACEHOLDER\"|" "$FORMULA" > "$WORK/placeholder.rb"
assert_mutated "$WORK/placeholder.rb"
case_run "a pin that is not 64 hex characters" 1 \
  "pinned sha256 is not 64 hex characters" \
  verify-formula.sh < "$WORK/placeholder.rb"

# 10-12. The updater's version guard. It reaches curl, a url and the formula
#    text, and the value arrives from a repository_dispatch payload. Run with
#    ALLOW_UNATTESTED=1 so the checks under test are reached without a gh login.
export ALLOW_UNATTESTED=1

case_run "a version that is not a version" 2 \
  "version must look like 1.2.3" update-formula.sh "1.2; rm -rf /" < "$FORMULA"

# The one grep would accept: a bare semver on the first line, anything after it.
case_run "a version whose first line only looks valid" 2 \
  "version must look like 1.2.3" update-formula.sh "$(printf '1.2.3\nrm -rf /')" < "$FORMULA"

case_run "moving the tap to an older version" 1 \
  "Refusing to move the tap backwards" update-formula.sh 0.1.0 < "$FORMULA"

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) guard tests"
  exit 1
fi
echo "All $pass guard tests pass."
