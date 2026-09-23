#!/usr/bin/env bash
# Everything CI runs against the formula, runnable locally, in the same order.
# CI runs this exact script, so the two cannot drift apart.
#
#   scripts/validate-formula.sh              # guards, pins, audit, style, strict audit
#   scripts/validate-formula.sh --install    # also brew install + brew test
#
# The pin check comes first and on purpose. `brew audit` and `brew style` say
# nothing about whether a sha256 is the hash of the artifact its url fetches -
# they both passed for eleven months on a formula whose Linux pins were the gnu
# tarballs' hashes while the urls fetched the musl tarballs. A script that
# printed "ready to push" on that formula was worse than no script.
#
# Not interactive: the previous version asked before the checks that cost
# something, so the usual run skipped them and still reported success.

set -euo pipefail

WITH_INSTALL=0
case "${1:-}" in
  "") ;;
  --install) WITH_INSTALL=1 ;;
  *) echo "usage: $0 [--install]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
TAP_DIR="$PWD"

command -v brew >/dev/null 2>&1 || {
  echo "error: Homebrew is not installed" >&2
  echo "The pin check alone needs no brew: scripts/verify-formula.sh" >&2
  exit 1
}

# Before the check, the checker - the same order as CI's `pins` job, because this
# script claims to run what CI runs and a guard-script regression that only CI
# catches makes that claim false. Offline and hermetic, so it costs seconds.
# Running it here also exercises the mutations under BSD sed and BSD awk, which
# the Linux-only `pins` job never does.
echo "==> The guards reject what they are supposed to reject"
scripts/test-guards.sh
echo

echo "==> Every sha256 is the hash of the artifact its url fetches"
scripts/verify-formula.sh
echo

# brew audit/style need the formula to be reachable as a tap. This changes local
# Homebrew state, which is why it happens after the check that does not.
#
# Note for anyone validating an edit locally: this CLONES the repository, so the
# brew checks below see HEAD, not the working tree. Commit first if you want brew
# to see your change. The pin check above reads the working tree directly.
if brew tap | grep -qx rvben/rumdl; then
  # Already tapped, which is the normal state for anyone who has run this before.
  # `brew tap --force` does nothing whatsoever here - Homebrew rescues
  # TapAlreadyTappedError and returns, printing nothing - so every brew check
  # below would run against whatever that clone already holds: an older commit of
  # this repo, or the published tap from GitHub, while the pin check above read
  # this working tree. Verified: re-tapping a local repository whose HEAD had
  # moved on by one commit left the clone on the old commit, silently, and the
  # script then reported success for a formula it had not looked at.
  #
  # Refresh the clone in place rather than untapping it. `brew untap` refuses
  # outright while a keg from the tap is installed, and its --force would
  # uninstall the machine's rumdl to get its way - verified on Linux, where the
  # untap approach aborted the run before it installed anything.
  tap_repo="$(brew --repository rvben/rumdl)"
  [ -n "$tap_repo" ] && [ -d "$tap_repo/.git" ] || {
    echo "error: rvben/rumdl is tapped but $tap_repo is not a git clone" >&2
    exit 1
  }
  echo "==> Refreshing the existing rvben/rumdl tap clone from $TAP_DIR"
  git -C "$tap_repo" fetch --quiet "$TAP_DIR" HEAD

  # The refresh discards whatever is in that clone, and `brew edit
  # rvben/rumdl/rumdl` edits precisely this clone - it is where a contributor's
  # experiment plausibly lives. So look before overwriting: uncommitted changes,
  # untracked files, and commits the clone has that this checkout does not.
  dirty="$(git -C "$tap_repo" status --porcelain)"
  ahead="$(git -C "$tap_repo" rev-list --count FETCH_HEAD..HEAD 2>/dev/null || echo 0)"
  if { [ -n "$dirty" ] || [ "$ahead" != "0" ]; } && [ "${DISCARD_TAP_CLONE:-0}" = "1" ]; then
    echo "    DISCARD_TAP_CLONE=1: discarding $(printf '%s' "$dirty" | grep -c . ) changed path(s) and $ahead local commit(s)"
  elif [ -n "$dirty" ] || [ "$ahead" != "0" ]; then
    echo "error: the rvben/rumdl tap clone holds work this would destroy" >&2
    echo "       $tap_repo" >&2
    [ -n "$dirty" ] && printf '%s\n' "$dirty" | sed 's/^/         /' >&2
    [ "$ahead" != "0" ] && echo "         $ahead commit(s) not in $TAP_DIR" >&2
    echo "       Refreshing it means reset --hard and clean -fd, so this stops here." >&2
    echo "       Keep the work (git -C \"$tap_repo\" stash, or copy it into $TAP_DIR)," >&2
    echo "       or discard it deliberately with DISCARD_TAP_CLONE=1 $0 $*" >&2
    exit 1
  fi

  git -C "$tap_repo" reset --hard --quiet FETCH_HEAD
  git -C "$tap_repo" clean -qfd
  echo "    tap clone now at $(git -C "$tap_repo" rev-parse --short HEAD)"
