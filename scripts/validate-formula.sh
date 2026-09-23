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
# the refresh that rewrites it. Verified: `GIT_DIR=$other/.git git -C "$repo"
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
# promise of a clean `pins` job on an older shellcheck. That job asserts the version
# it finds (SHELLCHECK_EXPECTED in .github/workflows/validate-formula.yml), so a
# runner-image bump fails there rather than leaving this note quietly false.
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

# Everything below is built on the tap clone and this checkout being two directories:
# the checkout holds the commit being validated, the clone is refreshed onto it, and one
# is safe to rewrite because the other is not. Running this script from inside the tap
# clone collapses that. The clone is a full clone of this repository, scripts included,
# so `cd "$(brew --repository rvben/rumdl)" && ./scripts/validate-formula.sh` is a
# reasonable thing for someone to try, and it has two bad outcomes and no good one. With
# DISCARD_TAP_CLONE=1 the pin check reads the working tree, the reset then puts HEAD's
# bytes back over it, and the run exits 0 reporting pins that belong to the formula it
# just discarded - the byte check cannot see it, since it is comparing HEAD against
# HEAD. Without the hatch it refuses over the contributor's own uncommitted work and
# tells them to stash it into the directory they are already standing in.
#
# Asked before anything is tapped or refreshed, because after the refresh the damage is
# done. `pwd -P` on both sides so a symlinked path is not mistaken for a different
# directory, and `|| true` because an older brew may have nothing to say about a name it
# has not tapped.
tap_repo_probe="$(brew --repository rvben/rumdl 2>/dev/null || true)"
if [ -n "$tap_repo_probe" ] && [ -d "$tap_repo_probe" ] &&
   [ "$(cd "$tap_repo_probe" && pwd -P)" = "$(cd "$TAP_DIR" && pwd -P)" ]; then
  echo "error: this directory IS the rvben/rumdl tap clone" >&2
  echo "       $TAP_DIR" >&2
  echo "       The brew checks below read a clone of the commit being validated, and" >&2
  echo "       here that clone would be this working tree: refreshing it would rewrite" >&2
  echo "       the formula the pin check just read, and with DISCARD_TAP_CLONE=1 it" >&2
  echo "       would discard your uncommitted work and then report on the formula it" >&2
  echo "       restored. Run it from your own checkout of the repository instead." >&2
  exit 1
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
  # Every git command below runs against that clone through this wrapper, so the
  # clone's own configuration can neither decide what the inventory sees nor get code
  # of its own run while this script is deciding what may be destroyed.
  #
  # core.fsmonitor names a program git runs to ask what changed, and core.hooksPath
  # does not cover it. Measured both ways round. A program there ran four times across
  # the status, ls-files and checkout below, and rewrote Formula/rumdl.rb, so the brew
  # checks read the clone's bytes while this script announced the fetched commit. And a
  # program that answers "nothing changed" - which is what an ordinary watchman setup
  # answers, no adversary required - made `status --porcelain` report a clean tree while
  # the formula held uncommitted edits: the inventory going blind in exactly the way
  # assume-unchanged makes it blind below, with the same consequence.
  #
  # core.hooksPath is emptied for the reason the refresh further down gives. Neither
  # value can name something that runs: /dev/null is not a directory, and `false` is
  # git's own spelling for "no fsmonitor".
  #
  # --work-tree pins where the refresh writes. core.worktree in that clone sends git
  # at another directory entirely, and these repos reach that state for real: the key
  # goes stale when a worktree is deleted under an interrupted operation, which has
  # happened twice. Measured with it set, two outcomes and both wrong. Where the
  # redirected directory looks clean against the clone's HEAD, the inventory reports
  # nothing, the checkout exits 0, and it writes the fetched commit INTO that
  # directory - files nobody nominated - while the tap path keeps the old formula that
  # every brew check below then reads. Where it does not look clean, the inventory
  # reports work that is not in the clone at all and the run refuses over someone
  # else's files. With --work-tree the same fixture refreshed the clone, left the other
  # directory byte-identical, and reported a clean inventory.
  #
  # core.autocrlf=true rewrites every file it checks out, and one of them is the
  # formula brew audits. No .gitattributes and no adversary needed: it is one setting a
  # contributor may have set once for Windows work. Measured: 3 CRs in
  # Formula/rumdl.rb after the refresh, none with these two overrides.
  #
  # What this wrapper cannot reach is recorded with the check that covers it, after the
  # refresh: a filter driver the FETCHED tree selects by name, and brew's own git.
  tap_git() {
    git -C "$tap_repo" --work-tree="$tap_repo" \
      -c core.fsmonitor=false -c core.hooksPath=/dev/null \
      -c core.autocrlf=false -c core.eol=lf "$@"
  }
  echo "==> Refreshing the existing rvben/rumdl tap clone from $TAP_DIR"
  tap_git fetch --quiet "$TAP_DIR" HEAD

  # The refresh discards whatever is in that clone, and `brew edit
  # rvben/rumdl/rumdl` edits precisely this clone - it is where a contributor's
  # experiment plausibly lives. So look before overwriting: uncommitted changes,
  # untracked files, and commits the clone has that this checkout does not.
  # `status --porcelain` is a complete inventory only while nothing has told git to
  # stop looking, and two things do, both by printing nothing rather than failing.
  #
  # status.showUntrackedFiles=no hides every untracked file, which is the half of this
  # inventory a contributor's own experiment most often lives in - a formula variant
  # saved beside the real one is untracked, not modified - and it can come from the
  # clone's own config, from a global
  # config, or from the environment. An --untracked-files on the command line beats
  # all three, so the inventory asks for the listing it needs instead of accepting
  # the one configuration chose.
  dirty="$(tap_git status --porcelain --untracked-files=normal)"
  # assume-unchanged and skip-worktree tell git not to stat a tracked file at all, so
  # an edit to it is reported by neither `status` nor `diff --quiet HEAD`. No flag
  # turns that off: whether those files hold edits is genuinely unknown here, and
  # unknown is not the same fact as clean immediately before a destructive command,
  # so they count as work. Verified: with rumdl.rb assume-unchanged and rewritten,
  # status prints nothing and `git diff --quiet HEAD` exits 0, while `ls-files -v`
  # tags it `h`.
  #
  # Both outcomes of refreshing anyway are wrong, though neither loses the bytes.
  # Measured against the refresh this script runs, crossing each flag with whether
  # the fetched commit changes the marked path:
  #
  #   either flag, path changed by the fetch: checkout aborts with exit 1, HEAD
  #     unmoved and the local bytes intact, and the run dies there on a git error
  #     that explains nothing about what to do.
  #   either flag, path unchanged by the fetch: checkout exits 0 and honours the
  #     flag, so the local bytes stay - and are now part of the tree every check
  #     below runs against. If that path is the formula, brew audits and installs
  #     the contributor's local copy while reporting on the formula under validation.
  if ! index_flags="$(tap_git ls-files -v 2>&1)"; then
    echo "error: could not read the index of the rvben/rumdl tap clone" >&2
    echo "       $tap_repo" >&2
    printf '%s\n' "$index_flags" | sed 's/^/         /' >&2
    echo "       Refreshing it rewrites the working tree, and whether that" >&2
    echo "       would destroy anything is exactly what could not be determined." >&2
    exit 1
  fi
  # Lowercase tag: assume-unchanged. S: skip-worktree. awk rather than grep so that
  # "nothing is hidden" stays an exit status of 0 under set -e.
  hidden="$(printf '%s\n' "$index_flags" |
    awk '$1 ~ /^([a-z]|S)$/ { $1 = ""; sub(/^ /, ""); print }')"
  # Ignored files are absent from both lists above, and nothing here deletes them, so
  # most of them are none of this script's business. One shape is:
  # a path the FETCHED commit tracks, which this clone holds as a locally created
  # ignored file. That collision is not detected here at all, deliberately - see the
  # refresh below, which asks git to detect it.
  #
  # Not `|| echo 0`. Zero here means "the clone holds no commits your checkout
  # lacks", and that answer is what permits the refresh below.
  # A rev-list that failed - a corrupt clone, an unreadable object, a FETCH_HEAD
  # that never landed - is not the same fact, and coercing it to 0 turns "I could
  # not tell" into "there is nothing to lose" immediately before destroying it.
  if ! ahead="$(tap_git rev-list --count FETCH_HEAD..HEAD 2>&1)"; then
    echo "error: could not count commits in the rvben/rumdl tap clone" >&2
    echo "       $tap_repo" >&2
    printf '%s\n' "$ahead" | sed 's/^/         /' >&2
    echo "       Refreshing it rewrites the working tree, and whether that" >&2
    echo "       would destroy anything is exactly what could not be determined." >&2
    echo "       Inspect the clone, or drop the tap (brew untap rvben/rumdl)." >&2
    exit 1
  fi
  # An operation left half-finished in that clone is state neither the reset nor the
  # checkout clears, so the refresh must not run past it. Nothing prevents a
  # contributor from starting one there: `brew edit rvben/rumdl/rumdl` puts them in
  # this clone in the first place, and a rebase or a bisect of what they found is an
  # ordinary next step. Measured on git 2.50.1, seven operations, each one's state
  # confirmed present before the two steps ran - the first run of that probe set up
  # no conflict, so four arms left nothing behind and proved nothing:
  #
  #   conflicted merge         MERGE_HEAD        cleared by the reset
  #   conflicted cherry-pick   CHERRY_PICK_HEAD  cleared by the reset
  #   conflicted revert        REVERT_HEAD       cleared by the reset
  #   rebase -i stopped        rebase-merge      SURVIVES the reset and the checkout
  #   conflicted rebase        rebase-merge      SURVIVES both
  #   rebase --apply stopped   rebase-apply      SURVIVES both
  #   bisect in progress       BISECT_START      SURVIVES both
  #
  # For the three that survive, refreshing moves HEAD out from under the operation and
  # leaves it pointing at commits the contributor never chose, while
  # DISCARD_TAP_CLONE=1 prints that HEAD's bytes were restored. The hatch is for
  # tracked edits; this is not one, so it stops in both modes. git's own --git-path is
  # what locates these, rather than a hand-built .git path, because the answer differs
  # in a linked worktree.
  in_progress=""
  for op in rebase-merge rebase-apply BISECT_START; do
    op_path="$(tap_git rev-parse --git-path "$op" 2>/dev/null || true)"
    if [ -n "$op_path" ] && [ -e "$tap_repo/$op_path" ]; then
      in_progress="$in_progress $op"
    fi
  done
  if [ -n "$in_progress" ]; then
    echo "error: the rvben/rumdl tap clone has a git operation in progress" >&2
    echo "       $tap_repo" >&2
    echo "       git state left behind:$in_progress" >&2
    echo "       Refreshing it would move HEAD out from under that operation, and a" >&2
    echo "       reset does not clear these the way it clears a merge, so" >&2
    echo "       DISCARD_TAP_CLONE=1 does not cover it either." >&2
    echo "       Finish it or abandon it (git -C \"$tap_repo\" rebase --abort," >&2
    echo "       git -C \"$tap_repo\" bisect reset), or drop the tap" >&2
    echo "       (brew untap rvben/rumdl)." >&2
    exit 1
  fi
  if { [ -n "$dirty" ] || [ -n "$hidden" ] || [ "$ahead" != "0" ]; } &&
     [ "${DISCARD_TAP_CLONE:-0}" = "1" ]; then
    # "over", not "discarding": a path HEAD does not track stays where it is now that no
    # `clean` follows the refresh. Saying discarded would overstate what happens to those
    # in the direction that matters, since a contributor who reads it as "they are gone"
    # has lost nothing.
    #
    # The sentence below states the RULE the reset follows rather than a list of shapes,
    # because the list was wrong twice. Measured, one arm each, on git 2.50.1:
    #
    #   edited + assume-unchanged   status clean, reset DESTROYS it (HEAD's bytes)
    #   edited + skip-worktree      status clean, reset keeps the local bytes
    #   staged deletion, bytes left status "D  f.rb" and "?? f.rb", reset DESTROYS them
    #   untracked path              kept
    #   ignored path                kept
    #   unfinished merge            MERGE_HEAD gone, working tree clean
    #   interrupted rebase          .git/rebase-merge STAYS, status still says rebasing
    #   edited file in a submodule  kept; the superproject still reports " m <path>"
    #
    # So the two flags do not behave alike, and "untracked files are left in place" was
    # false for the one untracked path HEAD still tracks: git restores the staged
    # deletion straight over it. Both of those paths ARE tracked edits in the hatch's
    # sense - the contributor asked for tracked edits to go - and both are listed above
    # before anything runs, the hidden ones under their own count. What was wrong was the
    # promise, not the behaviour.
    #
    # The last two arms are why the sentence below says "a path HEAD tracks" rather than
    # "everything": a submodule's own working tree is not reset with the superproject, and
    # a rebase left in progress survives both the reset and the checkout. The rebase is
    # reachable - a contributor can start one in the clone - and is refused above, before
    # either mode gets here, together with a bisect and the other rebase backend. The
    # submodule arm is stated for the sentence's accuracy rather than guarded: this
    # repository declares no submodules, so a clone of a commit of it has none unless
    # someone adds one by hand, and that shape is a tracked path the inventory above
    # already reports as changed.
    echo "    DISCARD_TAP_CLONE=1: proceeding over $(printf '%s' "$dirty" | grep -c . ) changed path(s), $(printf '%s' "$hidden" | grep -c . ) path(s) git was told not to look at, and $ahead local commit(s)"
    echo "    Every file HEAD tracks there goes back to HEAD's bytes - including an edit"
    echo "    git was told not to stat, and a path staged as deleted while HEAD still"
    echo "    tracks it. A path HEAD does not track is not touched."
    # And this is what makes that sentence true. The refresh below is a NON-forced
    # checkout, which refuses to overwrite a modified tracked file - so without this
    # reset the hatch announced it was proceeding and then died on git's refusal, for
    # exactly the shape it exists for: `brew edit rvben/rumdl/rumdl` modifies
    # Formula/rumdl.rb, and the commit being validated always changes that file too.
    # Measured on git 2.50.1: a local commit or an edit to any OTHER file completed
    # fine, which is why the hatch looked like it worked.
    #
    # `reset --hard HEAD`, not `checkout -f`, and the difference is the whole point.
    # Both clear tracked edits and an unmerged index; -f additionally defeats
    # --no-overwrite-ignore, overwriting the ignored local file the refresh below
    # refuses over. Measured on the same fixture, all four outcomes: after this reset
    # the collision still aborts with the local bytes intact, while -f exits 0 and
    # replaces them with the fetched commit's copy. The reset only touches paths in
    # HEAD, so ignored and untracked files are not its business.
    #
    # What it still does not cover: skip-worktree. reset honours that flag, so such a
    # path keeps its local bytes, and if the fetched commit changes it the checkout below
    # aborts - nothing is lost, and the run stops. assume-unchanged is NOT in that
    # sentence: the same reset overwrites it, measured above.
    if ! discard_out="$(tap_git reset --hard --quiet HEAD 2>&1)"; then
      echo "error: could not discard the local state of the rvben/rumdl tap clone" >&2
      echo "       $tap_repo" >&2
      printf '%s\n' "$discard_out" | sed 's/^/         /' >&2
      echo "       Nothing below this ran. Inspect that clone, or drop the tap" >&2
      echo "       (brew untap rvben/rumdl)." >&2
      exit 1
    fi
  elif [ -n "$dirty" ] || [ -n "$hidden" ] || [ "$ahead" != "0" ]; then
    echo "error: the rvben/rumdl tap clone holds work this would destroy" >&2
    echo "       $tap_repo" >&2
    [ -n "$dirty" ] && printf '%s\n' "$dirty" | sed 's/^/         /' >&2
    if [ -n "$hidden" ]; then
      printf '%s\n' "$hidden" | sed 's/^/         marked assume-unchanged or skip-worktree: /' >&2
      echo "         git does not stat those, so whether they hold edits is unknown" >&2
    fi
    [ "$ahead" != "0" ] && echo "         $ahead commit(s) not in $TAP_DIR" >&2
    echo "       Refreshing it rewrites the working tree, so this stops here." >&2
    echo "       Keep the work (git -C \"$tap_repo\" stash, or copy it into $TAP_DIR)," >&2
    echo "       or discard it deliberately with DISCARD_TAP_CLONE=1 $0 $*" >&2
    exit 1
  fi

  # `checkout --no-overwrite-ignore`, not `reset --hard`. The two agree on a clean
  # clone, which the inventory above has established this one is, and they differ on
  # exactly the case the inventory cannot see: a path the fetched commit tracks that
  # this clone holds as an ignored file. `reset --hard` writes over it silently;
  # checkout runs the collision check and aborts.
  #
  # Which matters because enumerating that collision by hand does not converge. An
  # exact-path intersection of "ignored here" against "tracked by the fetched commit"
  # misses at least three shapes, each measured to destroy the local bytes with every
  # list above empty: an ignored `Notes.md` against a fetched `notes.md`, which is one
  # file on a case-insensitive filesystem and so on every contributor's Mac; an
  # ignored `notes/private` against a fetched file `notes`, where the collision is
  # with an ancestor rather than a name; and that one reversed. git already knows the
  # filesystem's case sensitivity and how trees and directories collide, so the check
  # belongs there and not here.
  #
  # Measured across all four shapes, and two-sided: with --no-overwrite-ignore each
  # aborts with exit 1, HEAD unmoved and the local bytes intact; with
  # --overwrite-ignore each exits 0, moves HEAD and destroys them.
  #
  # -B rather than --detach so the clone stays on its branch, which is the state brew
  # expects; a clone already detached is refreshed detached.
  #
  # Hooks are suppressed by `tap_git`, and this command is why: checkout runs the
  # clone's `post-checkout` and `reference-transaction` hooks where `reset --hard` ran
  # neither, so swapping the command handed the clone an execution point that lands
  # after the inventory and before the brew checks. Measured with hooks live: a
  # post-checkout hook ran and rewrote the tracked formula, which is then the formula
  # the brew checks read while this script announced the fetched commit. The `fetch`
  # above needs no such treatment on its own account - it writes only FETCH_HEAD, and a
  # reference-transaction hook was measured not to fire for it - but it goes through the
  # wrapper too, because the `core.fsmonitor` half applies to every command that reads
  # the worktree, and one command left out of a wrapper is the hole it exists to close.
  tap_branch="$(tap_git symbolic-ref --quiet --short HEAD || true)"
  refresh_code=0
  if [ -n "$tap_branch" ]; then
    refresh_out="$(tap_git checkout --quiet \
      --no-overwrite-ignore -B "$tap_branch" FETCH_HEAD 2>&1)" || refresh_code=$?
  else
    refresh_out="$(tap_git checkout --quiet \
      --no-overwrite-ignore --detach FETCH_HEAD 2>&1)" || refresh_code=$?
  fi
  # git's own message is the only account of why it refused, so it is printed and
  # nothing here restates it as a cause. The earlier version of this block asserted
  # one: that the paths git named are ignored files the inventory could not see.
  # That is the collision this refresh exists to catch, but it is not the only way
  # out of checkout nonzero - a clone whose index is unmerged (a `brew update` that
  # conflicted, which is an ordinary state for a tap someone has committed to) also
  # lands here, and there the sentence about ignored paths is simply false. Measured:
  # `DISCARD_TAP_CLONE=1` on a clone mid-conflict printed it.
  #
  # The hatch covers that one - its `reset --hard HEAD` clears an unmerged index, and
  # the checkout then succeeds (measured: 3 unmerged paths before, 0 after, refresh
  # exit 0 on the fetched commit) - but only when the hatch was asked for, so this
  # refusal is still what a mid-conflict clone meets by default.
  #
  # What the hatch deliberately does not do is force: `checkout -f` clears the same
  # unmerged index and was measured to defeat `--no-overwrite-ignore` as well,
  # overwriting the very ignored file this block refuses over. So the refusal stands
  # for every cause and the guidance below distinguishes only what git's own message
  # already distinguishes, rather than asserting a cause: hand-enumerating the states
  # is the mistake this refresh already made once with collisions.
  if [ "$refresh_code" != "0" ]; then
    echo "error: git refused to refresh the rvben/rumdl tap clone" >&2
    echo "       $tap_repo" >&2
    printf '%s\n' "$refresh_out" | sed 's/^/         /' >&2
    echo "       Your working tree and your commits there are untouched: the fetch" >&2
    echo "       before this added objects and wrote FETCH_HEAD, and nothing else" >&2
    echo "       in that clone was written." >&2
    echo "       If git named paths there, that clone holds local bytes at those" >&2
    echo "       paths and the commit being validated writes them too: files it" >&2
    echo "       ignores or does not track, or a path marked assume-unchanged or" >&2
    echo "       skip-worktree. DISCARD_TAP_CLONE=1 covers none of those, so move" >&2
    echo "       or remove them deliberately." >&2
    echo "       If it named the index instead, an operation is unfinished in that" >&2
    echo "       clone - finish it, or abort it (git -C \"$tap_repo\" merge --abort)." >&2
    echo "       Either way you can also drop the tap (brew untap rvben/rumdl)." >&2
    exit 1
  fi
  # No `clean` here, deliberately. It used to follow the refresh, and what it deleted
  # was never what it was there for. On a clone the inventory has just found clean, the
  # one thing left for it to delete is the one thing it must not: a file the clone holds
  # that its OWN .gitignore covers, where the fetched commit drops that ignore rule
  # without tracking the path. Then the file is ignored when the inventory looks and
  # untracked when the clean runs, so no list above holds it, checkout has no collision
  # to refuse - the fetched commit does not track it - and the clean deletes it.
  # Measured, with the whole inventory empty: a local `notes.md` was gone at the end of
  # the run, and kept by the identical run with the clean removed, which also reached
  # the fetched commit with the right formula.
  #
  # "Nothing left to delete" holds for the clean-inventory case only. Past
  # DISCARD_TAP_CLONE=1 the clean had plenty to delete - every untracked file that hatch
  # was told to proceed over, and any other path the fetched rules stop ignoring - which
  # is the second reason it is gone rather than narrowed.
  #
  # What it cost to remove: under DISCARD_TAP_CLONE=1 the untracked files that hatch
  # discards now stay in the working tree rather than being deleted. They are listed
  # above before anything happens, the brew checks below read Formula/rumdl.rb and do
  # not care what else sits beside it, and leaving a file behind is the failure to
  # prefer over deleting one.
  echo "    tap clone now at $(tap_git rev-parse --short HEAD)"
