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

# `git -C <dir>` does not override GIT_DIR. With GIT_DIR set - which git exports to
# every hook it runs, and a pre-push hook calling this script is the obvious way
# to make the local gate automatic - every git command below reads and writes the
# repository GIT_DIR names rather than the one `-C` points at, including the one
# that decides whether the tap clone holds work worth keeping, three lines above
# a `reset --hard` and a `clean -fd`. Verified: `GIT_DIR=$other/.git git -C "$repo"
# rev-parse --short HEAD` prints the OTHER repository's commit.
#
# The GIT_CONFIG_* group is here for the same reason one step removed: it does not
# change which repository a command reads, it changes what that command is willing
# to report about it. GIT_CONFIG_COUNT with status.showUntrackedFiles=no makes the
# inventory below come back empty on a clone full of untracked files. Verified:
# `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=status.showUntrackedFiles
# GIT_CONFIG_VALUE_0=no git status --porcelain` prints nothing beside an untracked
# file, and the explicit --untracked-files flag on the status call overrides it.
#
# Cleared rather than refused, so running this from a hook keeps working, and
# announced rather than cleared silently, because changing which repository a
# command means is not something to do quietly.
git_overrides=""
for _v in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
          GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
          GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM; do
  if [ -n "${!_v:-}" ]; then
    git_overrides="$git_overrides $_v"
  fi
done
if [ -n "$git_overrides" ]; then
  echo "==> Clearing inherited git repository overrides:$git_overrides"
  echo "    They redirect every git command in this script, or narrow what it will"
  echo "    report, including the check that decides whether refreshing the tap"
  echo "    clone would destroy work."
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
        GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
        GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM
  echo
fi

command -v brew >/dev/null 2>&1 || {
  echo "error: Homebrew is not installed" >&2
  echo "The pin check alone needs no brew: scripts/verify-formula.sh" >&2
  exit 1
}