else
  echo "==> Tapping rvben/rumdl from $TAP_DIR"
  brew tap --force rvben/rumdl "$TAP_DIR"
fi

# Homebrew 7 refuses to load formulae from an untrusted third-party tap. Guarded
# because older Homebrew has no `trust` command at all.
if brew commands 2>/dev/null | tr ' ' '\n' | grep -qx trust; then
  brew trust --tap rvben/rumdl
fi
echo

echo "==> brew audit"
brew audit --formula rvben/rumdl/rumdl
echo

echo "==> brew style"
brew style rvben/rumdl/rumdl
echo

echo "==> brew audit --strict --online"
brew audit --strict --online rvben/rumdl/rumdl
echo

if [ "$WITH_INSTALL" -eq 0 ]; then
  echo "Pins, audit and style pass. Install and test not run; pass --install for those."
  exit 0
fi

# rumdl is also a homebrew-core formula. If core's copy is already installed,
# brew refuses to install this tap's over it, and the error is easy to misread as
# a problem with the formula. Say so plainly instead, and do not pretend the
# remaining checks ran.
#
# Which tap an installed keg came from is recorded only in its install receipt.
# `brew info --json=v2 rumdl` resolves the bare name to homebrew-core and its
# keg entries carry no tap at all, so reading the formula's own `tap` field
# would report homebrew/core for a keg this tap installed and refuse a perfectly
# good --install run.
installed_from=""
ours_installed=0
# No `|| true` here. `brew --cellar rumdl` exits 0 and prints the path even when
# rumdl is not installed, so an empty value means the resolution failed, not that
# nothing is installed - and swallowing it skips the whole guard below, deciding
# "nothing is installed" silently. That is the same wrong-answer-dressed-as-a-pass
# the receipt parsing further down was fixed for. If the formula cannot be
# resolved, fall back to the deterministic path under the prefix rather than
# guessing or aborting.
if ! cellar="$(brew --cellar rumdl 2>/dev/null)" || [ -z "$cellar" ]; then
  # Assigned inside the `if` for the same reason: a bare
  # `cellar="$(brew --cellar)/rumdl"` aborts the script with no message at all
  # under set -e when that call fails too, which is this defect again one line
  # further down.
  if prefix_cellar="$(brew --cellar 2>/dev/null)" && [ -n "$prefix_cellar" ]; then
    cellar="$prefix_cellar/rumdl"
    echo "    note: brew could not resolve rumdl's cellar; checking $cellar"
  else
    echo "error: brew cannot report its Cellar path." >&2
    echo "       Whether another tap's rumdl is installed cannot be determined," >&2
    echo "       and guessing would either skip a real conflict or block a good run." >&2
    exit 1
  fi
fi
if [ -d "$cellar" ]; then
  for receipt in "$cellar"/*/INSTALL_RECEIPT.json; do
    [ -f "$receipt" ] || continue
    # sed rather than a JSON parser: Homebrew writes this file pretty-printed
    # with exactly one "tap" key, and the check must not depend on an
    # interpreter the machine may not have. A python3 version of this silently
    # decided "nothing is installed" on a host without python3, which is the
    # wrong answer dressed as a passing check.
    tap="$(sed -n 's/.*"tap":[[:space:]]*"\([^"]*\)".*/\1/p' "$receipt" | head -1)"
    if [ -z "$tap" ]; then
      echo "error: $receipt records no source tap." >&2
      echo "       Which tap installed this rumdl cannot be determined, and" >&2
      echo "       guessing would either skip a real conflict or block a good run." >&2
      echo "       Run 'brew uninstall rumdl' first, or drop --install." >&2
      exit 1
    fi
    if [ "$tap" != "rvben/rumdl" ]; then
      installed_from="$tap"
      break
    fi
    # A keg this tap installed. Recorded here, from the same receipt parse, so
    # that the install step below knows to replace it rather than deciding from
    # a formula name that resolves to homebrew-core.
    ours_installed=1
  done
