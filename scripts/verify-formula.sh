#!/usr/bin/env bash
# Check the invariants the formula's integrity rests on:
#
#   1. every url points at rumdl's own releases
#   2. the formula still ships every platform it is supposed to ship
#   3. every sha256 is the hash of the artifact at the url directly above it
#   4. every url names the same version
#   5. every archive actually contains a rumdl binary to install
#   6. each url sits in the platform branch its filename claims, each branch
#      appearing exactly once
#   7. the binary inside is built for that branch's architecture, and the Linux
#      ones are the static musl builds the formula says they are
#
# Homebrew normally checks (3) only for the single platform it happens to be
# running on, at install time, in a user's terminal, and checks none of the
# others ever. This checks all of them for every platform, from anywhere:
#
#   scripts/verify-formula.sh
#
# Reports every platform before exiting non-zero, so one run tells you the
# whole state rather than just the first thing that is wrong.

set -euo pipefail

cd "$(dirname "$0")/.."
FORMULA="Formula/rumdl.rb"

# This script takes no arguments: it checks the committed formula, whatever
# version that names. Silently ignoring one turns a plausible invocation into a
# wrong answer dressed as a pass - `verify-formula.sh 0.2.77` reads as "check
# 0.2.77" and would report every pin matching while having checked the version
# already in the file.
if [ "$#" -ne 0 ]; then
  echo "error: verify-formula.sh takes no arguments, got: $*" >&2
  echo "       It checks $FORMULA as committed. To check a different version," >&2
  echo "       update the formula first (scripts/update-formula.sh <version>)." >&2
  exit 2
fi

[ -f "$FORMULA" ] || { echo "error: $FORMULA not found" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Bounded, because a stalled GitHub download hangs forever without --max-time
# and would sit in a workflow until the runner's own limit killed it. No
# --retry-all-errors here, unlike the updater: this checks an already published
# formula, so a 404 is a real answer and should fail fast rather than be waited
# out.
CURL_OPTS=(
  --fail --silent --show-error --location
  --connect-timeout 20 --max-time 180
  --retry 3 --retry-delay 2 --retry-max-time 60
)

# Pair each url with the sha256 line that follows it, and carry the platform
# branch each pair sits in. Pairing by position is the point: that adjacency is
# exactly what Homebrew acts on, so it is what has to be checked. The branch
# comes along because the pair alone says nothing about which machine Homebrew
# will hand it to - see the target/arch checks below.
#
# The two condition patterns are anchored whole-line, and any other line
# mentioning Hardware::CPU is an error rather than something to interpret,
# because the branch a url sits in has to be read the way Ruby reads it and not
# by noticing a predicate somewhere on the line. Matching `Hardware::CPU.intel?`
# anywhere bound the context by substring: measured on this formula, changing
# `if Hardware::CPU.intel?` to `if !Hardware::CPU.intel?` - or to `unless` -
# left every check here satisfied and reported all four pins matching, on a
# formula that hands an arm64 Mac the x86_64 archive and an Intel Mac no archive
# at all. Comment lines are skipped for the same reason from the other side: a
# comment naming the other predicate used to move the url into the other branch,
# so `# not Hardware::CPU.arm? here` inside the Intel branch failed the run with
# a message about the wrong branch carrying the wrong target.
pairs="$(awk '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*on_macos do/ { os = "macos"; cpu = ""; next }
  /^[[:space:]]*on_linux do/ { os = "linux"; cpu = ""; next }
  /^[[:space:]]*(els)?if[[:space:]]+Hardware::CPU\.intel\?[[:space:]]*$/ { cpu = "intel"; next }
  /^[[:space:]]*(els)?if[[:space:]]+Hardware::CPU\.arm\?[[:space:]]*$/   { cpu = "arm";   next }
  /Hardware::CPU/ {
    print "UNPARSED\tline " NR " decides a platform branch in a way this script does not read: " $0
    exit
  }
  /^[[:space:]]*url "/ {
    if (match($0, /"https:[^"]*"/)) {
      pending = substr($0, RSTART + 1, RLENGTH - 2)
      pending_ctx = (os == "" || cpu == "") ? "unbound" : os ":" cpu
    }
    next
  }
  /^[[:space:]]*sha256 "/ {
    if (pending == "") { print "UNPAIRED\tsha256 on line " NR " has no url above it"; exit }
    match($0, /"[^"]*"/)
    print pending "\t" substr($0, RSTART + 1, RLENGTH - 2) "\t" pending_ctx
    pending = ""
  }
