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
# Two-sided, deliberately. Two cases require a correct run to succeed: case 1 that
# the unmodified formula clears every structural check and reaches the download
# stage, and case 13 that a full update pins each url to the bytes that url
# fetched. Without them, a script that rejected everything would pass this suite.
#
# Hermetic and offline. Each case runs the real script against a scratch copy of
# the repository, so nothing here touches the network, Homebrew, or the working
# tree. By default `curl` is stubbed to fail immediately, which is all the
# structural cases need. The cases that run update-formula.sh to completion get
# per-case stubs instead: a `curl` serving locally built tarballs - one per target,
# four distinct ones, so a mispaired pin is visible - a `gh` that does or does not
# attest, and a `file` that answers for the fixture binaries, which are shell
# scripts rather than Mach-O and ELF.
#
# What that leaves to CI: whether rumdl's actually published assets match the pins
# in the committed formula. No local fixture can answer that, and it is the whole
# job of verify-formula.sh, which the `pins` job runs immediately after this.

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

# Two kinds of inherited environment decide the outcome of a case, so both are
# cleared once here rather than remembered per case.
#
# git's overrides name a repository rather than a directory. With GIT_DIR or
# GIT_WORK_TREE exported - which is exactly how git invokes a hook, and a hook is
# one of the places a contributor runs this suite from - the `git init` that builds
# a scratch repository below instead rewrites the config of whatever repository
# those point at, and the case reports a guard failure for it. Reproduced: with
# GIT_DIR set to an unrelated repository, its .git/config was rewritten and the
# setup then failed on `pathspec 'Formula' did not match any files`.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_CONFIG GIT_CONFIG_COUNT
#
# The scripts under test read their escape hatches from the environment, and each
# one turns a refusal that a case asserts into a deliberate proceed. A case must
# not depend on whether the caller happened to export one; the case that is about
# a hatch exports it itself.
unset ALLOW_UNATTESTED ALLOW_REPIN ALLOW_DOWNGRADE DISCARD_TAP_CLONE

CASE_SETUP=""
CASE_STUBS=""
CASE_ASSERT=""

# ---------------------------------------------------------------------------
# Fixture release assets, for the cases that run update-formula.sh to completion.
#
# Everything above stops at a structural check, so a curl that always fails is
# enough. The updater's remaining half - the provenance loop, the re-pin
# comparison, the hash write-back, and the restore when verification fails - only
# runs once downloads succeed, and those are the parts that decide what gets
# pinned. Reaching them needs a curl that hands back plausible assets.
#
# Real gzip tarballs holding a real executable, because verify-formula.sh unpacks
# each asset and requires an installable `rumdl` inside, and four *different* ones
# because the invariant under test is that each pin is the hash of the archive its
# own url fetches. A single shared payload would read identically whether the
# write-back paired them correctly or wrote one hash four times over.
# ---------------------------------------------------------------------------

sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

TARGETS="aarch64-apple-darwin aarch64-unknown-linux-musl x86_64-apple-darwin x86_64-unknown-linux-musl"

build_fixture_assets() { # build_fixture_assets <outdir> <build-name>
  local t d
  mkdir -p "$1" || return 1
  for t in $TARGETS; do
    d="$WORK/build-$2/$t"
    mkdir -p "$d" || return 1
    # The target is named inside the binary so the `file` stub below can answer
    # for it, and the build name is what makes the second set of assets different
    # bytes from the first.
    printf '#!/bin/sh\n# fixture binary for %s\n# fixture build %s\necho "rumdl fixture"\n' \
      "$t" "$2" > "$d/rumdl" || return 1
    chmod +x "$d/rumdl" || return 1
    # COPYFILE_DISABLE because BSD tar otherwise adds ._rumdl AppleDouble members,
    # and verify-formula.sh matches the archive's entries exactly.
    ( cd "$d" && COPYFILE_DISABLE=1 tar czf "$1/$t.tar.gz" rumdl ) || return 1
  done
}

build_fixture_assets "$WORK/assets" first ||
  { echo "HARNESS FAILURE: could not build the fixture assets" >&2; exit 1; }
build_fixture_assets "$WORK/assets-replaced" second ||
  { echo "HARNESS FAILURE: could not build the replaced fixture assets" >&2; exit 1; }

