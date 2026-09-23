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
# Two-sided, deliberately. Two cases require a correct run to succeed: that the
# unmodified formula clears every structural check and reaches the download stage,
# and that a full update pins each url to the bytes that url fetched. Without them,
# a script that rejected everything would pass this suite.
#
# Cases are referred to by name, never by number. The numbers here drifted twice
# (the version cases were labelled 10-12 while running as 12-14, and the last
# comment said 26 for case 27), which sends someone diagnosing a failure to the
# wrong fixture. The harness counts the cases and names their work directories,
# so that is where a case's number lives.
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

# An explicit template, because BSD `mktemp -d` with no template ignores TMPDIR
# entirely and answers under /var/folders - measured on macOS 25. That makes the
# filesystem the cases run on unchoosable, and one case below turns on whether that
# filesystem folds case, so the branch a Linux runner takes could not be exercised
# here at all.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rumdl-guards.XXXXXXXX")"
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

# One case turns on whether this filesystem folds case: an ignored `Notes.md` and a
# tracked `notes.md` are one file on macOS and two on the Linux runner, so the
# collision it tests exists on one and not the other. Hardcoding either answer makes
# the case wrong on the other platform, and skipping it there would leave the suite
# silently thinner where it runs most often. So the filesystem is asked, here, once,
# and the case takes its expectation from the answer - which gives the case-folding
# platform a refusal to assert and the case-sensitive one the useful opposite: that
# two files differing only in case are NOT mistaken for a collision.
: > "$WORK/CaseProbe"
if [ -e "$WORK/caseprobe" ]; then
  FS_FOLDS_CASE=1
else
  FS_FOLDS_CASE=0
fi
rm -f "$WORK/CaseProbe"
# Kept when the run failed, deleted when it passed. Everything a real failure has
# to be diagnosed from is in the case directories - the formula that went in, the
# one that came out, the generated stubs, and the run's full output in out.txt -
# and deleting them left only the excerpt printed above, so anything the excerpt
# did not cover could only be recovered by editing this file and running it again.
# The excerpt names the path, so the path has to still be there.
cleanup() { # cleanup <exit code>
  if [ "${1:-0}" != 0 ]; then
    echo
    echo "The cases' formulae, stubs and full output are kept in $WORK"
    return
  fi
  rm -rf "$WORK"
}
trap 'cleanup $?' EXIT

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

# The pair for the backwards-move case, and not just any older-newer pair. The
# updater decides with `sort -V`, so plain `sort` has to disagree about these two
# or the case passes with the -V dropped: 0.1.0 against 0.2.77 is ordered the same
# way by both, and that left the case vacuous.
#
# The pair is synthesized, not derived from whatever version the tap is on. For a
# current version like 0.2.9 NO older version exists that plain `sort` ranks above
# it, so deriving the pair made the suite abort - turning CI red on a routine
# version bump, which is the same defect this file warns about ten lines up. The
# case gets its own formula claiming BACK_VERSION instead.
BACK_VERSION=9.8.77
OLDER_VERSION=9.8.8
if [ "$(printf '%s\n%s\n' "$BACK_VERSION" "$OLDER_VERSION" | sort | tail -1)" != "$OLDER_VERSION" ] ||
   [ "$(printf '%s\n%s\n' "$BACK_VERSION" "$OLDER_VERSION" | sort -V | tail -1)" != "$BACK_VERSION" ]; then
  echo "HARNESS FAILURE: v$OLDER_VERSION must be older than v$BACK_VERSION by version" >&2
  echo "                 and higher as text, or the backwards-move case passes" >&2
  echo "                 whether or not the updater sorts by version, which is the" >&2
  echo "                 whole of what it tests." >&2
  exit 1
fi

# The line verify-formula.sh prints when every structural check has passed and it
# is about to start downloading. Written once and used by both the case that
# requires it and the cases that require its absence, so the two cannot drift
# apart: if this message changes, the positive control fails immediately rather
# than the negative assertions quietly becoming vacuous.
DOWNLOAD_MARKER="Verifying $FORMULA at version"

# The structural checks in verify-formula.sh all run BEFORE the first download,
# and every one of them exits 1. So does a run that reaches the download loop,
# because the default stubs have no curl that succeeds - which means an exit code
# of 1 is no evidence at all that the check under test is what stopped the run.
# Deleting the flag assignment from a check while leaving its `echo` in place
# satisfied both the code and the message. What separates them is the marker: a
# structural refusal must not reach the download stage.
# Some mutations would also be refused by a check further down, which exits 1
# before the download stage as well - so the marker alone still cannot attribute
# the refusal. What separates them is that a backstop announces itself: it prints
# its own message, and a correct run never reaches it. CASE_FORBID lists the
# messages that must therefore stay absent, one per line.
CASE_FORBID=""

assert_refused_before_download() { # <casedir>
  if grep -qF -- "$DOWNLOAD_MARKER" "$1/out.txt"; then
    echo "the message was printed, but the run went on to the download stage, so"
    echo "the check did not stop it and the exit code came from a failed download:"
    sed 's/^/  /' "$1/out.txt" | head -8
    return 1
  fi
  [ -n "${CASE_FORBID:-}" ] || return 0
  local pat
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    if grep -qF -- "$pat" "$1/out.txt"; then
      echo "the run also printed the message of a later check:"
      echo "  $pat"
      echo "which refuses this formula on its own, so the case does not show that"
      echo "the check it names is what stopped the run. A correct run never gets"
      echo "this far."
      return 1
    fi
  done <<EOF
$CASE_FORBID
EOF
}

# The guard against a mutation that matched nothing, which is the failure the
# version and hash above are read from the formula to avoid: a sed or python
# program whose pattern no longer matches produces the formula unchanged, and a
# case fed an unchanged formula is testing nothing while blaming the guard for it.
assert_mutated() { # assert_mutated <file>
  if cmp -s "$1" "$FORMULA"; then
    echo "HARNESS FAILURE: the mutation for the next case changed nothing." >&2
    echo "                 It would test an unmodified formula and report the" >&2
    echo "                 guard as broken. Fix the mutation, not the guard." >&2
    exit 1
  fi
}

# The second bound for the provenance case whose stub attests the first asset and
# not the second. Exit 1 and the refusal message are satisfied by refusing EITHER
# asset, and a provenance check whose sense is inverted refuses the attested one -
# so the case must also show that the attested asset was accepted. Exactly one
# asset clears provenance before the refusal, and a run that refused asset 1
# clears none.
assert_first_asset_cleared_provenance() { # <casedir>
  assert_formula_untouched "$1" || return 1
  local oks
  oks="$(grep -c 'provenance ok' "$1/out.txt")"
  if [ "$oks" != 1 ]; then
    echo "expected the attested asset to clear provenance and the next one to be"
    echo "refused, but $oks assets cleared it - so the refusal is not evidence that"
    echo "provenance is being read the right way round:"
    sed 's/^/  /' "$1/out.txt" | head -12
    return 1
  fi
}

