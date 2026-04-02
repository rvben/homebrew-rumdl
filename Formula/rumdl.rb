class Rumdl < Formula
  desc "Fast Markdown linter and formatter"
  homepage "https://github.com/rvben/rumdl"
  license "MIT"
  version "0.1.66"

  livecheck do
    url :stable
    strategy :github_latest
  end

  # Platform-specific downloads
  on_macos do
    if Hardware::CPU.intel?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-x86_64-apple-darwin.tar.gz"
      sha256 "7e54b2f368f1086f442b198be7a1487b68f51c69af21c1ac9553c537ce9753b3"
    elsif Hardware::CPU.arm?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "2efc4215d6edf9f2ab3f8a9bc2ce4cb9312001b506fc9e715c715222a481fb39"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      # Use static musl binaries for better portability on Linux
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-x86_64-unknown-linux-musl.tar.gz"
      sha256 "11c4aa30afce57054a8436dc6b14e6462645f52bb0c08d8bd6c8f53630143ae6"
    elsif Hardware::CPU.arm?
      # Use static musl binaries for better portability on Linux
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-aarch64-unknown-linux-musl.tar.gz"
      sha256 "84cbbe7156cb65199152072590a58a9b6571b26d486f5951cf1965ffaaed8b46"
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