fi
if [ -n "$installed_from" ]; then
  echo "error: rumdl is already installed from the $installed_from tap." >&2
  echo "       brew will not install this tap's copy over it." >&2
  echo "       Run 'brew uninstall rumdl' first, or drop --install." >&2
  exit 1
fi

# Reinstall rather than install when a keg from this tap is already there.
# `brew install` on an installed keg exits 0 without doing anything - it just
# prints "To reinstall ..., run brew reinstall" - so `brew test` below would
# exercise the binary that was already on the machine instead of the one this
# formula fetches. That passes for a formula whose install stanza or pins have
# changed, which is the only reason to be running this.
if [ "$ours_installed" -eq 1 ]; then
  echo "==> brew reinstall (a keg from this tap is already installed)"
  brew reinstall --verbose rvben/rumdl/rumdl
else
  echo "==> brew install"
  brew install --verbose rvben/rumdl/rumdl
fi
echo

echo "==> brew test"
brew test rvben/rumdl/rumdl
echo

# Call the installed binary by its full path. A plain `rumdl` can resolve to
# something else entirely - on a machine with mise or asdf shims, brew itself
# warns that its binary is shadowed - and then this proves nothing about what was
# just installed.
# And no fallback to `$(brew --prefix)/bin/rumdl`: that is whichever rumdl is
# currently linked into Homebrew's bin, which after a successful install of THIS
# formula may still be another tap's or another version's. The fallback could only
# ever run in exactly the situation where the binary's provenance is unknown,
# which is the situation the paragraph above exists to prevent. A keg that does
# not resolve right after `brew install rvben/rumdl/rumdl` succeeded is a failure
# to report, not a reason to test something else.
if ! keg="$(brew --prefix rvben/rumdl/rumdl 2>/dev/null)" || [ -z "$keg" ]; then
  echo "error: brew install reported success but rvben/rumdl/rumdl has no prefix" >&2
  echo "       Refusing to fall back to \$(brew --prefix)/bin/rumdl, which may be" >&2
  echo "       another tap's or another version's binary." >&2
  exit 1
fi
RUMDL="$keg/bin/rumdl"
echo "==> The installed binary lints ($RUMDL)"
[ -x "$RUMDL" ] || { echo "error: $RUMDL is not executable" >&2; exit 1; }
"$RUMDL" --version

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '# Heading\nNo blank line below the heading.\n' > "$tmp/bad.md"
printf '# Heading\n\nA blank line below the heading.\n' > "$tmp/good.md"

# Two bounds, and the exit code read exactly rather than as "nonzero". rumdl
# exits 1 for violations, 0 for a clean file and 2 when it cannot run at all -
# so `if ! rumdl check` accepted a config error, a missing argument or a crash as
# proof that the binary detects MD022. Verified: an unparseable .rumdl.toml exits
# 2 having linted nothing. --no-config for the same reason as in the formula's
# test do: otherwise this depends on whatever config discovery walks up into.
smoke() { # smoke <file> <expected exit> <expected substring>
  # Inside the `if`, because `out="$(cmd)"` under set -e aborts the moment cmd
  # exits nonzero - which is every interesting case here, including the one this
  # check exists for.
  if out="$("$RUMDL" check --no-config "$1" 2>&1)"; then code=0; else code=$?; fi
  if [ "$code" != "$2" ] || ! printf '%s' "$out" | grep -q "$3"; then
    echo "error: $RUMDL check ${1##*/} exited $code (want $2)" >&2
    echo "       and its output ${3:+did not contain \"$3\"}" >&2
    printf '%s\n' "$out" | sed 's/^/       /' >&2
    exit 1
  fi
  echo "    ${1##*/}: exit $code, output mentions $3"
}
smoke "$tmp/bad.md" 1 MD022
smoke "$tmp/good.md" 0 Success
echo

echo "All checks passed, install and test included."