# The second bound for the pin-format case. The check sits inside the download
# loop, so "exit 1" proves nothing on its own: a run that never downloaded
# anything exits 1 too. Requiring the other three assets to have verified shows
# the loop ran, and requiring exactly one failure shows the placeholder is what
# stopped it.
assert_only_the_pin_format_failed() { # <casedir>
  local oks fails
  oks="$(grep -c '^ok    ' "$1/out.txt")"
  fails="$(grep -c '^FAIL  ' "$1/out.txt")"
  if [ "$oks" != 3 ] || [ "$fails" != 1 ]; then
    echo "expected the other three assets to verify and one to fail, got $oks ok and"
    echo "$fails FAIL - so this case does not show that the pin's format is what"
    echo "failed the run:"
    sed 's/^/  /' "$1/out.txt" | head -12
    return 1
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
#
# GIT_TEMPLATE_DIR is in the list for a different reason: the scratch repository
# below already pins `init.templateDir=`, and the environment variable overrides
# that config rather than being overridden by it. A template carrying an
# `info/exclude` that names Formula, scripts or original.rb then makes `git add`
# refuse the fixture files it just wrote, and the suite stops at the first
# tap-clone case with a harness failure.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM \
      GIT_TEMPLATE_DIR
#
# The scripts under test read their escape hatches from the environment, and each
# one turns a refusal that a case asserts into a deliberate proceed. A case must
# not depend on whether the caller happened to export one; the case that is about
# a hatch exports it itself.
unset ALLOW_UNATTESTED ALLOW_REPIN ALLOW_DOWNGRADE DISCARD_TAP_CLONE

CASE_SETUP=""
CASE_STUBS=""
CASE_ASSERT=""
CASE_ENV=""

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

write_gh_stub() { # write_gh_stub <stubdir>
  # The workflow the attestation must be signed by, written beside the stub rather
  # than interpolated into it, for the reason write_curl_stub gives. This is the
  # value the updater is supposed to ask for; a stub that accepted any value let
  # the updater ask for a workflow nobody publishes, which refuses every real
  # asset at release time while all 25 cases passed.
  printf '%s\n' "rvben/rumdl/.github/workflows/release.yml" > "$1/gh.signer"
  cat > "$1/gh" <<'STUB'
#!/bin/sh
# `gh auth status` is checked once up front, and has to succeed here or the run
# stops on "gh is not authenticated" instead of reaching the provenance check the
# case is about.
case "$1 $2" in
  "auth status") exit 0 ;;
esac
want="$(cat "$(dirname "$0")/gh.signer")"
got=""
prev=""
for a in "$@"; do
  [ "$prev" = "--signer-workflow" ] && got="$a"
  prev="$a"
done
if [ "$got" != "$want" ]; then
  echo "no attestation matching the signer workflow" >&2
  echo "this stub attests $want; the run asked for '$got'" >&2
  exit 1
fi
exit 0
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

stubs_attested()   { write_curl_stub "$1" "$WORK/assets";   write_gh_stub "$1"; write_file_stub "$1"; }

# A gh that attests the FIRST asset and no other. The release being pinned has
# four assets and the updater is a loop, so "provenance is checked" and "the first
# asset's provenance is checked" are different claims that a stub refusing every
# asset cannot separate: the loop stops on asset 1 either way. This one is refused
# on asset 2, so an updater that checked only the first would sail past it.
write_gh_stub_first_only() { # <stubdir>
  printf '%s\n' "rvben/rumdl/.github/workflows/release.yml" > "$1/gh.signer"
  cat > "$1/gh" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "auth status") exit 0 ;;
esac
here="$(dirname "$0")"
# The same requirement as the plain stub: this one attests the first asset, and
# only when asked for the workflow that actually signs rumdl's releases.
want="$(cat "$here/gh.signer")"
got=""
prev=""
for a in "$@"; do
  [ "$prev" = "--signer-workflow" ] && got="$a"
  prev="$a"
done
if [ "$got" != "$want" ]; then
  echo "no attestation matching the signer workflow" >&2
  echo "this stub attests $want; the run asked for '$got'" >&2
  exit 1
fi
n=$(( $(cat "$here/gh.attest.count" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$here/gh.attest.count"
[ "$n" = 1 ] && exit 0
echo "no attestation matching the signer workflow" >&2
echo "this stub attests the first asset only; asset $n is not attested" >&2
exit 1
STUB
  chmod +x "$1/gh"
}

# A gh that answers as GitHub would for an asset carrying a real attestation from
# some OTHER workflow: asked without --signer-workflow it finds one and succeeds,
# asked with it finds none and fails. So the flag, not the presence of any
# attestation at all, is what has to be doing the work.
write_gh_stub_wrong_signer() { # <stubdir>
  cat > "$1/gh" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "auth status") exit 0 ;;
esac
for a in "$@"; do
  if [ "$a" = "--signer-workflow" ]; then
    echo "no attestation matching the signer workflow" >&2
    echo "an attestation exists, but it was not signed by that workflow" >&2
    exit 1
  fi
done
exit 0
STUB
  chmod +x "$1/gh"
}

stubs_attested_first_only() { write_curl_stub "$1" "$WORK/assets"
  write_gh_stub_first_only "$1"; write_file_stub "$1"; }
stubs_attested_wrong_signer() { write_curl_stub "$1" "$WORK/assets"
  write_gh_stub_wrong_signer "$1"; write_file_stub "$1"; }
# Four downloads to pin, then verification downloads all four again: this serves
# the second set from the fifth call on.
stubs_replaced_midway() { write_curl_stub "$1" "$WORK/assets" 4 "$WORK/assets-replaced"
  write_gh_stub "$1"; write_file_stub "$1"; }
# For the verifier rather than the updater: downloads succeed and `file` answers,
# and there is no gh stub because verify-formula.sh checks no attestations.
stubs_verifier() { write_curl_stub "$1" "$WORK/assets"; write_file_stub "$1"; }

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

# A copy of the formula with every pin replaced by the hash of the fixture asset
# its own url fetches, so verify-formula.sh can be made to SUCCEED offline.
#
# Needed because the committed pins are the hashes of rumdl's real published
# assets, which no local fixture can serve: every case that runs the verifier
# against the committed formula therefore ends in a hash mismatch, and exits 1
# whatever the check under test decided. That is invisible for the structural
# checks, which refuse before the first download - but the pin-format check runs
# inside the download loop, and deleting the flag it sets left its case passing on
# a failure that came from curl.
fixture_pinned_formula() { # fixture_pinned_formula <outfile>
  local t
  : > "$WORK/fixture-pins.tsv" || return 1
  for t in $TARGETS; do
    printf '%s\t%s\n' "$t" "$(sha256_of_file "$WORK/assets/$t.tar.gz")" >> "$WORK/fixture-pins.tsv"
  done
  pin_to_fixtures "$FORMULA" "$1" "$WORK/fixture-pins.tsv"
}

# The table of target -> fixture hash is passed as a FILE, not on stdin: the
# program itself arrives on stdin, through a quoted heredoc so its own quoting
# survives - it contains both kinds of quote, which no single-quoted `python3 -c`
# string can carry.
pin_to_fixtures() { # pin_to_fixtures <informula> <outfile> <tablefile>
  python3 - "$1" "$2" "$3" <<'PY'
import sys, re
table = dict(l.rstrip("\n").split("\t") for l in open(sys.argv[3]) if l.strip())
src, out = sys.argv[1], sys.argv[2]
t = open(src).read()
# Each url is followed by the sha256 Homebrew pairs with it, so walk the pairs in
# order and give each pin the hash of the asset that url actually serves.
pairs = re.findall(
    r'"https:[^"]*/rumdl-v[0-9.]+-([a-z0-9_]+-[a-z0-9.-]+)\.tar\.gz"\s*\n\s*sha256 "([0-9a-f]{64})"',
    t)
if len(pairs) != len(table):
    sys.exit(f"found {len(pairs)} url/sha256 pairs, expected {len(table)}")
for target, old in pairs:
    if target not in table:
        sys.exit(f"no fixture asset for target {target}")
    t = t.replace(f'sha256 "{old}"', f'sha256 "{table[target]}"', 1)
missing = [h for h in table.values() if h not in t]
if missing:
    sys.exit("a fixture hash did not reach the formula: " + ", ".join(missing))
open(out, "w").write(t)
PY
}

# ---------------------------------------------------------------------------
# The tap-clone refresh in validate-formula.sh, which is the one place in this
# repository that destroys data: it moves the clone `brew edit rvben/rumdl/rumdl`
# opens, where a contributor's experiment plausibly lives, onto the commit being
# validated. What permits that to run is the inventory above it, and that inventory
# was wrong until today - a failed `rev-list` was coerced to `0`, turning "I could
# not tell" into "there is nothing to lose".
#
# The commands have changed under these cases twice, which is why they assert states
# and not commands: `reset --hard` plus `clean -qfd` became `checkout
# --no-overwrite-ignore` with no clean at all, and every case below held. Where a
# comment names one, it is naming the version that produced the defect the case
# covers.
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
# core.excludesFile is pinned away for the same class of reason as the template:
# whether a fixture file can be committed must not depend on what the machine's
# global ignore file happens to name.
# The harness's own git. It builds the fixtures and it inspects them afterwards, so it
# must not run anything a fixture installed: a fixture that gives a clone a
# core.fsmonitor program or a hook is testing what validate-formula.sh does with it, and
# an assertion that trips it itself reports the harness's own side effect as the
# guard's. Measured: without the fsmonitor line the assertion's `rev-parse` and `status`
# ran the fixture's program, which rewrote the formula, and the case failed naming both
# the program and the dirty tree - while the script under test had suppressed it
# correctly. core.hooksPath is here for the same reason.
scratch_git() {
  git -c init.templateDir= -c core.excludesFile=/dev/null \
      -c core.hooksPath="$WORK/nohooks" -c core.fsmonitor=false \
      -c commit.gpgsign=false \
      -c user.name=guard -c user.email=guard@example.invalid "$@"
}

# Reading a tap clone's working tree, for the assertions. The same principle as the
# overrides above, one step further: the harness must not run what a fixture installed,
# and it must not be SENT where a fixture's config points either. A fixture that sets
# core.worktree redirects every worktree command in the clone, the assertions' included,
# so `status --porcelain` there describes the other directory. Measured: it reported
# ` M Formula/rumdl.rb` and ` D later.txt` - a correct account of the directory that was
# rightly left alone - and failed a case whose guard had worked.
#
# Only the worktree-level reads need this. HEAD comparisons are ref-level, the byte
# comparisons read files directly, and `ls-files -v` answers from the index.
clone_git() { # clone_git <casedir> <args...>
  local d="$1"; shift
  scratch_git -C "$d/tap-clone" --work-tree="$d/tap-clone" "$@"
}

setup_tap_clone() { # setup_tap_clone <casedir>
  local d="$1"
  # validate-formula.sh runs both of these before it reaches the refresh. The real
  # verify-formula.sh needs the network, and the real test-guards.sh is this script.
  printf '#!/bin/sh\nexit 0\n' > "$d/scripts/test-guards.sh"
  printf '#!/bin/sh\nexit 0\n' > "$d/scripts/verify-formula.sh"
  chmod +x "$d/scripts/test-guards.sh" "$d/scripts/verify-formula.sh"
  scratch_git init -q "$d" || return 1
  # -f on paths this function wrote itself, so no ignore rule from any source can
  # decide whether the fixture repository gets built.
  scratch_git -C "$d" add -f Formula scripts original.rb || return 1
  # A .gitignore the fixture wrote before calling this goes into the FIRST commit, so
  # the clone inherits it and a later commit in the checkout can remove it. That is the
  # one ignore rule .git/info/exclude cannot express: an uncommitted personal exclude is
  # not something a fetched commit can drop.
  if [ -f "$d/.gitignore" ]; then
    scratch_git -C "$d" add -f .gitignore || return 1
  fi
  scratch_git -C "$d" commit -q -m "the tap at its first commit" || return 1

  # The clone is a clone of `published`, not of the checkout, because that is the
  # real topology: the tap clone under `brew --repository` came from GitHub, and
  # the checkout is a separate clone of the same tap carrying the edit being
  # validated. Cloning it straight from the checkout made the clone's `origin` and
  # `$TAP_DIR` the same repository, so `fetch origin HEAD` and `fetch "$TAP_DIR"
  # HEAD` fetched identical objects and the case could not tell them apart - a
  # refresh from `origin` re-validates whatever is already published and never
  # sees the contributor's commit at all.
  scratch_git clone -q "$d" "$d/published" || return 1
  scratch_git clone -q "$d/published" "$d/tap-clone" || return 1

  # The checkout moves on by one commit, so the refresh has something to do and
  # "the clone was left alone" and "the clone was refreshed" are different states.
  # `published` stays behind at the first commit, which is what makes fetching
  # from the wrong place observable.
  #
  # That commit changes the FORMULA, not merely some file. What the refresh exists
  # to achieve is that the brew checks below it read THIS Formula/rumdl.rb out of
  # the clone's working tree; if the later commit left the formula alone, a refresh
  # that moved the ref without touching the working tree would be indistinguishable
  # from a correct one.
  printf '# the checkout moved on by one commit\n' >> "$d/Formula/rumdl.rb" || return 1
  printf 'a later change in the checkout\n' > "$d/later.txt" || return 1
  scratch_git -C "$d" add -f Formula/rumdl.rb later.txt || return 1
  scratch_git -C "$d" commit -q -m "the tap moved on by one commit" || return 1

  # Every refusal promises to leave the clone alone, and "alone" includes its
  # ref. Recorded here rather than per case so no refusal case can be written
  # without the comparison being available to it.
  scratch_git -C "$d/tap-clone" rev-parse HEAD > "$d/clone-head.txt" || return 1
}

setup_clone_clean() { setup_tap_clone "$1"; }

setup_clone_dirty() {
  setup_tap_clone "$1" || return 1
  printf '# an uncommitted edit, as brew edit would leave\n' >> "$1/tap-clone/Formula/rumdl.rb" || return 1
  # A copy of the edited file is kept, because the assertion has to require these
  # exact bytes back rather than "the clone is dirty". See assert_clone_still_dirty.
  cp "$1/tap-clone/Formula/rumdl.rb" "$1/clone-dirty-formula.rb" || return 1
}

# Dirt that is a file git is not tracking. These are where a contributor's experiment
# most often lives - a formula variant saved beside the real one is untracked, not
# modified - and CONTRIBUTING.md promises they stop the refresh, while every other
# case's dirt is a modified tracked file, which `status --porcelain
# --untracked-files=no` still reports. So a refresh that stopped asking about
# untracked files, or that deleted them before deciding whether it may, destroyed a
# contributor's unversioned work with every other case still passing.
setup_clone_untracked() {
  setup_tap_clone "$1" || return 1
  printf 'notes to myself, never committed\n' > "$1/tap-clone/experiment.md" || return 1
  mkdir -p "$1/tap-clone/scratch" || return 1
  printf 'and a whole untracked directory\n' > "$1/tap-clone/scratch/notes.md" || return 1
}

# One commit the checkout does not have, and nothing uncommitted. This is the shape
# that the coerced rev-list destroyed: `dirty` empty and `ahead` read as 0 means both
# refusal branches are skipped and the refresh runs over the clone's own commit.
setup_clone_ahead() {
  setup_tap_clone "$1" || return 1
  printf 'a local experiment\n' > "$1/tap-clone/experiment.txt" || return 1
  scratch_git -C "$1/tap-clone" add experiment.txt || return 1
  scratch_git -C "$1/tap-clone" commit -q -m "an experiment only the clone has" || return 1
  scratch_git -C "$1/tap-clone" rev-parse HEAD > "$1/clone-head.txt"
}

# The checkout's formula edited and not committed, which is the state anyone
# validating an edit locally is in. The pin check reads the working tree, the brew
# checks read a clone at HEAD, so the edit is not the formula brew audits,
# installs or tests - while every line the run prints says those checks passed.
setup_clone_uncommitted_formula() {
  setup_tap_clone "$1" || return 1
  printf '# an edit that was never committed\n' >> "$1/Formula/rumdl.rb" || return 1
}

# A second repository, for the case about GIT_DIR. `git -C <dir>` does not override
# GIT_DIR, so with one exported - the ordinary state inside any git hook - every
# git call in validate-formula.sh reads the repository GIT_DIR names rather than
# the one -C points at, including the commands that decide whether refreshing the tap
# clone would destroy work, immediately above the refresh that acts on the answer.
#
# The decoy is a clean clone of the checkout at its own HEAD, chosen so that the
# unprotected script produces a passing run rather than an error: nothing is
# dirty, the ahead-count is 0, both refusal branches are skipped, and the refresh
# lands on the decoy while the real tap clone stays at its old commit. The run
# then prints "tap clone now at" and a sha that matches the checkout, and every
# brew check below reads the formula nobody validated.
setup_clone_decoy_repo() {
  setup_tap_clone "$1" || return 1
  scratch_git clone -q "$1" "$1/decoy" || return 1
  scratch_git -C "$1/decoy" rev-parse HEAD > "$1/decoy-head.txt" || return 1
}

case_env_decoy_repo() { # <casedir>
  printf 'GIT_DIR=%s\n' "$1/decoy/.git"
  printf 'GIT_WORK_TREE=%s\n' "$1/decoy"
}

# The next three fixtures are all the same shape as the decoy: work that a refresh
# destroys, which the inventory in front of the refresh cannot see. Each one is
# reachable by exactly one of the two halves of the fix, so a case cannot pass on
# the strength of the other half.
#
# Untracked files, hidden by the clone's own config. Only an --untracked-files on
# the status command line overrides this; unsetting environment variables does
# nothing, because the setting is committed to the clone's .git/config.
setup_clone_untracked_suppressed_by_config() {
  setup_clone_untracked "$1" || return 1
  scratch_git -C "$1/tap-clone" config status.showUntrackedFiles no || return 1
}

# The same suppression arriving through the environment, which is how it reaches a
# script run from a hook or a wrapper. Both halves of the fix stop the deletion, so
# this case also requires the announcement, which only the unset produces.
setup_clone_untracked_suppressed_by_env() { setup_clone_untracked "$1"; }

case_env_suppress_untracked() { # <casedir>
  printf 'GIT_CONFIG_COUNT=1\n'
  printf 'GIT_CONFIG_KEY_0=status.showUntrackedFiles\n'
  printf 'GIT_CONFIG_VALUE_0=no\n'
}

# The fixtures below all hide a local edit from every list the inventory reads, and
# each records the path and the bytes it hid, for assert_clone_hidden_bytes_kept.
#
# An edit to a tracked file that git has been told not to stat. Neither `status` nor
# `diff --quiet HEAD` reports it, so only the index-flag check sees it.
#
# The marked path is scripts/verify-formula.sh rather than the formula, and that
# choice is the whole case. Measured, on both flags: when the fetched tree CHANGES the
# marked path the refresh aborts on its own, exit 1 with HEAD unmoved - so a case
# built that way passes on git's refusal and says nothing about the guard. When the
# fetched tree leaves the marked path alone the refresh exits 0 and moves HEAD, and
# only the guard stands between the contributor's hidden edit and a run that carries
# it into every brew check below. The checkout's later commit changes
# Formula/rumdl.rb and leaves scripts/ alone, so marking a script is what makes the
# guard the thing under test.
setup_clone_assume_unchanged_edit() {
  setup_tap_clone "$1" || return 1
  scratch_git -C "$1/tap-clone" update-index \
    --assume-unchanged scripts/verify-formula.sh || return 1
  printf '# a local edit git was told not to look for\n' \
    >> "$1/tap-clone/scripts/verify-formula.sh" || return 1
  printf '%s\n' scripts/verify-formula.sh > "$1/hidden-path" || return 1
  cp "$1/tap-clone/scripts/verify-formula.sh" "$1/hidden-bytes" || return 1
}

# skip-worktree on the formula, which loses no bytes at all and is worth refusing for
# the other reason. Measured: the refresh honours the flag, so the clone keeps the
# contributor's formula - and every brew check below then audits, installs and tests
# that file while the run reports on the formula under validation. Same hidden state,
# same refusal, opposite consequence: not destroyed work, but a validated formula
# nobody wrote.
#
# The clone is brought level with the checkout first, and that is what makes the case
# the one it claims to be. Measured, on both flags: when the fetched tree CHANGES the
# marked path the refresh aborts on its own with exit 1 - a run that dies confusingly,
# not a wrong one. The base fixture's later commit changes the formula, so written
# against it this case caught git's refusal rather than the guard, and the first
# version of it did exactly that. Level, the refresh has nothing to change for that
# path, the flag is honoured, and the brew checks read the contributor's formula while
# the run reports on ours.
setup_clone_skip_worktree_formula() {
  setup_tap_clone "$1" || return 1
  scratch_git -C "$1/tap-clone" fetch -q "$1" HEAD || return 1
  scratch_git -C "$1/tap-clone" reset -q --hard FETCH_HEAD || return 1
  # Re-recorded, because the clone is no longer at the commit setup_tap_clone saw and
  # every refusal case compares against this file.
  scratch_git -C "$1/tap-clone" rev-parse HEAD > "$1/clone-head.txt" || return 1
  scratch_git -C "$1/tap-clone" update-index --skip-worktree Formula/rumdl.rb ||
    return 1
  printf '# the clone keeps its own formula, whatever is fetched\n' \
    >> "$1/tap-clone/Formula/rumdl.rb" || return 1
  printf '%s\n' Formula/rumdl.rb > "$1/hidden-path" || return 1
  cp "$1/tap-clone/Formula/rumdl.rb" "$1/hidden-bytes" || return 1
}

# The next three fixtures are one shape in three forms: a path the FETCHED commit
# tracks, held in the clone as a locally created ignored file. Ignored files are
# absent from `status` and from `ls-files -v`, and nothing in the refresh deletes them,
# so for every other case they are correctly none of this script's business.
# This shape is different, and none of the inventory's lists can see it.
#
# Three forms rather than one because an exact-path comparison catches only the first,
# and each of the other two was measured to destroy the local bytes while every list
# read clean: a name that differs only in case, which is one file wherever the
# filesystem folds case, and a name that collides with an ancestor rather than with a
# name. Together they are the reason the refresh asks git about collisions instead of
# comparing path lists here.
#
# The ignore rule goes in the clone's own .git/info/exclude, which is where a
# personal, uncommitted ignore belongs and which --exclude-standard reads. A fresh
# clone has no .git/info at all, so the directory comes first.
clone_ignores() { # clone_ignores <casedir> <pattern>
  mkdir -p "$1/tap-clone/.git/info" || return 1
  printf '%s\n' "$2" >> "$1/tap-clone/.git/info/exclude" || return 1
}

# The exact form: ignored notes.md, fetched commit tracks notes.md.
setup_clone_ignored_tracked_upstream() {
  setup_tap_clone "$1" || return 1
  printf 'the fetched bytes, which this clone never asked for\n' > "$1/notes.md" ||
    return 1
  scratch_git -C "$1" add -f notes.md || return 1
  scratch_git -C "$1" commit -q -m "the tap starts tracking notes.md" || return 1
  clone_ignores "$1" notes.md || return 1
  printf 'MY PRIVATE NOTES\n' > "$1/tap-clone/notes.md" || return 1
  printf '%s\n' notes.md > "$1/hidden-path" || return 1
  cp "$1/tap-clone/notes.md" "$1/hidden-bytes" || return 1
}

# The case-folding form: ignored Notes.md, fetched commit tracks notes.md. Two
# different strings, and on macOS one file. The fixture is identical on both kinds of
# filesystem and only the expectation differs, so the case-sensitive platform runs it
# as the control it is: two files, no collision, refresh proceeds, bytes untouched.
setup_clone_ignored_case_collision() {
  setup_tap_clone "$1" || return 1
  printf 'the fetched bytes, which this clone never asked for\n' > "$1/notes.md" ||
    return 1
  scratch_git -C "$1" add -f notes.md || return 1
  scratch_git -C "$1" commit -q -m "the tap starts tracking notes.md" || return 1
  clone_ignores "$1" Notes.md || return 1
  printf 'MY PRIVATE NOTES\n' > "$1/tap-clone/Notes.md" || return 1
  # Recorded under the name the clone actually holds, which on a folding filesystem
  # is the one that already existed: git created notes.md, the open() found Notes.md.
  if [ -f "$1/tap-clone/Notes.md" ]; then
    printf '%s\n' Notes.md > "$1/hidden-path" || return 1
  else
    printf '%s\n' notes.md > "$1/hidden-path" || return 1
  fi
  cp "$1/tap-clone/$(cat "$1/hidden-path")" "$1/hidden-bytes" || return 1
}

# The ancestor form: ignored notes/private, fetched commit tracks a FILE named notes.
# Writing that file means removing the directory, and the directory holds work. No
# comparison of path strings matches here - `notes` and `notes/private` are different
# names - which is why this form escaped the intersection that caught the first.
setup_clone_ignored_dir_collision() {
  setup_tap_clone "$1" || return 1
  printf 'the fetched bytes, and it is a file, not a directory\n' > "$1/notes" ||
    return 1
  scratch_git -C "$1" add -f notes || return 1
  scratch_git -C "$1" commit -q -m "the tap starts tracking a file named notes" ||
    return 1
  clone_ignores "$1" 'notes/' || return 1
  mkdir -p "$1/tap-clone/notes" || return 1
  printf 'MY PRIVATE NOTES\n' > "$1/tap-clone/notes/private" || return 1
  printf '%s\n' notes/private > "$1/hidden-path" || return 1
  cp "$1/tap-clone/notes/private" "$1/hidden-bytes" || return 1
}

# The escape hatch's own shape: a tracked edit to the formula, which is what `brew edit
# rvben/rumdl/rumdl` leaves, and which the commit under validation always changes too.
# DISCARD_TAP_CLONE=1 says those go, so the run has to reach the fetched commit.
setup_clone_dirty_for_discard() { setup_clone_dirty "$1"; }

# The hatch crossed with the collision the refresh must never resolve by force. Both
# halves are needed for this to test anything: the tracked edit is what makes the hatch
# branch run at all, and the ignored file the fetched commit tracks is what must still be
# there afterwards. `checkout -f` would satisfy the hatch and destroy that file, so this
# case is what stands between the two and fails if anyone reaches for -f.
setup_clone_dirty_and_ignored_collision() {
  setup_clone_ignored_tracked_upstream "$1" || return 1
  printf '# an uncommitted edit, as brew edit would leave\n' >> "$1/tap-clone/Formula/rumdl.rb" || return 1
}

case_env_discard_tap_clone() { # <casedir>
  printf 'DISCARD_TAP_CLONE=1\n'
}

# A clone carrying its own post-checkout hook. Not a collision case: the point is that
# refreshing the clone must not EXECUTE anything the clone brought with it. `reset --hard`
# ran no hooks, so switching the refresh to `checkout` started running them, and a hook
# gets to act after the inventory has finished deciding what may be touched - it can edit
# the tracked formula the brew checks are about to read.
#
# The marker goes OUTSIDE the clone, so that nothing the refresh does to that working tree
# can remove the evidence, and so that a hook whose only effect was outside the clone is
# caught as well. Written with a relative path rather than by interpolating the case
# directory, for the reason write_brew_stub gives below - a path can contain an
# apostrophe - and because git runs a post-checkout hook from the top of the working
# tree, which makes `../hook-ran` the case directory.
# A file the clone holds under its OWN committed ignore rule, where the commit being
# validated drops that rule without tracking the path. Nothing in the inventory can see
# it: it is ignored while the inventory looks, and the collision check has nothing to
# refuse because the fetched commit does not track it. It becomes an ordinary untracked
# file the moment the refresh lands, which is what a `clean` after the refresh then
# deleted. So this case expects a successful refresh that leaves the file alone.
setup_clone_deignored_local_file() {
  # Written before setup_tap_clone, so it lands in the commit the clone inherits.
  printf 'notes.md\n' > "$1/.gitignore" || return 1
  setup_tap_clone "$1" || return 1
  # The commit under validation stops ignoring notes.md, and does not add it.
  : > "$1/.gitignore" || return 1
  scratch_git -C "$1" add -f .gitignore || return 1
  scratch_git -C "$1" commit -q -m "stop ignoring notes.md" || return 1
  printf 'MY PRIVATE NOTES\n' > "$1/tap-clone/notes.md" || return 1
  printf '%s\n' notes.md > "$1/hidden-path" || return 1
  cp "$1/tap-clone/notes.md" "$1/hidden-bytes" || return 1
}

# A clone whose config names a core.fsmonitor program. core.hooksPath does not cover
# that setting, so it is a second way for the clone to get code run by the commands
# above the refresh - during the inventory itself, not after it. The program here does
# what a broken or hostile one would: it rewrites the formula the brew checks are about
# to read, then answers "/" (assume everything changed), which is a valid response, so
# git carries on and the run looks normal.
#
# It lives under .git/ and is named to git relatively, so no case-directory path is
# interpolated into a config value; git runs it from the top of the working tree, which
# is what makes `.git/fsm` and the marker's `../fsm-ran` resolve.
setup_clone_fsmonitor_program() {
  setup_tap_clone "$1" || return 1
  cat > "$1/tap-clone/.git/fsm" <<'PROG' || return 1
#!/bin/sh
printf 'ran with args: %s\n' "$*" >> ../fsm-ran
printf 'class Rumdl\n  # the fsmonitor program replaced this\nend\n' > Formula/rumdl.rb
printf '/\0'
PROG
  chmod +x "$1/tap-clone/.git/fsm" || return 1
  scratch_git -C "$1/tap-clone" config core.fsmonitor .git/fsm || return 1
}

# core.worktree in the clone sends every worktree command somewhere else. Built in the
# DANGEROUS shape deliberately: the redirected directory holds exactly the clone's
# tracked files, unmodified, so the inventory reads clean and the refresh proceeds -
# which is how the fetched commit gets written into a directory nobody nominated while
# the tap path keeps the old formula brew then reads. Built with modifications in it
# instead, the run refuses and the case would pass without testing anything.
setup_clone_worktree_redirect() {
  setup_tap_clone "$1" || return 1
  mkdir -p "$1/elsewhere" || return 1
  # The clone's index, extracted into that directory: identical bytes and modes, so
  # `status` there reports nothing at all.
  scratch_git -C "$1/tap-clone" --work-tree="$1/elsewhere" \
    checkout-index --all --force || return 1
  cp "$1/elsewhere/Formula/rumdl.rb" "$1/elsewhere-formula.rb" || return 1
  scratch_git -C "$1/tap-clone" config core.worktree "$1/elsewhere" || return 1
}

# The third execution point, and the one no override can close: the FETCHED commit's
# .gitattributes names a filter driver, and the clone's config says what that driver
# runs. So the program runs whatever this script passes on the command line, and the
# formula in the working tree afterwards is the program's output rather than the commit's
# bytes. What is guarded is therefore the outcome, not the execution: the run must refuse
# rather than let brew check bytes nothing validated.
setup_clone_smudge_filter() {
  setup_tap_clone "$1" || return 1
  printf 'Formula/rumdl.rb filter=tapf\n' > "$1/.gitattributes" || return 1
  scratch_git -C "$1" add -f .gitattributes || return 1
  scratch_git -C "$1" commit -q -m "the fetched commit selects a filter driver" || return 1
  cat > "$1/smudge" <<'PROG'
#!/bin/sh
cat >/dev/null
printf 'class Rumdl\n  # THE SMUDGE FILTER WROTE THIS, NOT THE COMMIT\nend\n'
PROG
  chmod +x "$1/smudge" || return 1
  scratch_git -C "$1/tap-clone" config filter.tapf.smudge "$1/smudge" || return 1
}

# One setting, no .gitattributes and no program: core.autocrlf=true rewrites every file
# git checks out, and one of them is the formula brew audits. The likeliest of all these
# to be set by an actual contributor rather than by an attacker.
setup_clone_autocrlf() {
  setup_tap_clone "$1" || return 1
  scratch_git -C "$1/tap-clone" config core.autocrlf true || return 1
}

setup_clone_post_checkout_hook() {
  setup_tap_clone "$1" || return 1
  mkdir -p "$1/tap-clone/.git/hooks" || return 1
  cat > "$1/tap-clone/.git/hooks/post-checkout" <<'HOOK' || return 1
#!/bin/sh
printf 'ran\n' > ../hook-ran
printf 'the hook replaced the formula after the inventory ran\n' > Formula/rumdl.rb
printf 'and created this, for the clean to delete\n' > hook-made-this.txt
HOOK
  chmod +x "$1/tap-clone/.git/hooks/post-checkout" || return 1
}

write_brew_stub() { # write_brew_stub <stubdir> <clonepath> [livecheck-json-file]
  # The clone's path is handed over in a file beside the stub, for the reason
  # write_curl_stub gives: interpolating it would break the stub on an apostrophe.
  printf '%s\n' "$2" > "$1/brew.repository"
  # `brew livecheck --json` answers in JSON and exits 0 whether or not the block
  # resolved anything, so the stub has to answer in JSON too: a stub that stayed
  # silent would make every successful-refresh case refuse, and a stub that only
  # exited 0 would let a validator that ignores the JSON pass.
  if [ -n "${3:-}" ]; then
    cp "$3" "$1/brew.livecheck" || return 1
  else
    cat > "$1/brew.livecheck" <<JSON
[
  {
    "formula": "rumdl",
    "version": {
      "current": "$CUR_VERSION",
      "latest": "$CUR_VERSION",
      "outdated": false
    }
  }
]
JSON
  fi
  cat > "$1/brew" <<'STUB'
#!/bin/sh
case "$1" in
  tap)          echo rvben/rumdl ;;
  --repository) cat "$(dirname "$0")/brew.repository" ;;
  livecheck)    cat "$(dirname "$0")/brew.livecheck" ;;
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

