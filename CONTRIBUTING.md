# Contributing to homebrew-rumdl

Thank you for considering contributing to the rumdl Homebrew tap!

## The invariant that matters most

Every `sha256` in `Formula/rumdl.rb` must be the hash of the artifact fetched by
the `url` directly above it, and every `url` must name the same version, fetch
from rumdl's own releases, and contain a `rumdl` binary to install. The formula
must also still ship all four platforms: removing a `url` and its `sha256`
together leaves every count in agreement, so `verify-formula.sh` holds the
expected platform list itself rather than deriving it from the file.

`brew audit` and `brew style` do not check either of those things. A formula can
pass both while pinning the wrong artifact's hash, in which case `brew install`
fails checksum verification for the affected platform and nothing upstream of
the user notices. Measured on Homebrew 7.0.6: `Error: Formula reports different
checksum`, exit 1, nothing installed. On an older Homebrew it is worse rather
than better, which is the stronger reason to check the pins here: 4.6.20 treats
the same mismatch as a warning and installs the downloaded bytes anyway, so a
user on that version gets the wrong artifact with a message they can miss.
Check it with:

```bash
./scripts/verify-formula.sh
```

That script needs nothing but `curl` and a shell, reads the working tree, and
reports every platform rather than stopping at the first failure.

## Updating to a new rumdl release

Do not edit the version or the hashes by hand. Run:

```bash
./scripts/update-formula.sh 0.2.76
```

It rewrites the version inside each `url`, downloads exactly those urls, pins
what it downloaded, and then re-runs `verify-formula.sh` against the result. It
derives the platform list from the formula itself, so a pin cannot end up
belonging to a different artifact than the url beside it. If any asset cannot be
downloaded it aborts and leaves the formula untouched, rather than bumping the
version while one platform keeps the previous release's hash.

It needs the GitHub CLI, because it checks each asset's Sigstore build provenance
(`gh attestation verify --repo rvben/rumdl --signer-workflow ...`) before pinning
it. A hash proves the bytes have not changed since they were hashed; the
attestation is what ties them to a rumdl release build.

Three things it refuses to do quietly, each with an escape hatch for when you
mean it:

- **Re-pin a version the formula already names**, when the published assets now
  hash differently (`ALLOW_REPIN=1`). This is the asset-replacement case, and it
  changes what users get under a version they already have.
- **Move the tap to an older version** (`ALLOW_DOWNGRADE=1`). The version comes
  from a dispatch payload and is otherwise taken on trust.
- **Pin an asset with no valid provenance** (`ALLOW_UNATTESTED=1`). Needed for
  releases old enough to predate attestation, and nothing else.

Normally you do not run it at all: rumdl's release workflow sends a
`repository_dispatch` and `.github/workflows/update-formula.yml` does the above,
commits, pushes, and then asks Validate Formula to run.

## Changing a guard script

`scripts/test-guards.sh` tests the guards themselves. It breaks the formula one
way at a time - the right assets in the wrong `Hardware::CPU` branches, a
platform dropped with its pin, a url pointing at someone else's release, a
version that only looks valid on its first line - and requires the guard to
reject each one with the message belonging to the check under test, so a mutation
caught by the wrong check counts as a failure. It is offline, hermetic and takes
seconds. It needs `python3` for two of its mutations, and says so up front if it
is missing, because those two cases would otherwise hand the guard an empty file
and report the guard as broken.

It also runs `update-formula.sh` to completion, which is the only way to reach the
half of it that decides what gets pinned: the provenance check, the re-pin
comparison, the hash write-back, and the restore when verification fails. Those
cases stub `curl` with four locally built tarballs, one per target, and assert the
result directly - every `sha256` in the written formula is the hash of the archive
the `url` above it fetched. Four distinct fixtures rather than one shared payload,
because a script that wrote the first hash into all four pins would be
indistinguishable from a correct one otherwise. `gh` and `file` are stubbed
alongside it: what remains untestable locally is whether rumdl's actually
published assets match the committed pins, which is `verify-formula.sh`'s job and
runs next in the same CI job.