# First, in CI's order. Every check in this repository is a shell script, so a
# shell defect is a guard defect.
#
# Version drift is real here and CI is the authority: the runner ships shellcheck
# 0.9.0, a Homebrew machine currently has 0.11.0, and the older one is the stricter
# of the two - 0.9.0 rejected an `A && B || C` line that 0.11.0 accepted silently,
# which is a lint that passes locally and fails in CI. So a clean run here is not a
# promise of a clean `pins` job on an older shellcheck.
echo "==> The scripts are free of shell defects"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --version | sed -n 2p
  shellcheck scripts/*.sh
else
  # Reported, not silently skipped and not fatal. The gate is CI's `pins` job,
  # which requires shellcheck and runs on a runner that has it; this call is the
  # local convenience copy. Making it fatal here broke both macOS brew jobs on the
  # first push, because the GitHub macOS images carry no shellcheck, and
  # `brew install shellcheck` in four jobs to re-run what `pins` already ran is
  # cost for nothing. What matters is that a run without it says so rather than
  # reporting a clean lint.
  echo "    shellcheck is not installed, so the shell lint did NOT run here."
  echo "    CI's pins job is the gate for it. Locally: brew install shellcheck"
fi
echo

# Same arrangement, same reason: the gate is the pins job, which pins the version
# and checks its hash. Invalid workflow YAML produces no run rather than a failing
# one, so this is not a lint whose absence should pass unmentioned.
echo "==> The workflows are valid"
if command -v actionlint >/dev/null 2>&1; then
  actionlint --version | head -n 1
  actionlint
else
  echo "    actionlint is not installed, so the workflows were NOT checked here."
  echo "    CI's pins job is the gate for it. Locally: brew install actionlint"
fi
echo

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

# Which formula the brew checks are about to read. Everything above read the
# working tree; everything below reads a CLONE of this repository at HEAD, and
# those are the same bytes only while the formula is committed. The difference is
# invisible in the output otherwise: an uncommitted install stanza collects a
# clean `brew audit`, a passing `brew test` and a final "all checks passed" line
# from a run that never looked at it. So the run says which tree answered, and
# says so again at the end, where the claim is made.
# Three states, not two. "There is no HEAD to compare against" is a different
# fact from "the formula matches HEAD", and reading the first as the second is how
# a checkout with no commits at all - a fresh `git init`, a clone interrupted
# before its first fetch - collects a report saying the committed formula was
# audited.
HEAD_SHA=""
FORMULA_STATE=committed
if ! git -C "$TAP_DIR" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  FORMULA_STATE=unknown
else
  HEAD_SHA="$(git -C "$TAP_DIR" rev-parse --short HEAD)"
  # `diff HEAD` covers staged and unstaged alike; `ls-files --error-unmatch`
  # covers the formula being untracked, which `diff` reports as no difference.
  if ! git -C "$TAP_DIR" ls-files --error-unmatch Formula/rumdl.rb >/dev/null 2>&1 ||
     ! git -C "$TAP_DIR" diff --quiet HEAD -- Formula/rumdl.rb; then
    FORMULA_STATE=uncommitted
  fi
fi
if [ "$FORMULA_STATE" = uncommitted ]; then
  echo "==> WARNING: Formula/rumdl.rb differs from HEAD ($HEAD_SHA)"
  echo "    The pin check above read your working tree. Every brew check below"
  echo "    reads a clone of this repository at HEAD, so your edit is NOT what"
  echo "    brew audits, installs or tests. Commit it first to validate it."
  echo
elif [ "$FORMULA_STATE" = unknown ]; then
  echo "==> WARNING: $TAP_DIR has no HEAD commit"
  echo "    Whether Formula/rumdl.rb is committed cannot be determined, so this"
  echo "    run cannot say which bytes the brew checks below read. Commit the"
  echo "    formula, then re-run to get an answer that names a commit."
  echo
fi

# brew audit/style need the formula to be reachable as a tap. This changes local
# Homebrew state, which is why it happens after the check that does not.
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
  # Spelled as an `if` rather than `A && B || C`, which shellcheck 0.9.0 on the
  # runner flags as SC2015 while a newer local shellcheck stays quiet. The logic
  # was correct either way; a lint that passes locally and fails in CI is the
  # thing worth removing.
  if [ -z "$tap_repo" ] || [ ! -d "$tap_repo/.git" ]; then
    echo "error: rvben/rumdl is tapped but $tap_repo is not a git clone" >&2
    exit 1
  fi
  echo "==> Refreshing the existing rvben/rumdl tap clone from $TAP_DIR"
  git -C "$tap_repo" fetch --quiet "$TAP_DIR" HEAD

  # The refresh discards whatever is in that clone, and `brew edit
  # rvben/rumdl/rumdl` edits precisely this clone - it is where a contributor's
  # experiment plausibly lives. So look before overwriting: uncommitted changes,
  # untracked files, and commits the clone has that this checkout does not.
  # `status --porcelain` is a complete inventory only while nothing has told git to
  # stop looking, and two things do, both by printing nothing rather than failing.
  #
  # status.showUntrackedFiles=no hides every untracked file - which is exactly what
  # `clean -fd` deletes - and it can come from the clone's own config, from a global
  # config, or from the environment. An --untracked-files on the command line beats
  # all three, so the inventory asks for the listing it needs instead of accepting
  # the one configuration chose.
  dirty="$(git -C "$tap_repo" status --porcelain --untracked-files=normal)"
  # assume-unchanged and skip-worktree tell git not to stat a tracked file at all,
  # so an edit to it is reported by neither `status` nor `diff --quiet HEAD`, and
  # `reset --hard` overwrites it. No flag turns that off: whether those files hold
  # edits is genuinely unknown here, and unknown is not the same fact as clean
  # immediately before a destructive command, so they count as work. Verified: with
  # rumdl.rb assume-unchanged and rewritten, status prints nothing and `git diff
  # --quiet HEAD` exits 0, while `ls-files -v` tags it `h`.
  if ! index_flags="$(git -C "$tap_repo" ls-files -v 2>&1)"; then
    echo "error: could not read the index of the rvben/rumdl tap clone" >&2
    echo "       $tap_repo" >&2
    printf '%s\n' "$index_flags" | sed 's/^/         /' >&2
    echo "       Refreshing it means reset --hard and clean -fd, and whether that" >&2
    echo "       would destroy anything is exactly what could not be determined." >&2
    exit 1
  fi
  # Lowercase tag: assume-unchanged. S: skip-worktree. awk rather than grep so that
  # "nothing is hidden" stays an exit status of 0 under set -e.
  hidden="$(printf '%s\n' "$index_flags" |
    awk '$1 ~ /^([a-z]|S)$/ { $1 = ""; sub(/^ /, ""); print }')"
  # Not `|| echo 0`. Zero here means "the clone holds no commits your checkout
  # lacks", and that answer is what permits the reset --hard and clean -qfd below.
  # A rev-list that failed - a corrupt clone, an unreadable object, a FETCH_HEAD
  # that never landed - is not the same fact, and coercing it to 0 turns "I could
  # not tell" into "there is nothing to lose" immediately before destroying it.
  if ! ahead="$(git -C "$tap_repo" rev-list --count FETCH_HEAD..HEAD 2>&1)"; then
    echo "error: could not count commits in the rvben/rumdl tap clone" >&2
    echo "       $tap_repo" >&2
    printf '%s\n' "$ahead" | sed 's/^/         /' >&2
    echo "       Refreshing it means reset --hard and clean -fd, and whether that" >&2
    echo "       would destroy anything is exactly what could not be determined." >&2
    echo "       Inspect the clone, or drop the tap (brew untap rvben/rumdl)." >&2
    exit 1
  fi
  if { [ -n "$dirty" ] || [ -n "$hidden" ] || [ "$ahead" != "0" ]; } &&
     [ "${DISCARD_TAP_CLONE:-0}" = "1" ]; then
    echo "    DISCARD_TAP_CLONE=1: discarding $(printf '%s' "$dirty" | grep -c . ) changed path(s), $(printf '%s' "$hidden" | grep -c . ) path(s) git was told not to look at, and $ahead local commit(s)"
  elif [ -n "$dirty" ] || [ -n "$hidden" ] || [ "$ahead" != "0" ]; then
    echo "error: the rvben/rumdl tap clone holds work this would destroy" >&2
    echo "       $tap_repo" >&2
    [ -n "$dirty" ] && printf '%s\n' "$dirty" | sed 's/^/         /' >&2
    if [ -n "$hidden" ]; then
      printf '%s\n' "$hidden" | sed 's/^/         marked assume-unchanged or skip-worktree: /' >&2
      echo "         git does not stat those, so whether they hold edits is unknown" >&2
    fi
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
  if [ "$FORMULA_STATE" = unknown ]; then
    echo "Pins pass against this working tree. Audit and style pass against a clone"
    echo "of a repository with no HEAD, so which bytes they read is unrecorded."
  else
    echo "Pins pass against this working tree. Audit and style pass against $HEAD_SHA."
  fi
  # Spelled as an `if`: a bare `[ ... ] && echo` is a statement that returns 1
  # when the test is false, which under `set -e` ends the run here.
  if [ "$FORMULA_STATE" = uncommitted ]; then
    echo "Your uncommitted Formula/rumdl.rb was NOT audited. Commit it and re-run."
  fi
  echo "Install and test not run; pass --install for those."
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

# The tap's own documentation, linted by the binary the tap just installed. Two
# things at once, which is why it sits here rather than in a lint job of its own:
# this repository's markdown gets the tool it ships (nothing else checks it, and a
# markdown linter's tap with unlinted docs is its own kind of bug), and the binary
# gets real prose instead of the two synthetic files above. --no-config so it is
# the default rule set, the same one a user gets, and not whatever config
# discovery finds by walking up from here.
echo "==> The installed binary lints this repository's own docs"
"$RUMDL" check --no-config README.md CONTRIBUTING.md
echo

if [ "$FORMULA_STATE" = unknown ]; then
  echo "Pins pass against this working tree. Audit, style, install and test pass"
  echo "against a clone of a repository with no HEAD, so which bytes they read is"
  echo "unrecorded."
else
  echo "Pins pass against this working tree. Audit, style, install and test pass"
  echo "against $HEAD_SHA, which is what brew read."
fi
if [ "$FORMULA_STATE" = uncommitted ]; then
  echo "Your uncommitted Formula/rumdl.rb was NOT installed or tested. Commit it"
  echo "and re-run: nothing below the pin check looked at it."
fi