# The shape brew returns for a livecheck block that resolves nothing: a status of
# error, no version object at all, and exit 0. Taken from a real run against a
# tapped formula whose strategy was pointed at a pattern that matches nothing.
write_brew_livecheck_unresolved() { # <stubdir> <clonepath>
  cat > "$1/livecheck-error.json" <<'JSON'
[
  {
    "formula": "rumdl",
    "status": "error",
    "messages": [
      "Unable to get versions"
    ],
    "meta": {
      "livecheck_defined": true
    }
  }
]
JSON
  write_brew_stub "$1" "$2" "$1/livecheck-error.json"
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
stubs_validator_livecheck_unresolved() {
  write_validator_stubs "$1"
  write_brew_livecheck_unresolved "$1" "${1%/stub}/tap-clone"
}

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
  # And the working tree, which is what brew actually reads. A reset that moves
  # the ref and leaves the files behind - `--soft`, or `--mixed` - matches on HEAD
  # while brew goes on validating the previous formula, so the sha comparison
  # above cannot be the whole assertion.
  if ! cmp -s "$1/Formula/rumdl.rb" "$1/tap-clone/Formula/rumdl.rb"; then
    echo "the tap clone's HEAD matches the checkout but its working-tree formula"
    echo "does not, so the brew checks below it would read the previous formula"
    diff "$1/Formula/rumdl.rb" "$1/tap-clone/Formula/rumdl.rb" | sed 's/^/  /'
    return 1
  fi
  # HEAD and one file are still two points, and a wrong refresh can hit both: a
  # `reset --soft` that copies the formula across leaves the index and every other
  # file at the previous commit while satisfying both checks above. What the
  # refresh actually promises is that the clone IS the checkout's commit, which is
  # a clean tree at that ref and nothing weaker.
  local residue
  residue="$(clone_git "$1" status --porcelain)"
  if [ -n "$residue" ]; then
    echo "the tap clone is at the checkout's HEAD but is not clean at it, so part"
    echo "of what brew reads is still from the previous commit:"
    printf '%s\n' "$residue" | sed 's/^/  /'
    return 1
  fi
}

