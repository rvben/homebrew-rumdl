class Rumdl < Formula
  desc "Fast Rust-based Markdown linter with real-time diagnostics and auto-fixes"
  homepage "https://github.com/rvben/rumdl"
  license "MIT"
  version "0.0.104"

  # Platform-specific downloads
  on_macos do
    if Hardware::CPU.intel?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-x86_64-apple-darwin.tar.gz"
      sha256 "722dc703525aa3ab12c2696c6f63692843cc5acd36fb0df499c089ef62f11fec"
    elsif Hardware::CPU.arm?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "dadf0def6f9a386270c3ce90ae917ef0d780671af7bddef3238fc81b88644cef"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "PLACEHOLDER_LINUX_X86_SHA256"
    elsif Hardware::CPU.arm?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-aarch64-unknown-linux-gnu.tar.gz"
      sha256 "PLACEHOLDER_LINUX_ARM_SHA256"
    end
  end

  def install
    bin.install "rumdl"
  end

  test do
    # Create a test markdown file
    (testpath/"test.md").write <<~EOS
      # Test Heading

      This is a test file for rumdl.
      
      - List item 1
      - List item 2
    EOS

    # Test that rumdl runs without error
    system "#{bin}/rumdl", "--version"
    
    # Test linting functionality
    output = shell_output("#{bin}/rumdl check #{testpath}/test.md 2>&1", 0)
    
    # Basic check that it processed the file
    assert_match(/test\.md|No issues found|Found \d+ issue/, output)
  end
end