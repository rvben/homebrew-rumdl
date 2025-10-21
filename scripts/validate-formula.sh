#!/bin/bash
# Validate the rumdl formula locally before pushing
# Inspired by Homebrew's PR requirements

set -e

echo "🔍 Validating rumdl formula..."

# Check if brew is installed
if ! command -v brew &> /dev/null; then
    echo "❌ Error: Homebrew is not installed"
    exit 1
fi

# Navigate to tap directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_DIR="$(dirname "$SCRIPT_DIR")"

echo "📂 Tap directory: $TAP_DIR"

# Ensure the tap is tapped
echo ""
echo "1️⃣  Tapping rvben/rumdl from local directory..."
brew tap --force rvben/rumdl "$TAP_DIR"

# Run brew audit
echo ""
echo "2️⃣  Running brew audit..."
if brew audit --formula rvben/rumdl/rumdl; then
    echo "✅ brew audit passed"
else
    echo "❌ brew audit failed"
    exit 1
fi

# Run brew style
echo ""
echo "3️⃣  Running brew style..."
if brew style rvben/rumdl/rumdl; then
    echo "✅ brew style passed"
else
    echo "❌ brew style failed"
    exit 1
fi

# Optional: Run strict audit (requires network)
echo ""
read -p "4️⃣  Run strict audit with online checks? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if brew audit --strict --online rvben/rumdl/rumdl; then
        echo "✅ brew audit --strict --online passed"
    else
        echo "❌ brew audit --strict --online failed"
        exit 1
    fi
fi

# Optional: Test installation
echo ""
read -p "5️⃣  Test installation? This will install rumdl (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Installing rumdl..."
    if brew install --verbose rvben/rumdl/rumdl; then
        echo "✅ Installation successful"

        echo ""
        echo "6️⃣  Running brew test..."
        if brew test rvben/rumdl/rumdl; then
            echo "✅ brew test passed"
        else
            echo "❌ brew test failed"
            exit 1
        fi

        echo ""
        echo "7️⃣  Verifying rumdl works..."
        if rumdl --version; then
            echo "✅ rumdl is working"
        else
            echo "❌ rumdl verification failed"
            exit 1
        fi
    else
        echo "❌ Installation failed"
        exit 1
    fi
fi

echo ""
echo "✅ All validations passed! Formula is ready to push."