# The clean case's second bound. A warning printed unconditionally would satisfy
# the uncommitted case below while telling everyone who commits first that their
# formula was not audited, so the ordinary run has to be shown staying quiet.
assert_clone_refreshed_and_quiet() { # <casedir>
  assert_clone_refreshed "$1" || return 1
  if grep -q 'differs from HEAD' "$1/out.txt"; then
    echo "the formula is committed and the clone is at that commit, so brew read"
    echo "exactly the formula the pin check read - but the run warned that it did"
    echo "not:"
    sed 's/^/  /' "$1/out.txt" | head -8
    return 1
  fi
}

# The refresh completed AND ran none of the clone's own hooks. Both halves, because
# either alone is satisfiable by the wrong thing: suppressing hooks by failing to
# refresh at all would pass a marker-only check, and a refresh that ran the hook still
# reaches the checkout's HEAD. `assert_clone_refreshed` covers the damage a hook does
# (it replaces the formula, and it is checked against the checkout's copy and for a
# clean tree); the marker covers the hook having run at all, including a hook whose
# only effect was outside the clone or was cleaned away afterwards.
# Both markers, because a clone has more than one way to get its own code run and each
# is a separate setting: .git/hooks (or core.hooksPath) for post-checkout, core.fsmonitor
# for the program git asks what changed. One function so that neither case can pass on
# the other's suppression, and so a third way, when one turns up, has one place to land.
assert_clone_refreshed_and_clone_code_unrun() { # <casedir>
  local bad=0 marker what
  assert_clone_refreshed "$1" || bad=1
  for marker in hook-ran fsm-ran; do
    [ -f "$1/$marker" ] || continue
    case "$marker" in
      hook-ran) what="post-checkout hook" ;;
      fsm-ran)  what="core.fsmonitor program" ;;
    esac
    echo "the clone's own $what executed during the refresh, so the clone got to run"
    echo "code while this script was deciding what may be touched, and could change"
    echo "the formula the brew checks read:"
    sed 's/^/  /' "$1/$marker"
    bad=1
  done
  return "$bad"
}