' "$FORMULA")"

[ -n "$pairs" ] || { echo "error: no url/sha256 pairs found in $FORMULA" >&2; exit 1; }

# On any line, not just the first: awk emits this and stops the moment it sees a
# sha256 with no url above it, which for `url, sha, sha, url` is the second line
# of the output. Anchoring the check to the start of $pairs missed exactly that
# case, and the url/sha/pair counts all agree on it (2, 2, 2), so the run fell
# through to the download loop and reported the marker text as a malformed pin.
unpaired="$(printf '%s\n' "$pairs" | sed -n 's/^UNPAIRED	//p')"
if [ -n "$unpaired" ]; then
  echo "error: $unpaired" >&2
  exit 1
fi

# A condition this script cannot read is a refusal, not a default. Guessing the
# branch is how a negated condition passed: the alternative to failing here is
# binding a url to the machine that will not get it.
unparsed="$(printf '%s\n' "$pairs" | sed -n 's/^UNPARSED	//p')"
if [ -n "$unparsed" ]; then
  echo "error: $unparsed" >&2
  echo "       Each platform branch must be exactly \`if Hardware::CPU.intel?\` or" >&2
  echo "       \`elsif Hardware::CPU.arm?\` (or the intel/arm pair the other way" >&2
  echo "       round), with nothing else on the line. Homebrew evaluates the" >&2
  echo "       condition; this script has to agree with it about which machine" >&2
  echo "       each url is for, and it can only do that for those two shapes." >&2
  exit 1
fi

# Every url must have been consumed by a sha256 line, and vice versa.
url_count="$(grep -c '^[[:space:]]*url "' "$FORMULA")"
sha_count="$(grep -c '^[[:space:]]*sha256 "' "$FORMULA")"
pair_count="$(printf '%s\n' "$pairs" | wc -l | tr -d ' ')"
if [ "$url_count" != "$sha_count" ] || [ "$pair_count" != "$sha_count" ]; then
  echo "error: $url_count urls, $sha_count sha256 lines, $pair_count pairs - they must agree" >&2
  exit 1
fi

# Every url must fetch from rumdl's own releases. Nothing else in the chain
# checks this: a host serving bytes that match the pins satisfies every other
# check in this script, and `brew audit --strict --online` does not require a
# url's owner to match the homepage. Verified with a control - a formula whose
# url pointed at another project's release asset, pinned to that asset's real
# hash, passed every structural check and every hash comparison and reported
# "All 1 pins match".
ORIGIN_PREFIX="https://github.com/rvben/rumdl/releases/download/v"
bad_origin=0
while IFS="$(printf '\t')" read -r url _; do
  case "$url" in
    "$ORIGIN_PREFIX"*) ;;
    *)
      echo "error: url does not fetch from rumdl's own releases: $url" >&2
      bad_origin=1
      ;;
  esac
done <<EOF
$pairs
EOF
if [ "$bad_origin" -ne 0 ]; then
  echo "error: every url must begin ${ORIGIN_PREFIX}<version>/" >&2
  exit 1
fi

