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
the user notices. Check it with:

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

```bash
./scripts/test-guards.sh
```

If you add a check, add the case that fails without it, and confirm the case
actually fails against the previous version of the script. A guard test that
passes both before and after proves nothing.

## Validating locally

```bash
./scripts/validate-formula.sh            # guards, pins, audit, style, strict audit
./scripts/validate-formula.sh --install  # also install, test, lint these docs
```

This runs what CI runs, in the same order, `scripts/test-guards.sh` included, so
a guard-script regression cannot pass locally and fail only in CI. Two things to
know:

- `brew tap --force rvben/rumdl <path>` clones the repository, so the `brew`
  checks see `HEAD`, not your uncommitted changes. Commit first if you want brew
  to see your edit. The pin check at the start reads the working tree directly,
  so it always reflects what you have now.
- It taps `rvben/rumdl` from your local checkout, which changes your local
  Homebrew state. `brew untap rvben/rumdl` afterwards if you would rather it did
  not.
- If you already have the tap, it refreshes that clone from your checkout instead
  of re-tapping, because `brew tap --force` on an already-tapped name does
  nothing and brew would keep checking the old commit. `brew edit
  rvben/rumdl/rumdl` edits exactly that clone, so the refresh stops rather than
  overwrite anything it finds there: uncommitted changes, untracked files, or
  commits your checkout does not have. Stash them, copy them into your checkout,
  or discard them deliberately with `DISCARD_TAP_CLONE=1`.

## Continuous integration

`.github/workflows/validate-formula.yml` runs on pull requests, on pushes to
`main` that touch `Formula/**` or `scripts/**`, daily on a schedule, and on
explicit dispatch. Its jobs:

- `pins`: `shellcheck` over every script, then `scripts/test-guards.sh`, then
  every platform's pin from one runner, without Homebrew. Every check here is a
  shell script, so a shell defect is a guard defect.
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

One caveat worth knowing, because it silently disabled this workflow for its
first eleven months: a push made by a workflow using `GITHUB_TOKEN` does not
trigger other workflows. `update-formula.yml` therefore dispatches Validate
Formula explicitly after it pushes. A push you make yourself triggers it
normally.

## Questions?

Open an issue or reach out to [@rvben](https://github.com/rvben).
