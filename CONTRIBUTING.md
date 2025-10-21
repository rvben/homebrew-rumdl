# Contributing to homebrew-rumdl

Thank you for considering contributing to the rumdl Homebrew tap!

## Formula Quality Standards

This tap follows Homebrew's quality standards to ensure a great user experience.

### Validation Requirements

All formula changes must pass these checks:

1. **brew audit** - Formula validation
2. **brew style** - Ruby style compliance
3. **brew test** - Formula tests pass
4. **brew audit --strict --online** - Comprehensive validation (CI only)

### Testing Changes Locally

Before submitting a PR, validate your changes locally:

```bash
# Quick validation
./scripts/validate-formula.sh
```

The script will guide you through:
- Formula audit
- Style checks
- Optional strict audit
- Optional installation test

### Manual Validation

If you prefer to run commands manually:

```bash
# Tap from local directory
brew tap --force rvben/rumdl /path/to/homebrew-rumdl

# Run audit
brew audit --formula rvben/rumdl/rumdl

# Check style
brew style rvben/rumdl/rumdl

# Test installation
brew install --verbose rvben/rumdl/rumdl

# Run tests
brew test rvben/rumdl/rumdl

# Strict audit (optional, requires network)
brew audit --strict --online rvben/rumdl/rumdl
```

## Continuous Integration

GitHub Actions automatically validates all PRs and commits:

- **Multi-platform testing**: macOS and Linux
- **All brew checks**: audit, style, test
- **Installation verification**: Ensures rumdl actually works

See `.github/workflows/validate-formula.yml` for details.

## Formula Updates

When rumdl releases a new version:

1. **Automated**: The `update-formula.yml` workflow can be triggered
2. **Manual**: Update version and SHA256 hashes in `Formula/rumdl.rb`

Always validate changes before pushing!

## Questions?

Open an issue or reach out to [@rvben](https://github.com/rvben).