# Both controls on the fixtures themselves, because either failure would make a
# case pass while testing nothing. Four identical assets cannot show a mispaired
# pin; a replacement set identical to the original cannot show a mid-run asset
# swap, and verification would simply succeed.
distinct="$(for t in $TARGETS; do sha256_of_file "$WORK/assets/$t.tar.gz"; done | sort -u | wc -l | tr -d ' ')"
if [ "$distinct" != "4" ]; then
  echo "HARNESS FAILURE: the four fixture assets have $distinct distinct hashes, not 4." >&2
  echo "                 A mispaired pin would be invisible to every case below." >&2
  exit 1
fi
for t in $TARGETS; do
  if cmp -s "$WORK/assets/$t.tar.gz" "$WORK/assets-replaced/$t.tar.gz"; then
    echo "HARNESS FAILURE: the replaced fixture for $t is byte-identical to the original." >&2
    echo "                 The asset-replacement cases would test nothing." >&2
    exit 1
  fi
done

# A curl that succeeds, serving each url the fixture asset for the target named in
# that url's filename. Both the updater's download loop and the verification it
# runs afterwards fetch through this, so what gets pinned and what gets checked are
# the same bytes - unless a case asks for the switch, which serves the second set
# from call <switch_after> + 1 on. That is a release asset replaced in the window
# between pinning and verifying.
write_curl_stub() { # write_curl_stub <stubdir> <assetdir> [switch_after] [assetdir2]
  # Every path the stub needs is written to a file beside it, never interpolated
  # into its text. A quoted path inside a generated script is a syntax error the
  # moment the path contains an apostrophe, which a TMPDIR can, and the case then
  # fails for the harness rather than for what it tests.
  printf '%s\n' "$2" > "$1/curl.assets"
  printf '%s\n' "${4:-$2}" > "$1/curl.assets-after"
  printf '%s\n' "${3:-0}" > "$1/curl.switch-after"
  cat > "$1/curl" <<'STUB'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *)  url="$1"; shift ;;
  esac
done
[ -n "$out" ] && [ -n "$url" ] || { echo "stub curl: no -o or no url in: $*" >&2; exit 2; }
target="$(printf '%s' "$url" | sed -e 's|.*/rumdl-v[0-9][0-9.]*-||' -e 's|\.tar\.gz$||')"
here="$(dirname "$0")"
count="$here/curl.count"
n=$(( $(cat "$count" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$count"
switch="$(cat "$here/curl.switch-after")"
dir="$(cat "$here/curl.assets")"
if [ "$switch" != 0 ] && [ "$n" -gt "$switch" ]; then dir="$(cat "$here/curl.assets-after")"; fi
[ -f "$dir/$target.tar.gz" ] || { echo "stub curl: no fixture asset for target '$target'" >&2; exit 22; }
cat "$dir/$target.tar.gz" > "$out"
STUB
  chmod +x "$1/curl"
}

write_gh_stub() { # write_gh_stub <stubdir> <attestation-exit>
  cat > "$1/gh" <<STUB
#!/bin/sh
# \`gh auth status\` is checked once up front, and has to succeed here or the run
# stops on "gh is not authenticated" instead of reaching the provenance check the
# case is about.
case "\$1 \$2" in
  "auth status") exit 0 ;;
esac
if [ '$2' = '0' ]; then exit 0; fi
echo "no attestation matching the signer workflow" >&2
echo "rvben/rumdl/.github/workflows/release.yml was expected" >&2
exit 1
STUB
  chmod +x "$1/gh"
}

# Only verify-formula.sh's architecture check calls `file`, and the fixture
# binaries are shell scripts, so the real file(1) would report "POSIX shell
# script" and fail that check for a reason that has nothing to do with the updater
# under test. Each fixture names its target inside; this maps that back to the
# string verify-formula.sh expects for the branch it sits in, which keeps the
# check's pairing intact - an asset served into the wrong branch still fails.
write_file_stub() { # write_file_stub <stubdir>
  cat > "$1/file" <<'STUB'
#!/bin/sh
path=""
for a in "$@"; do path="$a"; done
t="$(sed -n 's/^# fixture binary for \(.*\)$/\1/p' "$path" 2>/dev/null | head -1)"
case "$t" in
  x86_64-apple-darwin)        echo "Mach-O 64-bit executable x86_64" ;;
  aarch64-apple-darwin)       echo "Mach-O 64-bit executable arm64" ;;
  x86_64-unknown-linux-musl)  echo "ELF 64-bit LSB executable, x86-64, statically linked" ;;
  aarch64-unknown-linux-musl) echo "ELF 64-bit LSB executable, ARM aarch64, statically linked" ;;
  *) echo "stub file: no fixture target marker in $path" >&2; exit 1 ;;
