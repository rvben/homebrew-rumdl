class Rumdl < Formula
  desc "Fast Rust-based Markdown linter with real-time diagnostics and auto-fixes"
  homepage "https://github.com/rvben/rumdl"
  license "MIT"
  version "0.0.160"

  # Platform-specific downloads
  on_macos do
    if Hardware::CPU.intel?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-x86_64-apple-darwin.tar.gz"
      sha256 "60edfd435ae96251c75bb919d7245b5f9f6dd0a86c4ce18c2f55342d323d99e4"
    elsif Hardware::CPU.arm?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "3438ef3dd9b1b2c8b43367dd1a70b3fb7fa388c58a1be1809760b05f7f239979"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      # Use static musl binaries for better portability on Linux
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-x86_64-unknown-linux-musl.tar.gz"
      sha256 "b376f8ec3694dbd144ae9309d72b2d92a6e51fbbc662c90c969fbba98756bba0"
    elsif Hardware::CPU.arm?
      # Use static musl binaries for better portability on Linux
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-aarch64-unknown-linux-musl.tar.gz"
      sha256 "dba22932cab028983bdaf9268db9af17e365f3e19e7ecd8567a0277448aa2448"
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