class Rumdl < Formula
  desc "Fast Rust-based Markdown linter with real-time diagnostics and auto-fixes"
  homepage "https://github.com/rvben/rumdl"
  license "MIT"
  version "0.0.114"

  # Platform-specific downloads
  on_macos do
    if Hardware::CPU.intel?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-x86_64-apple-darwin.tar.gz"
      sha256 "290988c4504172e0a9f9e7da0c89ebdb858c015a6119b4cf935e1326cd9fe5ed"
    elsif Hardware::CPU.arm?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "914e198209a35da55d687f11c53e39e1e2ca2366a5d5c570a0feb6334916599f"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      # Use static musl binaries for better portability on Linux
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-x86_64-unknown-linux-musl.tar.gz"
      sha256 "7ae1bd6fbc2ab97b349243ae853ccca0eb9f3889bd1d2a764087eb81a80c71d2"
    elsif Hardware::CPU.arm?
      # Use static musl binaries for better portability on Linux
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-aarch64-unknown-linux-musl.tar.gz"
      sha256 "daaf15c9d0e776d722272a991145d17a7fb9f5a1364d786f5facfd95af6bf5da"
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