else
  echo "==> Tapping rvben/rumdl from $TAP_DIR"
  brew tap --force rvben/rumdl "$TAP_DIR"
  tap_repo="$(brew --repository rvben/rumdl)"
fi

# Whichever path produced that clone, everything below depends on one property, and it
# is one sentence long: the formula sitting where brew reads it is the formula in the
# commit this run says it validated. Five review rounds found five different mechanisms
# that break it - a post-checkout hook, a core.fsmonitor program, core.autocrlf, a
# smudge filter the fetched .gitattributes selects, core.worktree pointing elsewhere -
# and each fix closed one and left the next. Enumerating mechanisms is what kept
# failing, so this compares the bytes themselves. It holds for the mechanism nobody has
# thought of yet, and for the plainest failure of all: a clone left at the wrong
# commit, which is what this whole block exists to prevent and was seen happening.
#
# `cat-file blob` is the stored object - no smudge filter, no textconv, no eol
# conversion - so it is the commit's bytes rather than another reading of the same
# worktree. And the check sits outside the refresh because `brew tap --force` clones
# with brew's own git, which this script has no way to wrap: a global core.autocrlf
# reaches that clone, and only the bytes afterwards can say so.
#
# The honest limit: this proves what brew READS, not that brew's own git ran nothing
# of the clone's choosing. Those invocations are brew's, they are not wrapped, and
# nothing here changes that.
#
# The states where this check refuses a run nothing did wrong are all attributes, and
# they are in THIS repository's hands rather than the contributor's, because attributes
# beat config. Two of them measured: `Formula/rumdl.rb eol=crlf` put 3 CRs in the
# checked-out file with `-c core.autocrlf=false -c core.eol=lf` passed (and 3 with
# `-c core.eol=crlf` as a control that the arm produces them at all), and `ident` with a
# `$Id$` line in the formula had git expand it on checkout, leaving valid Ruby that no
# commit contains. Either would make the blob and the file differ on every run, by
# design and for everybody.
#
# There is no .gitattributes in this repository at all, and a Homebrew formula has no
# business being CRLF or carrying an expanded ident, so committing one of those would be
# the defect and this check firing on it would be correct. What it gets is therefore a
# place in the diagnosis below rather than a guard of its own - without that, the refusal
# sends someone hunting through their own clone's config for a cause that is committed.
#
# The same reasoning applies to a global git setting, which is what the fresh-tap path is
# exposed to: brew's clone gets the contributor's core.autocrlf, nothing here can pass a
# flag to it, and "re-tap to get a clean clone" would loop forever. So the diagnosis
# names that too, and says which of the three causes re-tapping actually fixes.
if [ "$FORMULA_STATE" = unknown ]; then
  echo "==> Not checking the tap clone's bytes: $TAP_DIR has no HEAD commit, so this"
  echo "    run has no committed formula to compare against."
