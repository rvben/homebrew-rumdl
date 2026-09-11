class Rumdl < Formula
  desc "Fast Markdown linter and formatter"
  homepage "https://github.com/rvben/rumdl"
  license "MIT"
  version "0.2.72"

  livecheck do
    url :stable
    strategy :github_latest
  end

  # Platform-specific downloads
  on_macos do
    if Hardware::CPU.intel?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-x86_64-apple-darwin.tar.gz"
      sha256 "46353520dfb2bdd201e7e398e5f9780fca4d4c81bd7bf0bbbbc7f58e69aa7cac"
    elsif Hardware::CPU.arm?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "357aa36c53013563afe6fc5a9f8b24f070e569306995703feca93dee8b19b43a"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      # Use static musl binaries for better portability on Linux
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-x86_64-unknown-linux-musl.tar.gz"
      sha256 "1082d4b72dfc620f35ec348ec37cdeea53f548e5c96bc9aaad591d9e720bf16b"
    elsif Hardware::CPU.arm?
      # Use static musl binaries for better portability on Linux
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-aarch64-unknown-linux-musl.tar.gz"
      sha256 "d6c70e82cf59a046fda2dd84b7d3f5d667cbaff1838c576e3c2e57dc19fd7950"
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