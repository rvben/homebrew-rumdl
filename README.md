# homebrew-rumdl

Homebrew tap for [rumdl](https://github.com/rvben/rumdl) - A fast Rust-based Markdown linter with real-time diagnostics and auto-fixes.

## Installation

```bash
brew tap rvben/rumdl
brew install rumdl
```

Or install directly:

```bash
brew install rvben/rumdl/rumdl
```

## Updating

To update rumdl to the latest version:

```bash
brew update
brew upgrade rumdl
```

## Uninstallation

```bash
brew uninstall rumdl
brew untap rvben/rumdl
```

## Features

rumdl provides:
- 🚀 **Fast Performance**: Written in Rust for speed and efficiency
- 📝 **50+ Linting Rules**: Comprehensive Markdown validation with MD001-MD058
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

For more information, visit the [main repository](https://github.com/rvben/rumdl).

## Issues

If you encounter any issues with the Homebrew formula, please file an issue in this repository.

For issues with rumdl itself, please use the [main repository's issue tracker](https://github.com/rvben/rumdl/issues).

## License

The formula in this repository is licensed under the MIT License.

rumdl itself is also licensed under the MIT License.