esac
STUB
  chmod +x "$1/file"
}

stubs_attested()   { write_curl_stub "$1" "$WORK/assets";   write_gh_stub "$1" 0; write_file_stub "$1"; }
stubs_unattested() { write_curl_stub "$1" "$WORK/assets";   write_gh_stub "$1" 1; write_file_stub "$1"; }
# Four downloads to pin, then verification downloads all four again: this serves
# the second set from the fifth call on.
stubs_replaced_midway() { write_curl_stub "$1" "$WORK/assets" 4 "$WORK/assets-replaced"
  write_gh_stub "$1" 0; write_file_stub "$1"; }

assert_formula_untouched() { # <casedir>
  if ! cmp -s "$1/Formula/rumdl.rb" "$1/original.rb"; then
    echo "the formula was modified; a refusal has to leave it byte-identical"
    diff "$1/original.rb" "$1/Formula/rumdl.rb" | head -6
    return 1
  fi
}

# The whole point of the updater, asserted directly: every sha256 in the written
# formula is the hash of the archive the url directly above it fetches, and that
# url names the expected version. Pairing by position, because that adjacency is
# what Homebrew acts on.
assert_pins_match_fixtures() { # <casedir> <assetdir> <version>
  local pairs url pin target want bad=0 count=0
  pairs="$(awk '
    /^[[:space:]]*url "/ {
      if (match($0, /"https:[^"]*"/)) u = substr($0, RSTART + 1, RLENGTH - 2)
      next
    }
    /^[[:space:]]*sha256 "/ {
      match($0, /"[^"]*"/)
      print u "\t" substr($0, RSTART + 1, RLENGTH - 2)
    }
  ' "$1/Formula/rumdl.rb")"
  while IFS="$(printf '\t')" read -r url pin; do
    [ -n "$url" ] || continue
    count=$((count + 1))
    case "$url" in
      *"/v$3/rumdl-v$3-"*.tar.gz) ;;
      *) echo "url does not name v$3 in both its path and its filename: $url"; bad=1; continue ;;
    esac
    target="${url##*-v"$3"-}"
    target="${target%.tar.gz}"
    if [ ! -f "$2/$target.tar.gz" ]; then
      echo "no fixture asset exists for target '$target', from url $url"
      bad=1
      continue
    fi
    want="$(sha256_of_file "$2/$target.tar.gz")"
    if [ "$pin" != "$want" ]; then
      echo "a pin is not the hash of the archive its own url fetched"
      echo "  url:      $url"
      echo "  pinned:   $pin"
      echo "  fetched:  $want"
      bad=1
    fi
  done <<PAIRS
$pairs
PAIRS
  if [ "$count" != "4" ]; then
    echo "expected 4 url/sha256 pairs in the written formula, found $count"
    bad=1
  fi
  return "$bad"
}

assert_pinned_to_other()   { assert_pins_match_fixtures "$1" "$WORK/assets" "$OTHER_VERSION"; }
assert_repinned_to_cur()   { assert_pins_match_fixtures "$1" "$WORK/assets" "$CUR_VERSION"; }

# ---------------------------------------------------------------------------
# The tap-clone refresh in validate-formula.sh, which is the one place in this
# repository that destroys data: `git reset --hard` followed by `git clean -qfd`
# inside the clone `brew edit rvben/rumdl/rumdl` opens, where a contributor's
# experiment plausibly lives. What permits that pair to run is a check three lines
# above it, and that check was wrong until today - a failed `rev-list` was coerced
# to `0`, turning "I could not tell" into "there is nothing to lose".
#
# So these cases use real git repositories rather than stubs for the part under
# test: a committed checkout, a clone of it, and an assertion afterwards about what
# the clone still holds. Only the surroundings are stubbed, because reaching the
# refresh otherwise means Homebrew, the network, and this suite calling itself.
# ---------------------------------------------------------------------------

mkdir -p "$WORK/nohooks"
# Pinned config rather than the machine's: a global commit.gpgsign, a templateDir
# that copies hooks, or a missing user.name each turn a scratch commit into a
# harness failure that reads as a guard failure.
scratch_git() {
  git -c init.templateDir= -c core.hooksPath="$WORK/nohooks" -c commit.gpgsign=false \
      -c user.name=guard -c user.email=guard@example.invalid "$@"
}

