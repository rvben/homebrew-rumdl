#!/usr/bin/env bash
# Check the two invariants the formula's integrity rests on:
#
#   1. every sha256 is the hash of the artifact at the url directly above it
#   2. every url names the same version
#
# Homebrew normally checks (1) only for the single platform it happens to be
# running on, at install time, in a user's terminal, and checks (2) never. This
# checks both for every platform the formula claims, from anywhere:
#
#   scripts/verify-formula.sh
#
# Reports every platform before exiting non-zero, so one run tells you the
# whole state rather than just the first thing that is wrong.

set -euo pipefail

cd "$(dirname "$0")/.."
FORMULA="Formula/rumdl.rb"

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

# Pair each url with the sha256 line that follows it. Pairing by position is
# the point: that adjacency is exactly what Homebrew acts on, so it is what
# has to be checked.
pairs="$(awk '
  /^[[:space:]]*url "/ {
    if (match($0, /"https:[^"]*"/)) { pending = substr($0, RSTART + 1, RLENGTH - 2) }
    next
  }
  /^[[:space:]]*sha256 "/ {
    if (pending == "") { print "UNPAIRED\tsha256 on line " NR " has no url above it"; exit }
    match($0, /"[^"]*"/)
    print pending "\t" substr($0, RSTART + 1, RLENGTH - 2)
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

# Every url must have been consumed by a sha256 line, and vice versa.
url_count="$(grep -c '^[[:space:]]*url "' "$FORMULA")"
sha_count="$(grep -c '^[[:space:]]*sha256 "' "$FORMULA")"
pair_count="$(printf '%s\n' "$pairs" | wc -l | tr -d ' ')"
if [ "$url_count" != "$sha_count" ] || [ "$pair_count" != "$sha_count" ]; then
  echo "error: $url_count urls, $sha_count sha256 lines, $pair_count pairs - they must agree" >&2
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
  printf '  %s\n' $versions >&2
  exit 1
fi
VERSION="$versions"

# Each url should name its version twice: once in the release path, once in the
# asset filename. Catching a mismatch here matters because the second one is
# part of the filename and a wrong one is a 404 at install time.
expected_mentions=$((url_count * 2))
actual_mentions="$(grep -o "v${VERSION}" "$FORMULA" | wc -l | tr -d ' ')"
if [ "$actual_mentions" != "$expected_mentions" ]; then
  echo "error: expected v$VERSION to appear $expected_mentions times across $url_count urls, found $actual_mentions" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Verifying $FORMULA at version $VERSION ($pair_count platforms)"
echo

failed=0
n=0
while IFS="$(printf '\t')" read -r url want; do
  n=$((n + 1))
  asset="${url##*/}"

  if ! printf '%s' "$want" | grep -Eq '^[0-9a-f]{64}$'; then
    echo "FAIL  $asset"
    echo "      pinned sha256 is not 64 hex characters: '$want'"
    failed=1
    continue
  fi

  if ! curl "${CURL_OPTS[@]}" -o "$tmp/asset.$n" "$url"; then
    echo "FAIL  $asset"
    echo "      could not download $url"
    failed=1
    continue
  fi

  got="$(sha256_of "$tmp/asset.$n")"
  if [ "$got" = "$want" ]; then
    echo "ok    $asset"
  else
    echo "FAIL  $asset"
    echo "      pinned:     $want"
    echo "      downloaded: $got"
    echo "      url:        $url"
    failed=1
  fi
  rm -f "$tmp/asset.$n"
done <<EOF
$pairs
EOF

echo
if [ "$failed" -ne 0 ]; then
  echo "FAILED: at least one pinned sha256 is not the hash of the artifact its url fetches."
  echo "Run scripts/update-formula.sh $VERSION to regenerate the pins."
  exit 1
fi
echo "All $pair_count pins match the artifacts their urls fetch, at version $VERSION."