It also drives `validate-formula.sh` through the one command in this repository
that can destroy data: refreshing an existing `rvben/rumdl` tap clone onto the
commit being validated, with `git checkout --no-overwrite-ignore`, preceded by a
`git reset --hard` when, and only when, `DISCARD_TAP_CLONE=1` asks for it. Those
cases stub `brew`, build a real
repository and a real clone of it for the stub to point at, and assert what is
left in the clone rather than what the script printed, because a refusal that
reset the clone anyway would pass a message check.

The first of those cases names the reason the coverage exists: against the earlier
`rev-list --count FETCH_HEAD..HEAD || echo 0`, a `rev-list` that could not answer
became "nothing to lose", and the clone's own commit was destroyed. Most of the
rest cover refusals older than that fix, so there is no previous version for them
to fail against; what keeps them honest is removing the check each one owns, after
which that case, and only that case, fails. Two of them work as a pair rather than
alone, and that is deliberate: clearing a contributor's tracked edit with `checkout
-f` would satisfy the case that asks the escape hatch to do what it says, while
destroying the ignored file the other case requires to survive. Neither case is
sufficient on its own, and the check they guard is only correct because both pass.

The escape hatch's own announcement is covered the same way, in both
directions: what it says the reset destroys has a case asserting it was
destroyed, and what it says survives has one asserting it survived. That
sentence was wrong twice while every case passed, because it listed shapes
rather than stating the rule, and no case held it to a measurement.

```bash
./scripts/test-guards.sh
```

If you add a check, add the case that fails without it, and confirm the case
actually fails against the version of the script that lacks the check - the
previous commit when the check is new, the script with that check removed when
it is not. A guard test that passes both with and without proves nothing.

## Validating locally

```bash
./scripts/validate-formula.sh            # lint, guards, pins, audit, style
./scripts/validate-formula.sh --install  # also install, test, lint these docs
```

This runs what CI runs, in the same order, `scripts/test-guards.sh` included, so
a guard-script regression cannot pass locally and fail only in CI. Three things
to know:

- The shell lint runs here too when `shellcheck` is installed, and says plainly
  that it did not run when it is absent rather than reporting a clean lint. The
  gate for it is the `pins` job: GitHub's macOS images carry no `shellcheck`, so
  requiring it in this script broke both macOS `brew` jobs, and installing it
  four times over to repeat a lint `pins` has already run buys nothing. A clean
  run here is also not a promise of a clean one in CI: the runner ships 0.9.0, a
  Homebrew machine currently has 0.11.0, and the older version is the stricter of
  the two, having rejected an `A && B || C` line that the newer one accepted
  silently. CI is the authority.
- `brew tap --force rvben/rumdl <path>` clones the repository, so the `brew`
  checks see `HEAD`, not your uncommitted changes. Commit first if you want brew
  to see your edit. The pin check at the start reads the working tree directly,
  so it always reflects what you have now.
- It taps `rvben/rumdl` from your local checkout, which changes your local
  Homebrew state. `brew untap rvben/rumdl` afterwards if you would rather it did
  not. That leaves one thing behind: Homebrew 7 refuses to load formulae from an
  untrusted third-party tap, so the script runs `brew trust --tap rvben/rumdl`,
  and untapping does not revoke that. `brew trust` has no revoke flag, so to undo
  it you remove the `rvben/rumdl` entry from `~/.homebrew/trust.json` (or
  `$XDG_CONFIG_HOME/homebrew/trust.json` when that is set) yourself. It is the
  `trustedtaps` entry you want: installing a formula by its full name records a
  separate `trustedformulae` entry, and that one does go away again when you
  uninstall the formula. Both measured on 7.0.6.
- If you already have the tap, it refreshes that clone from your checkout instead
  of re-tapping, because `brew tap --force` on an already-tapped name does
  nothing and brew would keep checking the old commit. `brew edit
  rvben/rumdl/rumdl` edits exactly that clone, so the refresh stops rather than
  overwrite anything it finds there: uncommitted changes, untracked files, commits
  your checkout does not have, or a path marked `assume-unchanged` or
  `skip-worktree`, which git does not stat and so cannot report as clean. Stash
  them, copy them into your checkout, or run with `DISCARD_TAP_CLONE=1`. That
  hatch resets the clone to its own `HEAD` first, so every file `HEAD` tracks
  there goes back to `HEAD`'s bytes, and an unfinished merge is cleared with it.
  An interrupted rebase is not: measured on git 2.50.1, `.git/rebase-merge`
  survives both the reset and the refresh, and the clone is still rebasing
  afterwards. Two shapes of that are worth naming, because `git status` reports
  neither as a modified file: an edit to a path marked `assume-unchanged`, and a
  path staged as deleted whose own bytes are still standing there, which status
  calls untracked as well as deleted. A path `HEAD` does not track is not
  touched: nothing in the script deletes untracked or ignored files any more, so
  they stay where they are and the run continues past them. Two things the hatch
  deliberately does not cover, because being stopped is the better outcome: a file
  the clone holds that the new commit starts tracking, which git refuses to
  overwrite, and a path marked `skip-worktree`, whose local bytes the reset
  honours - if the new commit changes that path the refresh aborts, and if it does
  not, the check that compares what brew is about to read against the commit under
  validation refuses instead. Move or unmark those yourself. One more shape is
  named for accuracy rather than guarded: a submodule's own working tree is not
  reset with the superproject, so an edit inside one survives. This repository
  has no submodules, so a clone of it cannot have one without a commit that adds
  it.
- Run it from your own checkout, never from the tap clone. `brew --repository
  rvben/rumdl` is a full clone of this repository, `scripts/` included, so
  running it there is easy to reach by accident, and then the directory being
  refreshed is the directory whose formula was just read: with
  `DISCARD_TAP_CLONE=1` your uncommitted formula is discarded and the run reports
  pins for the bytes that replaced it. The script checks for that and refuses
  before it taps anything.

## Continuous integration

`.github/workflows/validate-formula.yml` runs on pull requests, on pushes to
`main` that touch `Formula/**`, `scripts/**`, `.github/workflows/**` or any root
`*.md`, daily on a schedule, and on explicit dispatch. The markdown is in that
list because the `brew` job lints it: leaving it out meant a documentation-only
change was the one change that skipped the check for it. Both workflow files are
in it for the same reason from the other side: the `pins` job is what lints the
workflows, and while the filter named only this file, a commit touching only
`update-formula.yml` started no run at all. Its jobs:

- `pins`: `shellcheck` over every script, `actionlint` over the workflows, then
  `scripts/test-guards.sh`, then every platform's pin from one runner, without
  Homebrew. Every check here is a shell script, so a shell defect is a guard
  defect; and invalid workflow YAML produces no run at all rather than a failing
  one, which is why the workflows are linted too.
- `brew`: `scripts/validate-formula.sh --install` on all four platforms the
  formula declares, which is the guard suite, the pins, `brew audit`, `brew
  style`, `brew audit --strict --online`, `brew install`, `brew test`, and
  finally this repository's own markdown linted by the rumdl the tap just
  installed. Each runner can only install and run the binary for the platform it
  is on, which is why the `pins` job exists and why the matrix is four runners
  rather than two.
- `freshness` (scheduled and manual runs only): is the formula still pointing at
  rumdl's newest release? Nothing else asks. The update arrives as a dispatch
  from rumdl's release workflow, whose notify step is `continue-on-error: true`,
  so a lost dispatch leaves this tap behind with both repositories green.

The daily schedule exists because this tap can break with no commit to it. A
GitHub release asset can be replaced after publication, which makes a correct
pin wrong: v0.2.76 had two successful `Release` runs on one tag, publishing two
different macOS binaries, and until the tap was re-pinned every `brew install`
failed checksum verification.

That schedule is also the one check that can retire itself. GitHub's docs state
that in a public repository, scheduled workflows are disabled automatically once
no repository activity has occurred in 60 days, and re-enabling one is manual.
Releases commit here, so an active rumdl keeps it alive; a quiet stretch is
exactly when it would stop, and a watchdog that stopped looks identical to a
watchdog seeing nothing wrong. The tell is `freshness` missing from the run list
rather than passing in it. Re-enable it under Actions if that happens.

One caveat worth knowing, because it silently disabled this workflow for its
first eleven months: a push made by a workflow using `GITHUB_TOKEN` does not
trigger other workflows. `update-formula.yml` therefore dispatches Validate
Formula explicitly after it pushes. A push you make yourself triggers it
normally.

## Questions?

Open an issue or reach out to [@rvben](https://github.com/rvben).