# The platforms the formula is expected to ship, listed here deliberately rather
# than derived from the formula. Deriving it from the file cannot detect the file
# losing a platform: remove a url and its sha256 together and the url, sha and
# pair counts all stay equal, so the run passes and cheerfully reports one
# platform fewer. Verified with a control - deleting the x86_64-apple-darwin
# block gave "All 3 pins match", exit 0, while macOS Intel users would have been
# left with no bottle at all. Adding or renaming a platform is meant to require
# an edit here; that is the check, not an inconvenience.
#
# That control predates the branch checks below, which now catch a dropped
# platform as well (each branch must appear exactly once, carrying its own
# target), so this list is no longer the only thing standing between a dropped
# platform and a green run. It stays because it names the four targets in one
# place and says which one went missing, and because a check that is redundant
# today stops being redundant the moment the checks it overlaps with are edited.
EXPECTED_TARGETS="aarch64-apple-darwin
aarch64-unknown-linux-musl
x86_64-apple-darwin
x86_64-unknown-linux-musl"

got_targets="$(printf '%s\n' "$pairs" | cut -f1 |
  sed -e 's|.*/rumdl-v[0-9][0-9.]*-||' -e 's|\.tar\.gz$||' | sort)"
if [ "$got_targets" != "$(printf '%s\n' "$EXPECTED_TARGETS" | sort)" ]; then
  echo "error: $FORMULA does not ship the expected set of platforms" >&2
  echo "  missing:    $(comm -23 <(printf '%s\n' "$EXPECTED_TARGETS" | sort) <(printf '%s\n' "$got_targets") | tr '\n' ' ')" >&2
  echo "  unexpected: $(comm -13 <(printf '%s\n' "$EXPECTED_TARGETS" | sort) <(printf '%s\n' "$got_targets") | tr '\n' ' ')" >&2
  exit 1
fi

# Which machine Homebrew hands each url to is decided by the `on_macos` /
# `on_linux` and `Hardware::CPU` branch the url sits in, and nothing above reads
# that. Every check so far is satisfied by a formula whose four urls are the four
# expected ones arranged in the wrong branches: the set of targets is unchanged,
# every pin matches its own artifact, and every url names the same version.
# Verified with a control - swapping the two macOS url/sha256 pairs between the
# intel and arm branches gave "All 4 pins match", exit 0, on a formula that hands
# Intel Macs an arm64-only binary. CI cannot see it either: the matrix is arm
# macOS and x86_64 Linux, so a swap confined to the other two branches is
# executed nowhere.
#
# So each branch declares the target it must carry, and the binary's own
# architecture is checked against it further down. This is the same defect class
# as the one this whole script exists for - a pin that belongs to a different
# artifact - moved one step sideways into the filename.
target_for_context() { # target_for_context <os:cpu>
  case "$1" in
    macos:intel) echo "x86_64-apple-darwin" ;;
    macos:arm)   echo "aarch64-apple-darwin" ;;
    linux:intel) echo "x86_64-unknown-linux-musl" ;;
    linux:arm)   echo "aarch64-unknown-linux-musl" ;;
    *)           echo "" ;;
  esac
}

# What `file` must say about the binary inside that branch's archive. The arch
# half catches an archive built for another machine; `statically linked` on the
# Linux rows is the only check anywhere that the musl urls really are the static
# musl builds the formula's own comment gives as the reason for choosing them -
# the gnu tarball of the same version is byte-different and reports
# "dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2", so a url quietly
# moved to the gnu asset becomes self-consistent under every other check here.
# Strings taken from the real v0.2.76 assets, not guessed.
file_must_match() { # file_must_match <os:cpu>
  case "$1" in
    macos:intel) echo "Mach-O.*x86_64" ;;
    macos:arm)   echo "Mach-O.*arm64" ;;
    linux:intel) echo "ELF.*x86-64.*statically linked" ;;
    linux:arm)   echo "ELF.*aarch64.*statically linked" ;;
    *)           echo "" ;;
  esac
}

bad_context=0
while IFS="$(printf '\t')" read -r url _ ctx; do
  asset="${url##*/}"
  expect="$(target_for_context "$ctx")"
  if [ -z "$expect" ]; then
    echo "error: $asset sits in no recognised platform branch (context '$ctx')" >&2
    echo "       Every url must be inside on_macos/on_linux and a Hardware::CPU branch." >&2
    bad_context=1
  else
    case "$asset" in
      *"-$expect.tar.gz") ;;
      *)
        echo "error: the $ctx branch must carry $expect, but its url is $asset" >&2
        bad_context=1
        ;;
    esac
  fi
