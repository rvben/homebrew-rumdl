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
# bash's own =~ rather than grep, because grep matches line by line and so exits
# 0 when ANY line matches: a value whose first line is a bare semver passed this
# however much followed it. Verified - `printf '%s' '1.2.3\nrm -rf /'` piped to
# the old grep exits 0, and the form below rejects it. The value arrives from
# client_payload.version, which is JSON and can carry a literal newline, so this
# is reachable rather than theoretical. It did fail closed further down (awk dies
# with "newline in string" before anything is written), but failing closed by
# accident in an obscure place is not what a guard is for.
if ! [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
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

# The workflow whose signature is accepted as proof that an asset is a rumdl
# release build. Naming it matters: without --signer-workflow, any attestation
# from the repo would do, so a workflow added later with a different trust level
# would count as a release build.
SIGNER_WORKFLOW="rvben/rumdl/.github/workflows/release.yml"

# Checked once, before anything is downloaded, because the per-asset failure is
# indistinguishable from a real provenance failure: an unauthenticated
# `gh attestation verify` exits 4 telling you to run `gh auth login`, which the
# loop below would report as "no valid build provenance", pointing at the release
# instead of at the environment. A hosted runner has no gh login, so the workflow
# passes GH_TOKEN.
if [ "${ALLOW_UNATTESTED:-0}" != "1" ]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: gh is required to verify each asset's build provenance" >&2
    echo "       Install the GitHub CLI, or re-run with ALLOW_UNATTESTED=1 to pin" >&2
    echo "       bytes whose origin has not been checked." >&2
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh is not authenticated, so provenance cannot be verified" >&2
    echo "       Run gh auth login, or set GH_TOKEN. In a workflow, pass" >&2
    echo "       GH_TOKEN: \${{ github.token }} to the step that runs this." >&2
    exit 1
  fi
fi

url_count="$(grep -c '^[[:space:]]*url "' "$FORMULA")"
sha_count="$(grep -c '^[[:space:]]*sha256 "' "$FORMULA")"
if [ "$url_count" != "$sha_count" ]; then
  echo "error: $FORMULA has $url_count urls but $sha_count sha256 lines" >&2
  exit 1
fi

CURRENT_VERSION="$(sed -n 's|.*/releases/download/v\([0-9][0-9.]*\)/.*|\1|p' "$FORMULA" | sort -u)"
if [ -z "$CURRENT_VERSION" ] || [ "$(printf '%s\n' "$CURRENT_VERSION" | wc -l | tr -d ' ')" != "1" ]; then
  echo "error: could not read a single current version from $FORMULA" >&2
  exit 1
fi

# Refuse to move the tap backwards. The version is otherwise taken entirely on
# trust from a dispatch payload, so `{"version":"0.1.0"}` pins v0.1.0's real
# assets, passes every pin check (they are genuinely that release's hashes) and
# pushes, moving every `brew upgrade` onto an older rumdl. This is also reachable
# by accident: the concurrency group serializes queued runs but does not order
# them.
if [ "$VERSION" != "$CURRENT_VERSION" ]; then
  newest="$(printf '%s\n%s\n' "$CURRENT_VERSION" "$VERSION" | sort -V | tail -1)"
  if [ "$newest" != "$VERSION" ] && [ "${ALLOW_DOWNGRADE:-0}" != "1" ]; then
    echo "error: $VERSION is older than the formula's current $CURRENT_VERSION" >&2
    echo "       Refusing to move the tap backwards. To do it deliberately:" >&2
    echo "       ALLOW_DOWNGRADE=1 $0 $VERSION" >&2
    exit 1
  fi
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

  # Check the bytes before pinning them. Up to here the only thing tying an
  # asset to rumdl is the url it came from, and GitHub release assets are
  # mutable: a hash computed now is "whatever those bytes were when this ran",
  # which is how v0.2.76 came to be pinned twice to two different macOS binaries
  # in one day. rumdl's release workflow publishes Sigstore build provenance, so
  # the stronger statement is available for the asking, and asking costs one
  # call per platform.
  if [ "${ALLOW_UNATTESTED:-0}" = "1" ]; then
    printf '    provenance check skipped (ALLOW_UNATTESTED=1)\n'
  elif ! command -v gh >/dev/null 2>&1; then
    echo "error: gh is required to verify the release asset's build provenance" >&2
    echo "       Install the GitHub CLI, or re-run with ALLOW_UNATTESTED=1 to pin" >&2
    echo "       bytes whose origin has not been checked." >&2
    exit 1
  elif ! gh attestation verify "$tmp/asset" \
      --repo rvben/rumdl \
      --signer-workflow "$SIGNER_WORKFLOW" > "$tmp/attestation.log" 2>&1; then
    echo "error: $asset has no valid build provenance from rvben/rumdl" >&2
    echo "       Expected an attestation signed by $SIGNER_WORKFLOW." >&2
    sed 's/^/       /' "$tmp/attestation.log" >&2
    echo "       Refusing to pin bytes that cannot be traced to a rumdl build." >&2
    exit 1
  else
    printf '    provenance ok\n'
  fi

  h="$(sha256_of "$tmp/asset")"
  printf '    %s\n' "$h"
  hashes="$hashes $h"
  printf '%s\n' "$h" >> "$tmp/computed.txt"
  rm -f "$tmp/asset"
done <<EOF
$urls
EOF

# A re-pin of a version the formula already names is never routine, so it does
# not happen quietly. GitHub release assets can be replaced after publication,
# and v0.2.76 proves it is not theoretical: two successful Release runs on that
# one tag produced two separately attested macOS binaries, and the tap followed
# the second set without anyone deciding to. The provenance check above means the
# new bytes are at least a genuine rumdl build, but "a genuine build nobody asked
# to ship" is still a change of what users install under a version they already
# have, so it needs a human.
if [ "$VERSION" = "$CURRENT_VERSION" ]; then
  sed -n 's/^[[:space:]]*sha256 "\([^"]*\)".*/\1/p' "$FORMULA" > "$tmp/existing.txt"
  if ! diff -q "$tmp/existing.txt" "$tmp/computed.txt" >/dev/null 2>&1; then
    if [ "${ALLOW_REPIN:-0}" != "1" ]; then
      echo >&2
      echo "error: the assets for v$VERSION have changed since the formula was pinned" >&2
      echo "       The formula already names v$VERSION, and at least one published" >&2
      echo "       asset now hashes differently than the pin beside its url:" >&2
      paste "$tmp/existing.txt" "$tmp/computed.txt" |
        awk -F'\t' '$1 != $2 { print "         pinned " $1 "\n         now    " $2 }' >&2
      echo "       Every asset above still carries valid rumdl build provenance," >&2
      echo "       so this is a release that was re-run or re-uploaded, not a" >&2
      echo "       tampered download. Decide deliberately, then:" >&2
      echo "       ALLOW_REPIN=1 $0 $VERSION" >&2
      exit 1
    fi
    echo
    echo "ALLOW_REPIN=1: re-pinning v$VERSION to the assets published now."
  fi
fi

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
