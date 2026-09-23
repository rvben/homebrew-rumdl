# Contributing to homebrew-rumdl

Thank you for considering contributing to the rumdl Homebrew tap!

## The invariant that matters most

Every `sha256` in `Formula/rumdl.rb` must be the hash of the artifact fetched by
the `url` directly above it, and every `url` must name the same version.

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

Normally you do not run it at all: rumdl's release workflow sends a
`repository_dispatch` and `.github/workflows/update-formula.yml` does the above,
commits, pushes, and then asks Validate Formula to run.

## Validating locally

```bash
./scripts/validate-formula.sh            # pins, audit, style, strict audit
./scripts/validate-formula.sh --install  # also brew install and brew test
```

This runs what CI runs, in the same order. Two things to know:

- `brew tap --force rvben/rumdl <path>` clones the repository, so the `brew`
  checks see `HEAD`, not your uncommitted changes. Commit first if you want brew
  to see your edit. The pin check at the start reads the working tree directly,
  so it always reflects what you have now.
- It taps `rvben/rumdl` from your local checkout, which changes your local
  Homebrew state. `brew untap rvben/rumdl` afterwards if you would rather it did
  not.

## Continuous integration

`.github/workflows/validate-formula.yml` runs on pull requests, on pushes to
`main` that touch `Formula/**` or `scripts/**`, and on explicit dispatch:

- `pins`: every platform's pin, from one runner, without Homebrew.
- `audit-and-test`: `brew audit`, `brew style`, `brew install`, `brew test` on
  macOS and Linux. Each runner can only check the pin for the platform it runs
  on, which is why the `pins` job exists.
- `strict-audit`: `brew audit --strict --online`.

One caveat worth knowing, because it silently disabled this workflow for its
first eleven months: a push made by a workflow using `GITHUB_TOKEN` does not
trigger other workflows. `update-formula.yml` therefore dispatches Validate
Formula explicitly after it pushes. A push you make yourself triggers it
normally.

## Questions?

Open an issue or reach out to [@rvben](https://github.com/rvben).
