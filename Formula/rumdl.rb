class Rumdl < Formula
  desc "Fast Rust-based Markdown linter with real-time diagnostics and auto-fixes"
  homepage "https://github.com/rvben/rumdl"
  license "MIT"
  version "0.0.151"

  # Platform-specific downloads
  on_macos do
    if Hardware::CPU.intel?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-x86_64-apple-darwin.tar.gz"
      sha256 "9bf3227e3da203fef45832846603dc0a25ee7ad514c5dc1720a59d533bf5d6d2"
    elsif Hardware::CPU.arm?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "ceeb22407f5cefe1800b412d37bc598835b517c7aa7cac02edafc7cb5ef72a33"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      # Use static musl binaries for better portability on Linux
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-x86_64-unknown-linux-musl.tar.gz"
      sha256 "aa5130ebae53c494d6f10ac55b60932d11fa2725d20ed11699d98caadcf91525"
    elsif Hardware::CPU.arm?
      # Use static musl binaries for better portability on Linux
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-aarch64-unknown-linux-musl.tar.gz"
      sha256 "60627581b6f3c1bda2527266da99c3ea145d810bf9d1e8c27418da133de71876"
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