# The fsmonitor case's own positive control, and the reason it is not folded into the
# function above: that function asserts the ABSENCE of an effect, and an absence is what
# a fixture git never honours looks like too. If a future git ignores a relative
# core.fsmonitor path, or stops consulting the hook for `status`, the guard keeps passing
# while guarding nothing. So after the suppression is asserted, the same clone runs one
# UNWRAPPED command, which must produce the marker. Deliberately last: it executes the
# clone's program, which rewrites the formula, so every assertion above it has to have
# read the clone already.
assert_clone_code_unrun_and_fixture_live() { # <casedir>
  assert_clone_refreshed_and_clone_code_unrun "$1" || return 1
  git -C "$1/tap-clone" status --porcelain >/dev/null 2>&1
  if [ ! -f "$1/fsm-ran" ]; then
    echo "harness: this case's core.fsmonitor fixture never runs on this git, so the"
    echo "assertion above proved nothing. One unwrapped 'git status' in the same clone"
    echo "was supposed to produce the marker and did not - the fixture needs fixing"
    echo "before the guard it tests can be trusted:"
    scratch_git -C "$1/tap-clone" config --get core.fsmonitor | sed 's/^/  core.fsmonitor=/'
    git --version | sed 's/^/  /'
    return 1
  fi
}

# Both questions core.worktree raises, because the answers are independent and the
# dangerous arm is the one that exits 0: the clone brew reads must hold the commit under
# validation, AND the directory the stale key pointed at must be byte-for-byte what it
# was. A refresh that wrote the fetched commit into that directory has destroyed files
# nobody nominated, which no message check would notice.
assert_clone_refreshed_and_elsewhere_untouched() { # <casedir>
  local bad=0
  assert_clone_refreshed "$1" || bad=1
  if ! cmp -s "$1/elsewhere-formula.rb" "$1/elsewhere/Formula/rumdl.rb"; then
    echo "core.worktree in the clone sent the refresh into $1/elsewhere, so the fetched"
    echo "commit was written over a directory nobody nominated:"
    diff "$1/elsewhere-formula.rb" "$1/elsewhere/Formula/rumdl.rb" | sed 's/^/  /'
    bad=1
  fi
  # The fetched commit adds a second file, so a redirected checkout leaves a trace the
  # formula comparison alone would miss.
  if [ -e "$1/elsewhere/later.txt" ]; then
    echo "the refresh created $1/elsewhere/later.txt: the fetched commit was checked out"
    echo "into the directory core.worktree named, not into the tap clone"
    bad=1
  fi
  return "$bad"
}

# core.autocrlf is the one mechanism here with no program and no attacker, so the run is
# expected to COMPLETE - refusing on it would reject an ordinary contributor's clone.
# `assert_clone_refreshed` already compares bytes, so a CR would fail it; the explicit
# check exists to name the mechanism in the failure rather than print a diff of a file
# that looks identical.
assert_clone_refreshed_without_eol_conversion() { # <casedir>
  assert_clone_refreshed "$1" || return 1
  local crs
  crs="$(tr -dc '\r' < "$1/tap-clone/Formula/rumdl.rb" | wc -c | tr -d ' ')"
  if [ "$crs" != 0 ]; then
    echo "the clone's core.autocrlf rewrote the line endings of the formula brew audits"
    echo "($crs CR bytes), so brew is checking bytes no commit contains"
    return 1
  fi
}

# A refusal is only a refusal if it stopped the thing it was protecting. The byte check
# sits above the brew checks precisely so audit, style and install never see a formula
# nothing validated, and "the message was printed" does not establish that.
assert_refused_before_brew_checks() { # <casedir>
  if grep -q '^==> brew audit' "$1/out.txt"; then
    echo "the run printed the refusal and then ran the brew checks anyway, which is what"
    echo "the refusal exists to prevent:"
    sed 's/^/  /' "$1/out.txt" | tail -8
    return 1
  fi
}

# The de-ignored file: refreshed, and the file still there. Both halves, and the residue
# checked by equality rather than presence - "the clone is not clean" would also pass on
# a refresh that left the whole previous commit behind, which is the opposite failure.
assert_clone_refreshed_keeping_deignored() { # <casedir>
  local bad=0 rel residue want got
  want="$(scratch_git -C "$1" rev-parse HEAD)"
  got="$(scratch_git -C "$1/tap-clone" rev-parse HEAD)"
  if [ "$want" != "$got" ]; then
    echo "the tap clone was not moved to the checkout's HEAD, so the brew checks"
    echo "below it would read a different formula than the one being validated"
    echo "  checkout: $want"
    echo "  clone:    $got"
    bad=1
  fi
  if ! cmp -s "$1/Formula/rumdl.rb" "$1/tap-clone/Formula/rumdl.rb"; then
    echo "the tap clone's working-tree formula is not the checkout's:"
    diff "$1/Formula/rumdl.rb" "$1/tap-clone/Formula/rumdl.rb" | sed 's/^/  /'
    bad=1
  fi
  assert_clone_hidden_bytes_only "$1" || bad=1
  rel="$(cat "$1/hidden-path" 2>/dev/null)"
  residue="$(clone_git "$1" status --porcelain)"
  if [ "$residue" != "?? $rel" ]; then
    echo "the refreshed clone should hold exactly one untracked path, $rel - the file"
    echo "whose ignore rule the fetched commit dropped - but it holds:"
    printf '%s\n' "$residue" | sed 's/^/  /'
    bad=1
  fi
  return "$bad"
}

# The refresh happened to the tap clone AND not to the repository GIT_DIR named.
# Two bounds for the same reason as everywhere else here: clearing the overrides is
# only correct if the work moved to the right repository, and a script that read
# the decoy would satisfy a check that only asked whether the decoy was left alone.
assert_clone_refreshed_and_decoy_untouched() { # <casedir>
  assert_clone_refreshed_and_quiet "$1" || return 1
  local want got
  want="$(cat "$1/decoy-head.txt" 2>/dev/null)"
  got="$(scratch_git -C "$1/decoy" rev-parse HEAD)"
  if [ -z "$want" ]; then
    echo "harness: no recorded decoy HEAD to compare against"
    return 1
  fi
  if [ "$want" != "$got" ]; then
    echo "the run moved the repository GIT_DIR named instead of the tap clone:"
    echo "  decoy was at: $want"
    echo "  now at:       $got"
    return 1
  fi
}

# Two statements, and the case needs both: the warning where the split happens,
# and the same fact in the closing report, which is the line that gets read.
assert_said_the_edit_was_not_audited() { # <casedir>
  local pat
  for pat in 'differs from HEAD' 'was NOT audited'; do
    if ! grep -q "$pat" "$1/out.txt"; then
      echo "the run reported pins, audit and style passing without saying that the"
      echo "formula brew read is HEAD's, not the edited one (no \"$pat\"):"
      sed 's/^/  /' "$1/out.txt" | tail -8
      return 1
    fi
  done
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
    echo "the clone's own commit was destroyed by the refresh"
    echo "  it was at: $want"
    echo "  now at:    $got"
    return 1
  fi
}

# Every refusal promises the clone was left as it was, so each refusal assertion
# starts here: the ref itself must not have moved. A "refusal" that reset the
# clone and then printed the error message satisfies a dirtiness check and an
# exit code, and has already done the damage the message says it avoided.
assert_clone_head_unmoved() { # <casedir>
  local want got
  want="$(cat "$1/clone-head.txt" 2>/dev/null)"
  got="$(scratch_git -C "$1/tap-clone" rev-parse HEAD)"
  if [ -z "$want" ]; then
    echo "harness: no recorded clone HEAD to compare against"
    return 1
  fi
  if [ "$want" != "$got" ]; then
    echo "the refusal moved the clone's HEAD, which is the thing it said it would not do"
    echo "  it was at: $want"
    echo "  now at:    $got"
    return 1
  fi
}

# The untracked files must survive, and so must the untracked directory: `clean
# -fd` removes directories too, and a check that only looked for the file would
# pass on a clean that took the directory with it.
assert_clone_untracked_kept() { # <casedir>
  assert_clone_head_unmoved "$1" || return 1
  local p
  for p in experiment.md scratch/notes.md; do
    if [ ! -f "$1/tap-clone/$p" ]; then
      echo "the clone's untracked $p was deleted, which is work a contributor"
      echo "cannot recover - it was never committed anywhere"
      return 1
    fi
  done
}

# The bytes, not the dirtiness. Each of these fixtures hid a local edit from every
# list the inventory reads - an index flag, or an ignore rule - so the file is not
# dirty by any measure git reports, and asking git whether anything changed returns
# the same answer before and after the loss. Comparing against the recorded copy is
# the only way to see it, which is also why the script has to refuse rather than ask
# git for a verdict it cannot give.
assert_clone_hidden_bytes_only() { # <casedir>
  if [ ! -f "$1/hidden-bytes" ] || [ ! -f "$1/hidden-path" ]; then
    echo "harness: the fixture recorded no hidden edit to compare against"
    return 1
  fi
  local rel
  rel="$(cat "$1/hidden-path")"
  if [ ! -f "$1/tap-clone/$rel" ]; then
    echo "the clone's $rel is gone - the run deleted a file git was not reporting"
    return 1
  fi
  if ! cmp -s "$1/hidden-bytes" "$1/tap-clone/$rel"; then
    echo "the clone's hidden edit to $rel was overwritten - git reports no change for"
    echo "that path, so nothing else in this suite would notice:"
    diff "$1/hidden-bytes" "$1/tap-clone/$rel" | sed 's/^/  /'
    return 1
  fi
}

# Bytes and ref together, for the cases that expect a refusal. Split from the
# bytes-only half because one case expects the refresh to SUCCEED - an ignored path
# that collides only on a case-folding filesystem, run on one that does not fold -
# and there the ref is supposed to move while the bytes are supposed to survive.
#
# Both checks run; neither returns early, so a failure names every consequence rather
# than the first one. An early return on the ref answered "did HEAD move?" and left
# "did the work survive?" unasked, which is the only question these cases exist for.
assert_clone_hidden_bytes_kept() { # <casedir>
  local bad=0
  assert_clone_hidden_bytes_only "$1" || bad=1
  assert_clone_head_unmoved "$1" || bad=1
  return "$bad"
}