setup_tap_clone() { # setup_tap_clone <casedir>
  local d="$1"
  # validate-formula.sh runs both of these before it reaches the refresh. The real
  # verify-formula.sh needs the network, and the real test-guards.sh is this script.
  printf '#!/bin/sh\nexit 0\n' > "$d/scripts/test-guards.sh"
  printf '#!/bin/sh\nexit 0\n' > "$d/scripts/verify-formula.sh"
  chmod +x "$d/scripts/test-guards.sh" "$d/scripts/verify-formula.sh"
  scratch_git init -q "$d" || return 1
  scratch_git -C "$d" add Formula scripts original.rb || return 1
  scratch_git -C "$d" commit -q -m "the tap at its first commit" || return 1
  scratch_git clone -q "$d" "$d/tap-clone" || return 1
  # The checkout moves on by one commit, so the refresh has something to do and
  # "the clone was left alone" and "the clone was refreshed" are different states.
  printf 'a later change in the checkout\n' > "$d/later.txt" || return 1
  scratch_git -C "$d" add later.txt || return 1
  scratch_git -C "$d" commit -q -m "the tap moved on by one commit" || return 1
}

setup_clone_clean() { setup_tap_clone "$1"; }

setup_clone_dirty() {
  setup_tap_clone "$1" || return 1
  printf '# an uncommitted edit, as brew edit would leave\n' >> "$1/tap-clone/Formula/rumdl.rb"
}

# One commit the checkout does not have, and nothing uncommitted. This is the shape
# that the coerced rev-list destroyed: `dirty` empty and `ahead` read as 0 means
# both refusal branches are skipped and reset --hard runs.
setup_clone_ahead() {
  setup_tap_clone "$1" || return 1
  printf 'a local experiment\n' > "$1/tap-clone/experiment.txt" || return 1
  scratch_git -C "$1/tap-clone" add experiment.txt || return 1
  scratch_git -C "$1/tap-clone" commit -q -m "an experiment only the clone has" || return 1
  scratch_git -C "$1/tap-clone" rev-parse HEAD > "$1/clone-head.txt"
}

write_brew_stub() { # write_brew_stub <stubdir> <clonepath>
  # The clone's path is handed over in a file beside the stub, for the reason
  # write_curl_stub gives: interpolating it would break the stub on an apostrophe.
  printf '%s\n' "$2" > "$1/brew.repository"
  cat > "$1/brew" <<'STUB'
#!/bin/sh
case "$1" in
  tap)          echo rvben/rumdl ;;
  --repository) cat "$(dirname "$0")/brew.repository" ;;
  # Empty, so the `brew trust` call is skipped rather than stubbed into a
  # success it never had.
  commands)     ;;
  # audit and style are not what these cases are about; they must not be the
  # reason one fails.
  *)            ;;
esac
exit 0
STUB
  chmod +x "$1/brew"
}

# A git that works, except that it cannot count commits - a corrupt clone, an
# unreadable object, a FETCH_HEAD that never landed. The real path is baked in so
# the stub cannot recurse into itself.
write_git_stub_no_rev_list() { # write_git_stub_no_rev_list <stubdir>
  local real
  real="$(command -v git)" || return 1
  printf '%s\n' "$real" > "$1/git.real"
  cat > "$1/git" <<'STUB'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = rev-list ]; then
    echo "fatal: bad object FETCH_HEAD" >&2
    exit 128
  fi
done
exec "$(cat "$(dirname "$0")/git.real")" "$@"
STUB
  chmod +x "$1/git"
}

# The two linters are stubbed to say nothing: validate-formula.sh runs both before
# the refresh, and a real lint finding in an unrelated script would fail these
# cases for a reason that has nothing to do with them. The comment deliberately
# does not open with the name of the first one, which shellcheck would read as a
# malformed directive and stop parsing the rest of this file at.
write_validator_stubs() { # write_validator_stubs <stubdir>
  local t
  for t in shellcheck actionlint; do
    printf '#!/bin/sh\nexit 0\n' > "$1/$t"
    chmod +x "$1/$t"
  done
}

stubs_validator()             { write_validator_stubs "$1"; write_brew_stub "$1" "${1%/stub}/tap-clone"; }
stubs_validator_no_rev_list() { stubs_validator "$1"; write_git_stub_no_rev_list "$1"; }

assert_clone_refreshed() { # <casedir>
  local want got
  want="$(scratch_git -C "$1" rev-parse HEAD)"
  got="$(scratch_git -C "$1/tap-clone" rev-parse HEAD)"
  if [ "$want" != "$got" ]; then
    echo "the tap clone was not moved to the checkout's HEAD, so the brew checks"
    echo "below it would read a different formula than the one being validated"
    echo "  checkout: $want"
    echo "  clone:    $got"
    return 1
  fi
}

