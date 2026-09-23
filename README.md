# homebrew-rumdl

Homebrew tap for [rumdl](https://github.com/rvben/rumdl), a fast Rust-based
Markdown linter with real-time diagnostics and auto-fixes.

## Installation

```bash
brew install rvben/rumdl/rumdl
```

The fully qualified name is what installs from this tap. rumdl is also a
[homebrew-core](https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/r/rumdl.rb)
formula, and the bare name resolves to that one even with this tap added, so
`brew install rumdl` installs the core formula:

```bash
brew install rumdl
```

Either is a fine way to get rumdl, and which one is less work depends on the
machine. The core formula bottles both Linux architectures and the recent Apple
silicon macOS releases (`arm64_sequoia`, `arm64_tahoe`, `arm64_golden_gate`), and
installs those without a compiler. Every other machine it builds from source with
a Rust toolchain, because it declares `depends_on "rust" => :build` and has no
Intel macOS bottle and none for macOS older than those three. This tap pins a
prebuilt release binary for all four platforms and only ever downloads and unpacks
one, whatever the machine. Which machines get a bottle changes with core's
releases, so its `bottle do` block is the current answer.

Only one of them at a time, though: Homebrew refuses to have two formulae of the
same name from different taps installed together, so trying the second one after
the first aborts with "Formulae with the same name from different taps cannot be
installed at the same time". To switch, uninstall first:

```bash
brew uninstall rumdl
brew install rvben/rumdl/rumdl
```

Both formulae install shell completions, so switching does not cost you
`rumdl <TAB>`.

## Updating

To update rumdl to the latest version:

```bash
brew update
brew upgrade rvben/rumdl/rumdl
```

## Uninstallation

```bash
brew uninstall rvben/rumdl/rumdl
brew untap rvben/rumdl
```

## Features

rumdl provides:

- 🚀 **Fast Performance**: Written in Rust for speed and efficiency
- 📝 **80+ Linting Rules**: MD001 onwards, including rules with no
  markdownlint equivalent
- 🔧 **Auto-fix Support**: Automatically fix many common issues
- 🎯 **Smart Defaults**: Sensible configuration out of the box
- 🔌 **Editor Integration**: LSP support for VS Code, Neovim, and other editors
- 🐍 **Python Bindings**: Install via pip for Python integration
- 📊 **Multiple Output Formats**: JSON, SARIF, GitHub, GitLab, and more

## Usage

Check a single file:

```bash
rumdl check README.md
```

Check and auto-fix issues:

```bash
rumdl check --fix README.md
```

Check all Markdown files in a directory:

```bash
rumdl check .
```

For more information, visit the
[main repository](https://github.com/rvben/rumdl).

## Issues

If you encounter any issues with the Homebrew formula, please file an issue in
this repository.

For issues with rumdl itself, please use the [main repository's issue tracker](https://github.com/rvben/rumdl/issues).

## License

The formula in this repository is licensed under the MIT License.

rumdl itself is also licensed under the MIT License.