assert_clone_still_dirty() { # <casedir>
  assert_clone_head_unmoved "$1" || return 1
  if [ -z "$(clone_git "$1" status --porcelain)" ]; then
    echo "the clone's uncommitted changes were discarded"
    return 1
  fi
  # "Dirty" is presence, and what this case protects is particular bytes. A
  # refresh that reset the clone and then dirtied it some other way leaves it
  # dirty while having destroyed the contributor's edit, which is the whole harm.
  if [ ! -f "$1/clone-dirty-formula.rb" ]; then
    echo "harness: no copy of the edited formula to compare against"
    return 1
  fi
  if ! cmp -s "$1/clone-dirty-formula.rb" "$1/tap-clone/Formula/rumdl.rb"; then
    echo "the clone is still dirty, but not with the edit that was there:"
    diff "$1/clone-dirty-formula.rb" "$1/tap-clone/Formula/rumdl.rb" | sed 's/^/  /'
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
  # Building the fixture is the harness's job, so a failure here is not a guard
  # failing - and left unchecked it would present as one. On a full disk or an
  # unwritable TMPDIR the scripts never arrive, the run exits 127, and that is
  # neither the expected code nor the expected message: every case reports FAIL,
  # which is indistinguishable from the guards having regressed. Checked rather
  # than trusted because this file deliberately runs without `set -e`, so nothing
  # else stops a case built out of nothing from being counted.
  #
  # original.rb is kept so a case can assert the formula came out exactly as it went
  # in, which is what every refusal in update-formula.sh actually promises.
  if ! mkdir -p "$dir/Formula" "$dir/scripts" "$dir/stub" ||
     ! cat > "$dir/Formula/rumdl.rb" ||
     ! cp "$dir/Formula/rumdl.rb" "$dir/original.rb" ||
     ! cp scripts/verify-formula.sh scripts/update-formula.sh \
          scripts/validate-formula.sh "$dir/scripts/" ||
     ! chmod +x "$dir/scripts"/*.sh; then
    echo "HARNESS FAILURE: could not build the fixture for '$name'" >&2
    echo "                 $dir" >&2
    echo "                 Out of disk space, or that path is not writable. This is" >&2
    echo "                 the harness failing, not a guard: a case whose scripts" >&2
    echo "                 are missing exits 127 and reads as a rejected formula." >&2
    exit 1
  fi

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

  # The suite clears every git repository override for itself, which is right for
  # the harness and means no case can ever exercise a script's own handling of one.
  # A case that is about an inherited variable asks for it here, and gets it for
  # that run only.
  local -a case_env=()
  if [ -n "${CASE_ENV:-}" ]; then
    local line
    while IFS= read -r line; do
      [ -n "$line" ] && case_env+=("$line")
    done < <("$CASE_ENV" "$dir")
    if [ "${#case_env[@]}" -eq 0 ]; then
      echo "HARNESS FAILURE: $CASE_ENV set no variables for '$name', so the case" >&2
      echo "                 would run in the ordinary environment and pass for the" >&2
      echo "                 wrong reason." >&2
      exit 1
    fi
  fi

  local out code
  out="$(cd "$dir" && env PATH="$dir/stub:$PATH" "${case_env[@]+"${case_env[@]}"}" \
    "./scripts/$script" "$@" 2>&1)"
  code=$?
  # Written out so an assertion can look at what the run printed, not only at what
  # it left on disk. What a refusal did NOT print is the evidence for several
  # cases: the default stubs fail every download, so a structural check that
  # stopped firing still exits 1 once the run reaches the download loop.
  printf '%s\n' "$out" > "$dir/out.txt"

  local why=""
  if [ "$want_code" != "any" ] && [ "$code" != "$want_code" ]; then
    why="expected exit $want_code, got $code"
  elif ! printf '%s' "$out" | grep -qF -- "$want_text"; then
    why="expected message not found: $want_text"
  fi

  # An exit code and a message say the guard fired. They do not say what it left
  # on disk, and for the updater that is the part that matters: a refusal that
  # rewrote the formula anyway would pass a code-and-message check.
  #
  # The assertion runs whatever the exit code was, and its detail is added to that
  # reason rather than replacing it. Gated on a matching code, an assertion about
  # destroyed bytes can only ever confirm a case that already passed: with the guard
  # removed the run exits 0, the code check answers first, and the one question worth
  # asking - was the work actually destroyed? - is never put. That is not theoretical.
  # Two cases here were written around lost bytes, and the control arms that removed
  # their guard could report only "expected exit 1, got 0"; the bytes had to be
  # checked by hand outside the suite.
  if [ -n "${CASE_ASSERT:-}" ]; then
    local detail
    if ! detail="$("$CASE_ASSERT" "$dir" 2>&1)"; then
      if [ -n "$why" ]; then
        why="$why
$detail"
      else
        why="$detail"
      fi
    fi
  fi
  CASE_SETUP=""
  CASE_STUBS=""
  CASE_ASSERT=""
  CASE_FORBID=""
  CASE_ENV=""

  if [ -z "$why" ]; then
    pass=$((pass + 1))
    printf 'ok    %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n' "$name"
    printf '      %s\n' "$why"
    # Both ends, not the head alone. The head says which check the run reached;
    # the diagnosis is at the end, and a head-only excerpt cut it off exactly when
    # it was needed: a validate-formula.sh case prints pages of brew progress
    # before the line that explains the failure. The full text is in out.txt.
    local lines
    lines="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
    if [ "$lines" -le 24 ]; then
      printf '%s\n' "$out" | sed 's/^/      | /'
    else
      printf '%s\n' "$out" | head -12 | sed 's/^/      | /'
      printf '      | ... %s more line(s), in full at %s ...\n' "$((lines - 24))" "$dir/out.txt"
      printf '%s\n' "$out" | tail -12 | sed 's/^/      | /'
    fi
  fi
}

echo "Guard tests (offline; downloads stubbed with local fixture assets)"
echo

# The positive control. The unmodified formula must clear every structural
# check and reach the download stage, which this line marks. Without this a
# guard that rejected everything would pass every other case here.
case_run "unmodified formula clears every structural check" any \
  "$DOWNLOAD_MARKER" verify-formula.sh < "$FORMULA"

# Arguments are rejected rather than ignored, so `verify-formula.sh 0.2.77`
# cannot report the committed version's pins as if they were 0.2.77's.
case_run "an argument is refused, not discarded" 2 \
  "takes no arguments" verify-formula.sh 0.2.77 < "$FORMULA"

# The four correct assets arranged in the wrong Hardware::CPU branches. Every
# other check in the script is satisfied by this formula, which hands Intel
# Macs an arm64-only binary.
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
CASE_ASSERT=assert_refused_before_download
case_run "macOS pairs swapped between the intel and arm branches" 1 \
  "the macos:intel branch must carry x86_64-apple-darwin" \
  verify-formula.sh < "$WORK/macswap.rb"

# A platform dropped entirely. The url, sha256 and pair counts all stay in
# agreement, so no count check sees it. The expected-platform list is what
# rejects it, and the branch-exactly-once check further down independently
# rejects it too - verified by neutralising the list, which left the run
# failing on "does not declare each platform branch exactly once". That is why
# this case asserts the list's own message - and requires the backstop's message
# to be absent, because asserting a message is not the same as showing that the
# check owning it fired: the `echo` survives deleting the flag assignment beside
# it, and the backstop then refuses the formula with the same exit code.
#
# awk rather than `sed '/x86_64-apple-darwin/,+1d'`: the `,+N` address range is
# a GNU extension with no POSIX equivalent, and this suite runs on whatever sed
# the runner has. It does work on this macOS (Darwin 25.5 BSD sed deletes both
# lines), so nothing was broken - but a mutation that silently becomes a no-op
# on some other sed would feed the case an unmodified formula and blame the
# guard for accepting it, which is the failure assert_mutated exists to catch.
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
CASE_ASSERT=assert_refused_before_download
CASE_FORBID="does not declare each platform branch exactly once"
case_run "a platform removed with its pin" 1 \
  "does not ship the expected set of platforms" \
  verify-formula.sh < "$WORK/dropped.rb"

# A url pointing somewhere other than rumdl's releases. A host serving bytes
# that match the pin satisfies every hash check there is.
sed 's|github.com/rvben/rumdl/releases|github.com/someone/else/releases|' "$FORMULA" > "$WORK/origin.rb"
assert_mutated "$WORK/origin.rb"
CASE_ASSERT=assert_refused_before_download
case_run "a url that does not fetch from rumdl's releases" 1 \
  "does not fetch from rumdl's own releases" \
  verify-formula.sh < "$WORK/origin.rb"

# A half-rewritten formula: one platform moved to a new release, the rest left
# behind. The version is scanned from the urls, so they have to agree.
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
CASE_ASSERT=assert_refused_before_download
case_run "urls naming two different versions" 1 \
  "name more than one version" \
  verify-formula.sh < "$WORK/mixed.rb"

# A url that sits in no CPU branch at all, so nothing decides which machine
# gets it. Removing the branch also leaves the branch counts wrong, so the
# backstop further down refuses this formula too - its message must stay absent
# for the refusal to be this check's.
sed '/Hardware::CPU.intel?/d' "$FORMULA" > "$WORK/unbound.rb"
assert_mutated "$WORK/unbound.rb"
CASE_ASSERT=assert_refused_before_download
CASE_FORBID="does not declare each platform branch exactly once"
case_run "a url outside any Hardware::CPU branch" 1 \
  "sits in no recognised platform branch" \
  verify-formula.sh < "$WORK/unbound.rb"

# A sha256 with no url above it. The url/sha/pair counts can still agree on
# this, which is how it once reached the download loop and was reported as a
# malformed pin instead of a malformed formula.
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
CASE_ASSERT=assert_refused_before_download
# Removing one url to balance the counts balances only the pair count: the
# duplicated sha256 leaves 3 urls against 5 sha256 lines, so the count check
# below refuses this formula too, and it also exits before the download. Deleting
# the unpaired check's own `exit 1` therefore left this case passing on the count
# check's refusal - measured, by making that exact edit and reading which message
# came out.
CASE_FORBID="they must agree"
case_run "a sha256 with no url above it" 1 \
  "has no url above it" \
  verify-formula.sh < "$WORK/unpaired.rb"

# 9-10. The pin-format check, which unlike every check above runs inside the
# download loop - so its case cannot rest on the exit code, because a failed
# download produces the same one. Both cases here run against a formula pinned
# to the fixture assets, where the downloads succeed and the hashes match, so
# the only thing left that can fail the run is the check under test.
fixture_pinned_formula "$WORK/fixture-pinned.rb" || {
  echo "HARNESS FAILURE: could not build a formula pinned to the fixture assets." >&2
  echo "                 The pin-format cases would then rest on a failed download," >&2
  echo "                 which is what they exist to stop resting on." >&2
  exit 1
}

# The positive control for it: the verifier must be able to SUCCEED. Nothing
# else here shows that - the committed pins are the real published assets'
# hashes, which no fixture can serve, so the unmodified-formula case can only
# require that the run reaches the download stage. Without this, a verifier
# that failed every
# formula would pass every other verifier case in this suite.
CASE_STUBS=stubs_verifier
case_run "a formula pinned to the bytes its urls fetch verifies clean" 0 \
  "All 4 pins match the artifacts their urls fetch, at version $CUR_VERSION" \
  verify-formula.sh < "$WORK/fixture-pinned.rb"

# And one pin replaced by a placeholder, which is what a half-finished update
# leaves behind. Three assets still verify, so the run is proved to have got
# through the loop: what fails it is the pin's format and nothing else.
FIXTURE_FIRST_SHA="$(sed -n 's/^[[:space:]]*sha256 "\([^"]*\)".*/\1/p' "$WORK/fixture-pinned.rb" | head -1)"

# "64 hex characters" is two requirements, and one bad pin can only test one of
# them. A `PLACEHOLDER` violates both at once, so widening the character class to
# [0-9a-z] left the case passing - and a 64-character pin containing a z is then
# sent to `sha256`-comparison as a valid pin, where it simply never matches and
# the asset reports as changed bytes rather than as a malformed formula.
#
# So one pin per requirement: 64 characters that are not all hex, and hex that is
# not 64 characters long.
bad_pin() { # bad_pin <pin> <outfile>
  sed "s|sha256 \"$FIXTURE_FIRST_SHA\"|sha256 \"$1\"|" "$WORK/fixture-pinned.rb" > "$2"
  if cmp -s "$2" "$WORK/fixture-pinned.rb"; then
    echo "HARNESS FAILURE: substituting the pin '$1' changed nothing." >&2
    exit 1
  fi
}
bad_pin "$(printf 'z%.0s' $(seq 64))" "$WORK/pin-nonhex.rb"
bad_pin "0123abcd" "$WORK/pin-short.rb"

CASE_STUBS=stubs_verifier
CASE_ASSERT=assert_only_the_pin_format_failed
case_run "a 64-character pin that is not hexadecimal" 1 \
  "pinned sha256 is not 64 hex characters" \
  verify-formula.sh < "$WORK/pin-nonhex.rb"

CASE_STUBS=stubs_verifier
CASE_ASSERT=assert_only_the_pin_format_failed
case_run "a hexadecimal pin that is not 64 characters" 1 \
  "pinned sha256 is not 64 hex characters" \
  verify-formula.sh < "$WORK/pin-short.rb"

# 10-12. The updater's version guard. It reaches curl, a url and the formula
# text, and the value arrives from a repository_dispatch payload. Run with
# ALLOW_UNATTESTED=1 so the checks under test are reached without a gh login.
export ALLOW_UNATTESTED=1

case_run "a version that is not a version" 2 \
  "version must look like 1.2.3" update-formula.sh "1.2; rm -rf /" < "$FORMULA"

# The one grep would accept: a bare semver on the first line, anything after it.
case_run "a version whose first line only looks valid" 2 \
  "version must look like 1.2.3" update-formula.sh "$(printf '1.2.3\nrm -rf /')" < "$FORMULA"

# v$OLDER_VERSION rather than an obviously old one: sorted as text it looks newer
# than the version the formula names, so this fails if the updater compares
# versions as strings. Which candidate is used is chosen at startup and checked
# there for actually discriminating.
# The formula rewritten to claim BACK_VERSION, so what this case compares is the
# synthesized pair and not the version the tap happens to be on. Every url carries
# the version, so one substitution keeps them consistent with each other.
sed "s|v$CUR_VERSION|v$BACK_VERSION|g" "$FORMULA" > "$WORK/back-version.rb"
if grep -qF "v$CUR_VERSION" "$WORK/back-version.rb" || ! grep -qF "v$BACK_VERSION" "$WORK/back-version.rb"; then
  echo "HARNESS FAILURE: rewriting the formula to v$BACK_VERSION did not take, so the" >&2
  echo "                 case would compare v$OLDER_VERSION against v$CUR_VERSION instead." >&2
  exit 1
fi
case_run "moving the tap to an older version" 1 \
  "Refusing to move the tap backwards" update-formula.sh "$OLDER_VERSION" < "$WORK/back-version.rb"

# 13-17. The updater past its structural checks, where what gets pinned is
# actually decided. Downloads succeed from here on, so ALLOW_UNATTESTED must go:
# leaving it exported would skip the provenance loop in every case below,
# including the one whose whole subject is provenance.
unset ALLOW_UNATTESTED

# The positive control for the updater, and the counterpart to the
# unmodified-formula case. A script that refused every version, or wrote hashes in
# the wrong order, or wrote the first hash into all four pins, passes every other
# updater case here and fails only this one.
CASE_STUBS=stubs_attested
CASE_ASSERT=assert_pinned_to_other
case_run "a full update pins each url to the bytes that url fetched" 0 \
  "All 4 pins match the artifacts their urls fetch, at version $OTHER_VERSION" \
  update-formula.sh "$OTHER_VERSION" < "$FORMULA"

# An asset that downloads cleanly and carries no build provenance. The hash
# would be perfectly self-consistent - it is the hash of what the url served -
# which is exactly why the attestation is checked before pinning rather than
# the hash being taken as sufficient.
#
# The first asset here IS attested and a later one is not, because the release has
# four assets and the check sits in a loop: a stub refusing all four cannot tell
# "every asset is checked" from "the first asset is checked", since the loop stops
# on the first asset under either. Checking only the first left this case passing
# while three platforms were pinned unverified. Which asset is refused is asserted
# too: a check reading provenance the wrong way round refuses the attested one,
# with the same exit code and the same message.
CASE_STUBS=stubs_attested_first_only
CASE_ASSERT=assert_first_asset_cleared_provenance
case_run "an asset with no build provenance is refused, not pinned" 1 \
  "has no valid build provenance from rvben/rumdl" \
  update-formula.sh "$OTHER_VERSION" < "$FORMULA"

# An asset that IS attested, by a workflow that is not rumdl's release
# workflow. Provenance alone does not say who built the bytes: anyone can
# attest their own build from their own workflow, so what makes the check mean
# "rumdl built this" is --signer-workflow. This stub answers as GitHub would
# for such an asset - it finds an attestation when asked without the flag and
# none when asked with it - so dropping the flag accepts the asset and fails
# this case, while every other provenance case still passes.
CASE_STUBS=stubs_attested_wrong_signer
CASE_ASSERT=assert_formula_untouched
case_run "an asset attested by the wrong workflow is refused" 1 \
  "has no valid build provenance from rvben/rumdl" \
  update-formula.sh "$OTHER_VERSION" < "$FORMULA"

# The v0.2.76 case itself: the formula already names this version, and the
# published assets now hash differently. Every pin computed here is genuine
# and attested, so nothing else in the chain objects - this guard is the only
# thing that turns "the release was re-run" into a decision rather than a
# silent change of what users install under a version they already have.
CASE_STUBS=stubs_attested
CASE_ASSERT=assert_formula_untouched
case_run "the same version with changed assets needs ALLOW_REPIN" 1 \
  "the assets for v$CUR_VERSION have changed since the formula was pinned" \
  update-formula.sh "$CUR_VERSION" < "$FORMULA"

# And the escape hatch works, so the guard above is a gate rather than a dead
# end. Re-pins the version the formula already names to the assets published
# now, which is what the operator asked for.
export ALLOW_REPIN=1
CASE_STUBS=stubs_attested
CASE_ASSERT=assert_repinned_to_cur
case_run "ALLOW_REPIN=1 re-pins the version already named" 0 \
  "re-pinning v$CUR_VERSION to the assets published now" \
  update-formula.sh "$CUR_VERSION" < "$FORMULA"
unset ALLOW_REPIN

# An asset replaced between pinning and verifying: the four downloads that get
# pinned succeed, and the four the verification makes return different bytes.
# The formula has already been rewritten by then, so the requirement is not
# just that the run fails but that it leaves the working tree as it found it.
# Without the restore, the next thing to read the formula - including the
# commit step in update-formula.yml - takes those unverified pins as current.
CASE_STUBS=stubs_replaced_midway
CASE_ASSERT=assert_formula_untouched
case_run "a verification failure after the write restores the formula" 1 \
  "was restored to its previous contents" \
  update-formula.sh "$OTHER_VERSION" < "$FORMULA"

# 18-22. validate-formula.sh's tap-clone refresh: the only data-destroying pair of
# commands in this repository, and the check that permits them. Each case gets a
# real checkout and a real clone of it, and each asserts what the clone still
# holds afterwards - the exit code says the guard fired, not that the work
# survived.

# The positive control, and the reason the refresh exists at all: `brew tap
# --force` on an already-tapped name does nothing, so without this the brew
# checks would read whatever commit the clone happened to be on.
CASE_SETUP=setup_clone_clean
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_refreshed_and_quiet
case_run "a clean tap clone is moved to the checkout's HEAD" 0 \
  "tap clone now at" validate-formula.sh < "$FORMULA"

# Uncommitted changes in the clone, which is exactly what `brew edit
# rvben/rumdl/rumdl` leaves behind.
CASE_SETUP=setup_clone_dirty
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_still_dirty
case_run "a tap clone with uncommitted changes is not discarded" 1 \
  "holds work this would destroy" validate-formula.sh < "$FORMULA"

# Untracked files and an untracked directory in the clone. A separate case from the
# uncommitted-changes one because the two are found by different things: a modified
# tracked file shows in `status` however it is invoked, while untracked files are
# reported only when `status` is asked about them. Dropping them from the inventory, or
# deleting them before deciding whether that is allowed, left every other case passing
# while a contributor's unversioned notes were gone for good.
CASE_SETUP=setup_clone_untracked
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_untracked_kept
case_run "a tap clone's untracked files are not cleaned away" 1 \
  "holds work this would destroy" validate-formula.sh < "$FORMULA"

# A commit the checkout does not have. Nothing shows as dirty, so only the
# ahead-count sees it.
CASE_SETUP=setup_clone_ahead
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_kept_its_commit
case_run "a tap clone holding its own commit is not reset" 1 \
  "commit(s) not in" validate-formula.sh < "$FORMULA"

# And the ahead-count failing to answer. This is the one that was wrong: a
# `rev-list` that could not run was coerced to 0, which with a clean worktree
# skipped both refusals and ran reset --hard on the very commits it could not
# count. The assertion is that the clone's own commit is still there, so this
# case fails against the previous version of the script rather than merely
# asserting the new message.
CASE_SETUP=setup_clone_ahead
CASE_STUBS=stubs_validator_no_rev_list
CASE_ASSERT=assert_clone_kept_its_commit
case_run "a tap clone whose commits cannot be counted is not reset" 1 \
  "could not count commits" validate-formula.sh < "$FORMULA"

# The formula edited and not committed. The pin check reads the working tree
# and the brew checks read a clone at HEAD, so this run validates two
# different formulae and says so nowhere: the edit collects a clean audit, a
# passing test and a closing "all checks passed" from checks that never saw
# it. Whoever ran it then pushes on the strength of that.
CASE_SETUP=setup_clone_uncommitted_formula
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_said_the_edit_was_not_audited
case_run "an uncommitted formula edit is reported as unaudited" 0 \
  "tap clone now at" validate-formula.sh < "$FORMULA"

# A git repository override inherited from the environment. git exports GIT_DIR
# to every hook it runs, and this script is the repository's one-command local
# gate, so a pre-push hook that calls it is the obvious way to make it
# automatic. `git -C <dir>` does not override GIT_DIR, so without the script
# clearing it, the check that decides whether refreshing the tap clone would
# destroy work inspects a different repository entirely - and answers "nothing
# to lose" about a clone it never looked at. The clone here is clean, so the
# evidence is the refresh landing on the right repository rather than a
# refusal, which any mistake would also produce.
CASE_SETUP=setup_clone_decoy_repo
CASE_ENV=case_env_decoy_repo
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_refreshed_and_decoy_untouched
case_run "an inherited GIT_DIR does not redirect the tap-clone checks" 0 \
  "Clearing inherited git repository overrides" validate-formula.sh < "$FORMULA"

# Three more ways the inventory in front of the refresh comes back empty on a clone
# that holds work. None of them is an error state: git is
# being asked a narrower question than the one the answer gets used for, and it
# answers the narrow question correctly.
#
# The clone's own config suppressing untracked files. The case above covers
# untracked files; this covers being unable to see them, a different failure with
# the same consequence, and the refusal message is the same one either way - so
# the assertion that carries this case is the files still being there.
CASE_SETUP=setup_clone_untracked_suppressed_by_config
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_untracked_kept
case_run "untracked files hidden by the clone's own config are not cleaned away" 1 \
  "holds work this would destroy" validate-formula.sh < "$FORMULA"

# The same suppression inherited from the environment, the form it takes when this
# script runs from a hook or a wrapper. Requiring the announcement as well pins
# which half of the fix answered: the status flag alone would refuse silently.
CASE_SETUP=setup_clone_untracked_suppressed_by_env
CASE_ENV=case_env_suppress_untracked
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_untracked_kept
case_run "an inherited GIT_CONFIG_COUNT cannot hide the clone's untracked files" 1 \
  "Clearing inherited git repository overrides" validate-formula.sh < "$FORMULA"

# A tracked file marked assume-unchanged and then edited. git reports no change for
# it anywhere - not `status`, not `diff --quiet HEAD` - so every other assertion in
# this suite passes while the refresh rewrites the file from the index. Whether
# those paths hold edits is unknown rather than known-clean, and unknown immediately
# before a destructive command has to stop the run.
CASE_SETUP=setup_clone_assume_unchanged_edit
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_hidden_bytes_kept
case_run "a tracked edit git was told not to stat is not overwritten" 1 \
  "assume-unchanged or skip-worktree" validate-formula.sh < "$FORMULA"

# The same hidden state under the other flag, where nothing is destroyed and the run
# is wrong anyway: skip-worktree means the refresh leaves the clone's own formula
# in place, so the brew checks audit and install that file while every line the run
# prints refers to the formula under validation. The refusal is the same one; what it
# prevents here is a passing run about the wrong bytes.
CASE_SETUP=setup_clone_skip_worktree_formula
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_hidden_bytes_kept
case_run "a formula the clone was told to keep is not validated as ours" 1 \
  "assume-unchanged or skip-worktree" validate-formula.sh < "$FORMULA"

# An ignored file in the clone that the fetched commit tracks, in its three forms.
# Nothing the inventory reads mentions any of them - status omits ignored paths,
# `ls-files -v` lists only tracked ones - so the refusal can only come from the
# refresh itself, and the asserted message is the refresh's rather than the
# inventory's. That distinction is the point: "holds work this would destroy" is the
# inventory speaking, "git refused to refresh" is git refusing the checkout, and a
# case that accepted either would not say which half answered.
CASE_SETUP=setup_clone_ignored_tracked_upstream
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_hidden_bytes_kept
case_run "an ignored file the fetched commit tracks is not overwritten" 1 \
  "git refused to refresh" validate-formula.sh < "$FORMULA"

# The same collision reached through an ancestor: the fetched commit tracks a file
# where this clone keeps a directory of ignored work. Writing the file means removing
# the directory, and no comparison of path names matches `notes` against
# `notes/private`.
CASE_SETUP=setup_clone_ignored_dir_collision
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_hidden_bytes_kept
case_run "an ignored directory the fetched commit tracks as a file is not removed" 1 \
  "git refused to refresh" validate-formula.sh < "$FORMULA"

# And the same collision reached through case folding, where the expectation is the
# filesystem's to decide. On a folding filesystem an ignored Notes.md and a tracked
# notes.md are one file and the refresh must refuse; on a case-sensitive one they are
# two files, nothing collides, and the run must complete - which is the control that
# keeps the refusal from being satisfied by a refresh that refuses everything.
CASE_SETUP=setup_clone_ignored_case_collision
CASE_STUBS=stubs_validator
if [ "$FS_FOLDS_CASE" = 1 ]; then
  CASE_ASSERT=assert_clone_hidden_bytes_kept
  case_run "an ignored file differing only in case is one file, and is not overwritten" \
    1 "git refused to refresh" validate-formula.sh < "$FORMULA"
else
  # The bytes only: here the refresh is supposed to succeed, so HEAD is supposed to
  # move, and asserting it unmoved would fail on correct behaviour.
  CASE_ASSERT=assert_clone_hidden_bytes_only
  case_run "an ignored file differing only in case is a different file, and survives" \
    0 "tap clone now at" validate-formula.sh < "$FORMULA"
fi

# The escape hatch doing what it says. Untested until now, and it did not: the refresh is
# a non-forced checkout, which refuses to overwrite a modified tracked file, so the run
# printed "proceeding over 1 changed path(s)" and then died on git's refusal - for the one
# shape the hatch is for, since `brew edit` modifies the formula and the commit being
# validated changes it too. A local commit or an edit to another file completed fine,
# which is why the hatch looked like it worked. The message is asserted with the deed:
# a hatch that printed the promise and refused would pass on the text alone.
CASE_SETUP=setup_clone_dirty_for_discard
CASE_STUBS=stubs_validator
CASE_ENV=case_env_discard_tap_clone
CASE_ASSERT=assert_clone_refreshed
case_run "DISCARD_TAP_CLONE=1 discards the tracked edit it says it discards" 0 \
  "Tracked edits and local commits there go" validate-formula.sh < "$FORMULA"

# And the bound on the hatch, which is the case that keeps `checkout -f` out of this
# script. The hatch is asked for and there is also an ignored file the fetched commit
# tracks: the tracked edit goes, and that file must still be here afterwards. -f would
# make the case above pass and this one destroy a contributor's ignored work, measured on
# the same fixture; clearing the tracked edits with `reset --hard HEAD` keeps both.
CASE_SETUP=setup_clone_dirty_and_ignored_collision
CASE_STUBS=stubs_validator
CASE_ENV=case_env_discard_tap_clone
CASE_ASSERT=assert_clone_hidden_bytes_kept
case_run "DISCARD_TAP_CLONE=1 does not extend to an ignored file the commit tracks" 1 \
  "git refused to refresh" validate-formula.sh < "$FORMULA"

# A hook the clone brought with it. The refresh is allowed to move this clone; it is not
# allowed to run its code. `reset --hard` ran no hooks, so this case exists because the
# fix above - handing the collision check to `checkout` - would otherwise have handed the
# clone an execution point as well, one that lands after the inventory and before the
# brew checks.
CASE_SETUP=setup_clone_post_checkout_hook
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_refreshed_and_clone_code_unrun
case_run "the tap clone's own post-checkout hook is not run by the refresh" 0 \
  "tap clone now at" validate-formula.sh < "$FORMULA"

# The same principle at the other setting. core.fsmonitor is not a hook by name and
# core.hooksPath does not reach it, so it was live after the hooks were suppressed: the
# program ran during the status and ls-files that take the inventory, and rewrote the
# formula. This case is about the commands ABOVE the refresh as much as the refresh.
CASE_SETUP=setup_clone_fsmonitor_program
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_code_unrun_and_fixture_live
case_run "the tap clone's core.fsmonitor program is not run by the refresh" 0 \
  "tap clone now at" validate-formula.sh < "$FORMULA"

# The third setting, and the one that shows why enumerating them stopped being the plan:
# core.worktree points every worktree command at another directory, so the refresh writes
# the fetched commit THERE while the tap path keeps the old formula brew then reads. Built
# in its silent shape on purpose - see the fixture - so this case fails on the previous
# version of the script by exiting 0 with two wrong outcomes rather than by refusing.
# These repos reach this state for real: the key goes stale when a worktree is deleted
# under an interrupted operation, which has happened twice.
CASE_SETUP=setup_clone_worktree_redirect
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_refreshed_and_elsewhere_untouched
case_run "core.worktree in the clone does not redirect the refresh out of the tap" 0 \
  "tap clone now at" validate-formula.sh < "$FORMULA"

# One setting a contributor sets for their own reasons, no program and no adversary:
# core.autocrlf rewrites what checkout writes, and one of the files it rewrites is the
# formula brew audits. This run must COMPLETE - refusing here would reject an ordinary
# clone - with the commit's own bytes in the working tree.
CASE_SETUP=setup_clone_autocrlf
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_refreshed_without_eol_conversion
case_run "the clone's core.autocrlf does not rewrite the formula brew audits" 0 \
  "tap clone now at" validate-formula.sh < "$FORMULA"

# The execution point that cannot be closed from the command line: the driver's NAME comes
# from the fetched commit's .gitattributes and the command it runs comes from the clone's
# config, so no `-c` this script can pass disables it, and the fix that would
# (.git/info/attributes) writes inside the contributor's clone. So what is guarded is the
# outcome instead - the formula at the path brew reads is not the blob of the commit this
# run validated - and that check is what every other mechanism here also fails.
CASE_SETUP=setup_clone_smudge_filter
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_refused_before_brew_checks
case_run "a formula rewritten by the clone's own filter driver is refused" 1 \
  "is not the formula in" validate-formula.sh < "$FORMULA"

# A file the clone ignores until the fetched commit stops ignoring it. The refresh must
# proceed - there is no collision, and nothing in the inventory is holding it back - and
# must leave the file where it is, which is why no `clean` follows the refresh.
CASE_SETUP=setup_clone_deignored_local_file
CASE_STUBS=stubs_validator
CASE_ASSERT=assert_clone_refreshed_keeping_deignored
case_run "a local file the fetched commit stops ignoring is not deleted" 0 \
  "tap clone now at" validate-formula.sh < "$FORMULA"

# The formula's livecheck block resolving nothing. This is the block that tells a
# maintainer a new rumdl release exists, and a broken one is invisible: `brew audit`
# and `brew style` both accept it, and `brew livecheck` reports the failure in its
# JSON while exiting 0. So the validator has to read the JSON, and a stub that exits
# 0 with an error body is the only way to show that it does. The clone here is clean
# and the refresh succeeds, so the refusal can only come from the livecheck check.
CASE_SETUP=setup_clone_clean
CASE_STUBS=stubs_validator_livecheck_unresolved
case_run "a livecheck block that resolves nothing is refused" 1 \
  "livecheck block resolved no version" validate-formula.sh < "$FORMULA"

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) guard tests"
  exit 1
fi
echo "All $pass guard tests pass."