done <<EOF
$pairs
EOF
if [ "$bad_context" -ne 0 ]; then
  echo "error: at least one url is in the wrong platform branch" >&2
  exit 1
fi

# And each branch exactly once, so a duplicated branch cannot stand in for a
# missing one.
ctx_list="$(printf '%s\n' "$pairs" | cut -f3 | sort)"
if [ "$ctx_list" != "$(printf 'linux:arm\nlinux:intel\nmacos:arm\nmacos:intel\n')" ]; then
  echo "error: the formula does not declare each platform branch exactly once:" >&2
  printf '%s\n' "$ctx_list" | sed 's/^/  /' >&2
  exit 1
fi

# The version is not declared in the formula (Homebrew scans it from the urls,
# and declaring it too fails brew audit), so the urls have to agree among
# themselves. A half-rewritten formula - some platforms moved to the new
# release, some left behind - would otherwise be invisible here and would
# install different versions depending on who ran it.
versions="$(sed -n 's|.*/releases/download/v\([0-9][0-9.]*\)/.*|\1|p' "$FORMULA" | sort -u)"
version_count="$(printf '%s\n' "$versions" | wc -l | tr -d ' ')"
if [ -z "$versions" ]; then
  echo "error: no release version could be read from the urls in $FORMULA" >&2
  exit 1
fi
if [ "$version_count" != "1" ]; then
  echo "error: the urls in $FORMULA name more than one version:" >&2
  printf '%s\n' "$versions" | sed 's/^/  /' >&2
  exit 1
fi
VERSION="$versions"

# Each url should name its version twice: once in the release path, once in the
# asset filename. Catching a mismatch here matters because the second one is
# part of the filename and a wrong one is a 404 at install time.
#
# -F, because the version's dots are regex metacharacters otherwise and this is
# an exact-count comparison: measured, `grep -o "v0.2.77"` counts `v0X2X77` as a
# mention, so a filename with the version mangled that way reaches the expected
# count and the check passes on a url that 404s. Over-counting is the only
# direction this can err in, and it is the direction that hides a defect.
expected_mentions=$((url_count * 2))
actual_mentions="$(grep -oF "v${VERSION}" "$FORMULA" | wc -l | tr -d ' ')"
if [ "$actual_mentions" != "$expected_mentions" ]; then
  echo "error: expected v$VERSION to appear $expected_mentions times across $url_count urls, found $actual_mentions" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Verifying $FORMULA at version $VERSION ($pair_count platforms)"
echo

# Four checks fail in this loop and they call for three different actions, so
# what failed is recorded per asset rather than as one flag. Printing the same
# "regenerate the pins" line for all of them is worse than printing none: a url
# that timed out says nothing about its pin, and an asset whose archive cannot
# install is wrong at the release, so re-pinning writes a fresh hash for the same
# unusable bytes.
failed=0
kinds=""
note_failure() { # note_failure <kind>
  failed=$((failed + 1))
  case " $kinds " in
    *" $1 "*) ;;
    *) kinds="$kinds $1" ;;
  esac
}