elif ! git -C "$TAP_DIR" cat-file -e HEAD:Formula/rumdl.rb 2>/dev/null; then
  echo "error: HEAD in $TAP_DIR has no Formula/rumdl.rb" >&2
  echo "       Every check below reads a clone of that commit, so there is nothing" >&2
  echo "       for them to validate and no bytes to compare." >&2
  exit 1
elif [ ! -f "$tap_repo/Formula/rumdl.rb" ]; then
  echo "error: the rvben/rumdl tap clone has no Formula/rumdl.rb" >&2
  echo "       $tap_repo" >&2
  echo "       The commit being validated tracks it, so something in that clone is" >&2
  echo "       keeping it out of the working tree - sparse-checkout is the usual" >&2
  echo "       one. Every brew check below would run against a tap without the" >&2
  echo "       formula in it." >&2
  echo "       Re-tap to get a clean clone: brew untap rvben/rumdl, then re-run." >&2
  exit 1
elif ! git -C "$TAP_DIR" cat-file blob HEAD:Formula/rumdl.rb |
     cmp -s - "$tap_repo/Formula/rumdl.rb"; then
  echo "error: the formula in the rvben/rumdl tap clone is not the formula in $HEAD_SHA" >&2
  echo "       $tap_repo/Formula/rumdl.rb" >&2
  echo "       The bytes there differ from the committed formula this run validated," >&2
  echo "       so brew audit, brew style and brew install below would report on a" >&2
  echo "       formula nothing has checked, under the name of the one that was." >&2
  echo "       Something rewrites files as they are checked out, or that clone is not" >&2
  echo "       at the commit it reports. Three places to look:" >&2
  echo "         git -C \"$tap_repo\" config --list | grep -E 'filter|autocrlf|eol|worktree'" >&2
  echo "         git config --global --get-regexp 'core[.](autocrlf|eol)|^filter[.]'" >&2
  echo "         git -C \"$TAP_DIR\" check-attr eol text filter ident -- Formula/rumdl.rb" >&2
  echo "       Re-tapping gets a clean clone only if the cause was in that clone:" >&2
  echo "       brew untap rvben/rumdl, then re-run. A global git setting or a" >&2
  echo "       committed attribute reproduces itself in the new clone, so fix that" >&2
  echo "       first - the second and third commands are the ones that find it." >&2
  exit 1
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

