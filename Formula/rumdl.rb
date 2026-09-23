class Rumdl < Formula
  desc "Fast Markdown linter and formatter"
  homepage "https://github.com/rvben/rumdl"
  license "MIT"

  # No `version` line on purpose: Homebrew scans the version out of the urls
  # below, and declaring it as well fails `brew audit` ("redundant with version
  # scanned from URL"). The urls therefore carry the version literally, and
  # scripts/verify-formula.sh checks that every one of them agrees.
  # scripts/update-formula.sh rewrites them together.

  livecheck do
    url :stable
    strategy :github_latest
  end

  # Platform-specific downloads
  on_macos do
    if Hardware::CPU.intel?
      url "https://github.com/rvben/rumdl/releases/download/v0.2.76/rumdl-v0.2.76-x86_64-apple-darwin.tar.gz"
      sha256 "415df77d4c5d11f336733c9570a72cd0a188d8e6a7460a76134c4c033ec5ece7"
    elsif Hardware::CPU.arm?
      url "https://github.com/rvben/rumdl/releases/download/v0.2.76/rumdl-v0.2.76-aarch64-apple-darwin.tar.gz"
      sha256 "10ec95ee46e1d3f67560250db97725681a5fa4bc488f383615cc54b06c4bdbc7"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      # Use static musl binaries for better portability on Linux
      url "https://github.com/rvben/rumdl/releases/download/v0.2.76/rumdl-v0.2.76-x86_64-unknown-linux-musl.tar.gz"
      sha256 "0fe0c75a72849e877a779538d550cbefb2b4656911de188dac54067995a6ae2f"
    elsif Hardware::CPU.arm?
      # Use static musl binaries for better portability on Linux
      url "https://github.com/rvben/rumdl/releases/download/v0.2.76/rumdl-v0.2.76-aarch64-unknown-linux-musl.tar.gz"
      sha256 "ef4f1a707dad07f2fcfe207959ed03f2de6e0e0ff9e0c236dd64e89d88d75758"
    end
  end

  def install
    bin.install "rumdl"
  end

  test do
    # Test version output
    assert_match "rumdl #{version}", shell_output("#{bin}/rumdl --version")

    # Test that rumdl successfully checks valid markdown (exit code 0)
    (testpath/"valid.md").write <<~EOS
      # Valid Heading

      This is valid markdown with proper spacing.

      - List item 1
      - List item 2
    EOS

    output = shell_output("#{bin}/rumdl check #{testpath}/valid.md")
    assert_match "No issues found", output

    # Test that rumdl detects issues in invalid markdown (exit code 1)
    (testpath/"invalid.md").write <<~EOS
      # Bad Heading
      Missing blank line below heading
    EOS

    output = shell_output("#{bin}/rumdl check #{testpath}/invalid.md 2>&1", 1)
    assert_match "MD022", output
    assert_match "Expected 1 blank line below heading", output
  end
end