assert_clone_kept_its_commit() { # <casedir>
  local want got
  want="$(cat "$1/clone-head.txt" 2>/dev/null)"
  got="$(scratch_git -C "$1/tap-clone" rev-parse HEAD)"
  if [ -z "$want" ]; then
    echo "harness: no recorded clone HEAD to compare against"
    return 1
  fi
  if [ "$want" != "$got" ]; then
    echo "the clone's own commit was destroyed by reset --hard"
    echo "  it was at: $want"
    echo "  now at:    $got"
    return 1
  fi
}

assert_clone_still_dirty() { # <casedir>
  if [ -z "$(scratch_git -C "$1/tap-clone" status --porcelain)" ]; then
    echo "the clone's uncommitted changes were discarded"
    return 1
  fi
}

pass=0
fail=0

# case <name> <expect_exit|any> <expect_substring> <script> [args...] -- reads the
# mutated formula on stdin.
case_run() {
  local name="$1" want_code="$2" want_text="$3" script="$4"; shift 4
  local dir="$WORK/case-$((pass + fail + 1))"
  mkdir -p "$dir/Formula" "$dir/scripts" "$dir/stub"
  cat > "$dir/Formula/rumdl.rb"
  # Kept so a case can assert the formula came out exactly as it went in, which is
  # what every refusal in update-formula.sh actually promises.
  cp "$dir/Formula/rumdl.rb" "$dir/original.rb"
  cp scripts/verify-formula.sh scripts/update-formula.sh scripts/validate-formula.sh "$dir/scripts/"
  chmod +x "$dir/scripts"/*.sh

  # Whatever the case needs on disk before the script runs: a git repository and a
  # clone of it, for the cases about the tap-clone refresh. A failure here is the
  # harness's, not the guard's, so it stops the run rather than being counted.
  if [ -n "${CASE_SETUP:-}" ]; then
    if ! "$CASE_SETUP" "$dir" > "$dir/setup.log" 2>&1; then
      echo "HARNESS FAILURE: the setup for '$name' failed, so the case would" >&2
      echo "                 report the guard as broken. Fix the setup." >&2
      sed 's/^/                 /' "$dir/setup.log" >&2
      exit 1
    fi
  fi

  # A case may install stubs of its own - a curl that succeeds, a gh that does or
  # does not attest, a git that cannot count commits - ahead of the deliberately
  # failing defaults.
  if [ -n "${CASE_STUBS:-}" ]; then
    "$CASE_STUBS" "$dir/stub"
  fi

  local out code
  out="$(cd "$dir" && PATH="$dir/stub:$PATH" "./scripts/$script" "$@" 2>&1)"
  code=$?

  local why=""
  if [ "$want_code" != "any" ] && [ "$code" != "$want_code" ]; then
    why="expected exit $want_code, got $code"
  elif ! printf '%s' "$out" | grep -qF -- "$want_text"; then
    why="expected message not found: $want_text"
  fi

  # An exit code and a message say the guard fired. They do not say what it left
  # on disk, and for the updater that is the part that matters: a refusal that
  # rewrote the formula anyway would pass a code-and-message check.
  if [ -z "$why" ] && [ -n "${CASE_ASSERT:-}" ]; then
    local detail
    if ! detail="$("$CASE_ASSERT" "$dir" 2>&1)"; then
      why="$detail"
    fi
  fi
  CASE_SETUP=""
  CASE_STUBS=""
  CASE_ASSERT=""

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

echo "Guard tests (offline; downloads stubbed with local fixture assets)"
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

# 13-17. The updater past its structural checks, where what gets pinned is
#    actually decided. Downloads succeed from here on, so ALLOW_UNATTESTED must go:
#    leaving it exported would skip the provenance loop in every case below,
#    including the one whose whole subject is provenance.
unset ALLOW_UNATTESTED

# 13. The positive control for the updater, and the counterpart to case 1. A
#     script that refused every version, or wrote hashes in the wrong order, or
#     wrote the first hash into all four pins, passes cases 10-12 and 14-17 and
#     fails only here.
CASE_STUBS=stubs_attested
CASE_ASSERT=assert_pinned_to_other
case_run "a full update pins each url to the bytes that url fetched" 0 \
  "All 4 pins match the artifacts their urls fetch, at version $OTHER_VERSION" \
  update-formula.sh "$OTHER_VERSION" < "$FORMULA"

# 14. An asset that downloads cleanly and carries no build provenance. The hash
#     would be perfectly self-consistent - it is the hash of what the url served -
#     which is exactly why the attestation is checked before pinning rather than
#     the hash being taken as sufficient.
CASE_STUBS=stubs_unattested
CASE_ASSERT=assert_formula_untouched
case_run "an asset with no build provenance is refused, not pinned" 1 \
  "has no valid build provenance from rvben/rumdl" \
  update-formula.sh "$OTHER_VERSION" < "$FORMULA"

# 15. The v0.2.76 case itself: the formula already names this version, and the
#     published assets now hash differently. Every pin computed here is genuine
#     and attested, so nothing else in the chain objects - this guard is the only
#     thing that turns "the release was re-run" into a decision rather than a
#     silent change of what users install under a version they already have.
CASE_STUBS=stubs_attested
CASE_ASSERT=assert_formula_untouched
case_run "the same version with changed assets needs ALLOW_REPIN" 1 \
  "the assets for v$CUR_VERSION have changed since the formula was pinned" \
  update-formula.sh "$CUR_VERSION" < "$FORMULA"

# 16. And the escape hatch works, so the guard above is a gate rather than a dead
#     end. Re-pins the version the formula already names to the assets published
#     now, which is what the operator asked for.
export ALLOW_REPIN=1
CASE_STUBS=stubs_attested
CASE_ASSERT=assert_repinned_to_cur
case_run "ALLOW_REPIN=1 re-pins the version already named" 0 \
  "re-pinning v$CUR_VERSION to the assets published now" \
  update-formula.sh "$CUR_VERSION" < "$FORMULA"
unset ALLOW_REPIN

# 17. An asset replaced between pinning and verifying: the four downloads that get
#     pinned succeed, and the four the verification makes return different bytes.
#     The formula has already been rewritten by then, so the requirement is not
#     just that the run fails but that it leaves the working tree as it found it.
#     Without the restore, the next thing to read the formula - including the
#     commit step in update-formula.yml - takes those unverified pins as current.
CASE_STUBS=stubs_replaced_midway
CASE_ASSERT=assert_formula_untouched
case_run "a verification failure after the write restores the formula" 1 \
  "was restored to its previous contents" \
  update-formula.sh "$OTHER_VERSION" < "$FORMULA"

# 18-21. validate-formula.sh's tap-clone refresh: the only data-destroying pair of
#    commands in this repository, and the check that permits them. Each case gets a
#    real checkout and a real clone of it, and each asserts what the clone still
#    holds afterwards - the exit code says the guard fired, not that the work
#    survived.

# 18. The positive control, and the reason the refresh exists at all: `brew tap
#     --force` on an already-tapped name does nothing, so without this the brew
#     checks would read whatever commit the clone happened to be on.
CASE_SETUP=setup_clone_clean
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_refreshed
case_run "a clean tap clone is moved to the checkout's HEAD" 0 \
  "tap clone now at" validate-formula.sh < "$FORMULA"

# 19. Uncommitted changes in the clone, which is exactly what `brew edit
#     rvben/rumdl/rumdl` leaves behind.
CASE_SETUP=setup_clone_dirty
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_still_dirty
case_run "a tap clone with uncommitted changes is not discarded" 1 \
  "holds work this would destroy" validate-formula.sh < "$FORMULA"

# 20. A commit the checkout does not have. Nothing shows as dirty, so only the
#     ahead-count sees it.
CASE_SETUP=setup_clone_ahead
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_kept_its_commit
case_run "a tap clone holding its own commit is not reset" 1 \
  "commit(s) not in" validate-formula.sh < "$FORMULA"

# 21. And the ahead-count failing to answer. This is the one that was wrong: a
#     `rev-list` that could not run was coerced to 0, which with a clean worktree
#     skipped both refusals and ran reset --hard on the very commits it could not
#     count. The assertion is that the clone's own commit is still there, so this
#     case fails against the previous version of the script rather than merely
#     asserting the new message.
CASE_SETUP=setup_clone_ahead
CASE_STUBS=stubs_validator_no_rev_list
CASE_ASSERT=assert_clone_kept_its_commit
case_run "a tap clone whose commits cannot be counted is not reset" 1 \
  "could not count commits" validate-formula.sh < "$FORMULA"

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) guard tests"
  exit 1
fi
echo "All $pass guard tests pass."
