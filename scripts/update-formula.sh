#!/usr/bin/env bash
# Point Formula/rumdl.rb at a rumdl release, pinning each platform's sha256.
#
#   scripts/update-formula.sh 0.2.76
#
# The formula's own url lines decide which asset each platform gets, and this
# hashes exactly the assets those urls name. There is deliberately no list of
# platforms here: a second list is a second thing to keep in sync, and a pin
# belonging to a different artifact than the url beside it is precisely the
# defect this replaced (the Linux pins were the gnu tarballs' hashes while the
# urls fetched the musl tarballs, for every release up to v0.2.76).
#
# Any download failure aborts. A partially updated formula - new version, one
# platform still carrying the previous release's pin - installs for some users
# and fails checksum verification for others, which is worse than not updating.

set -euo pipefail

usage() { echo "usage: $0 <version>   e.g. $0 0.2.76" >&2; exit 2; }

[ $# -eq 1 ] || usage
VERSION="${1#v}"

# Also the injection guard: this value reaches curl, a url and the formula text.
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "error: version must look like 1.2.3, got '$1'" >&2
  exit 2
fi

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

# Bounded on purpose, in every direction. A GitHub download that stalls mid
# transfer hangs with no timeout at all, and in a workflow that means the job
# sits there until the runner's own limit kills it hours later. --retry-max-time
# caps the retry window as a whole, so the total wait is predictable rather than
# retries times timeout. --retry-all-errors is what makes a 404 retryable: this
# runs seconds after rumdl's release workflow uploads the assets, and curl does
# not retry a 404 on its own, so a release that is merely a moment early would
# otherwise abort the whole update.
CURL_OPTS=(
  --fail --silent --show-error --location
  --connect-timeout 20 --max-time 180
  --retry 5 --retry-delay 5 --retry-all-errors --retry-max-time 180
)

url_count="$(grep -c '^[[:space:]]*url "' "$FORMULA")"
sha_count="$(grep -c '^[[:space:]]*sha256 "' "$FORMULA")"
if [ "$url_count" != "$sha_count" ]; then
  echo "error: $FORMULA has $url_count urls but $sha_count sha256 lines" >&2
  exit 1
fi

# Rewrite the version inside the urls first, then hash what those urls now
# point at. Doing it in this order means the hashes can only ever be of the
# assets the written formula actually fetches.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

awk -v version="$VERSION" '
  /^[[:space:]]*url "/ {
    # Twice per url: once in the release path, once in the asset filename.
    n = gsub(/v[0-9]+\.[0-9]+\.[0-9]+/, "v" version)
    if (n != 2) {
      print "awk: url on line " NR " mentions a version " n " times, expected 2" > "/dev/stderr"
      exit 1
    }
  }
  { print }
' "$FORMULA" > "$tmp/versioned.rb"

urls="$(sed -n 's/^[[:space:]]*url "\(https:[^"]*\)".*/\1/p' "$tmp/versioned.rb")"
[ -n "$urls" ] || { echo "error: no asset urls found in $FORMULA" >&2; exit 1; }

echo "Updating $FORMULA to rumdl $VERSION ($url_count platforms)"
echo

hashes=""
n=0
while IFS= read -r url; do
  n=$((n + 1))
  asset="${url##*/}"
  printf '  %s\n' "$asset"
  if ! curl "${CURL_OPTS[@]}" -o "$tmp/asset" "$url"; then
    echo "error: could not download $url" >&2
    echo "error: refusing to write a formula with a stale or missing pin" >&2
    exit 1
  fi
  h="$(sha256_of "$tmp/asset")"
  printf '    %s\n' "$h"
  hashes="$hashes $h"
  rm -f "$tmp/asset"
done <<EOF
$urls
EOF

awk -v hashlist="$hashes" '
BEGIN { nh = split(hashlist, H, " ") }
{
  if ($0 ~ /^[[:space:]]*sha256 "/) {
    i++
    if (i > nh) { print "awk: more sha256 lines than hashes" > "/dev/stderr"; exit 1 }
    sub(/sha256 "[^"]*"/, "sha256 \"" H[i] "\"")
  }
  print
}
END { if (i != nh) { print "awk: wrote " i " of " nh " hashes" > "/dev/stderr"; exit 1 } }
' "$tmp/versioned.rb" > "$tmp/rumdl.rb"

# Keep the formula as it was until the written one has been proved good. The
# verification below downloads every asset a second time, so a transient network
# failure there would otherwise leave a half-trusted formula in the working tree
# while the script reports failure - and the next run of anything that reads the
# formula would take it as the current pins.
#
# The restore hangs off the trap rather than off the verification-failed branch
# alone, because the copy it restores from lives in $tmp and the trap deletes
# $tmp. A run that ends between the write below and the end of verification -
# Ctrl-C, or a cancelled CI job - would otherwise take the only copy of the
# original with it and leave the rewritten formula in place, unverified and
# unmentioned.
ORIGINAL="$tmp/original.rb"
cp "$FORMULA" "$ORIGINAL"

restore_unverified() {
  [ -n "${ORIGINAL:-}" ] && [ -f "$ORIGINAL" ] || return 0
  cat "$ORIGINAL" > "$FORMULA"
  echo >&2
  echo "error: $FORMULA was restored to its previous contents; its new pins were never verified" >&2
}

trap 'restore_unverified; rm -rf "$tmp"' EXIT
# Exit from these handlers so that the EXIT trap above runs. Without them a
# signal kills the shell directly and the rewritten formula stays behind.
trap 'exit 130' INT
trap 'exit 143' TERM

cat "$tmp/rumdl.rb" > "$FORMULA"

echo
echo "Wrote $FORMULA. Verifying against the published artifacts:"
echo
scripts/verify-formula.sh

# Verified, so keep what was written: stop the trap from undoing it.
ORIGINAL=""