n=0
while IFS="$(printf '\t')" read -r url want ctx; do
  n=$((n + 1))
  asset="${url##*/}"

  if ! printf '%s' "$want" | grep -Eq '^[0-9a-f]{64}$'; then
    echo "FAIL  $asset"
    echo "      pinned sha256 is not 64 hex characters: '$want'"
    note_failure format
    continue
  fi

  if ! curl "${CURL_OPTS[@]}" -o "$tmp/asset.$n" "$url"; then
    echo "FAIL  $asset"
    echo "      could not download $url"
    note_failure download
    continue
  fi

  got="$(sha256_of "$tmp/asset.$n")"
  if [ "$got" = "$want" ]; then
    # A matching hash proves the bytes are the ones that were pinned, and
    # nothing more. `def install` does `bin.install "rumdl"`, so an archive
    # whose layout or binary name changed satisfies every check above and then
    # fails at install time for every user on that platform. One `tar` listing
    # per asset turns that into a pre-push failure.
    #
    # Matched against the whole entry, with only a leading `./` removed: a
    # directory lists as `rumdl/`, so trimming at the first slash accepted an
    # archive holding a `rumdl/` directory and no binary at all. And the name
    # alone is not the requirement either - `bin.install` needs a file it can
    # install, so the member is extracted and checked for being a non-empty
    # regular file with an execute bit.
    if tar tzf "$tmp/asset.$n" 2>/dev/null | sed 's|^\./||' | grep -qx rumdl &&
       rm -rf "$tmp/x.$n" && mkdir -p "$tmp/x.$n" &&
       tar xzf "$tmp/asset.$n" -C "$tmp/x.$n" 2>/dev/null &&
       [ -f "$tmp/x.$n/rumdl" ] && [ -s "$tmp/x.$n/rumdl" ] && [ -x "$tmp/x.$n/rumdl" ]; then
      # The binary is here, so ask it what it is rather than trusting the
      # filename. This is the half the filename check above cannot do: an asset
      # built for the wrong machine, or a Linux url moved to the dynamically
      # linked gnu build, keeps its name and its hash.
      want_file="$(file_must_match "$ctx")"
      got_file="$(file -b "$tmp/x.$n/rumdl" 2>/dev/null || echo "file(1) said nothing")"
      if printf '%s' "$got_file" | grep -Eq "$want_file"; then
        echo "ok    $asset"
      else
        echo "FAIL  $asset"
        echo "      hash matches and a rumdl binary is present, but it is not the"
        echo "      architecture the $ctx branch needs"
        echo "      expected:   $want_file"
        echo "      file says:  $got_file"
        note_failure asset
      fi
    else
      echo "FAIL  $asset"
      echo "      hash matches, but the archive has no installable 'rumdl' binary"
      echo "      contents:   $(tar tzf "$tmp/asset.$n" 2>/dev/null | head -5 | tr '\n' ' ')"
      echo "      def install does bin.install \"rumdl\", so this cannot install"
      note_failure asset
    fi
    rm -rf "$tmp/x.$n"
  else
    echo "FAIL  $asset"
    echo "      pinned:     $want"
    echo "      downloaded: $got"
    echo "      url:        $url"
    note_failure mismatch
  fi
  rm -f "$tmp/asset.$n"
done <<EOF
$pairs
EOF

echo
if [ "$failed" -ne 0 ]; then
  echo "FAILED: $failed of $pair_count platforms did not verify."
  case " $kinds " in *" download "*)
    echo "  - An asset could not be downloaded. That says nothing about its pin:"
    echo "    check the release still carries that asset, then re-run."
    ;;
  esac
  case " $kinds " in *" asset "*)
    echo "  - An asset's hash matched, but what it contains cannot be installed on"
    echo "    the platform it is pinned for. The release upload is wrong, so"
    echo "    re-pinning would pin the same unusable archive under a fresh hash."
    ;;
  esac
  # Two kinds, one action, and still two diagnoses: a pin that is not 64 hex
  # characters is not a hash of anything, which a half-finished edit leaves behind
  # and which "not the hash of its artifact" understates.
  case " $kinds " in *" format "*)
    echo "  - A pin is not 64 hexadecimal characters, so the formula is malformed"
    echo "    rather than out of date."
    ;;
  esac
  case " $kinds " in *" mismatch "*)
    echo "  - A pin is not the hash of the artifact its url fetches."
    ;;
  esac
  case " $kinds " in *" format "*|*" mismatch "*)
    echo "    Run scripts/update-formula.sh $VERSION to regenerate the pins."
    ;;
  esac
  exit 1
fi
echo "All $pair_count pins match the artifacts their urls fetch, at version $VERSION."