# The formula's livecheck block is what tells a maintainer that a new rumdl release
# exists, and nothing else in this script or in the guard suite exercises it: the
# suite is offline, and `brew audit` accepts a block that resolves nothing.
#
# What is checked is that the block RESOLVES A VERSION, not that the tap is up to
# date - between a rumdl release and the bump that follows it, being behind is the
# correct state and gating on it would make this script refuse the truth.
#
# `brew livecheck --json` exits 0 either way, which is the trap: a block whose
# strategy matches nothing returns {"status": "error", "messages": ["Unable to get
# versions"]} with no version object at all, and exit status 0. Verified by breaking
# the strategy in a tapped clone. So the version has to be read out of the JSON
# rather than inferred from the exit code, and it is the `latest` field - `current`
# is parsed from the formula's own urls and is there even when nothing resolved.
echo "==> The livecheck block resolves a version"
livecheck_json="$(brew livecheck --json --formula rvben/rumdl/rumdl 2>&1 || true)"
livecheck_latest="$(printf '%s\n' "$livecheck_json" |
  sed -n 's/.*"latest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
if [ -z "$livecheck_latest" ]; then
  echo "error: the formula's livecheck block resolved no version" >&2
  printf '%s\n' "$livecheck_json" | sed 's/^/       /' >&2
  echo "       Either the block is wrong - a strategy that matches nothing still" >&2
  echo "       leaves brew audit and brew style clean - or the GitHub API could not" >&2
  echo "       be reached. The messages above say which." >&2
  echo "       Until it resolves, nothing tells this tap a new rumdl release exists." >&2
  exit 1
fi
echo "    livecheck resolves the newest rumdl release as $livecheck_latest"
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
