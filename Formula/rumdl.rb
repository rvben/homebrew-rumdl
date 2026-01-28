class Rumdl < Formula
  desc "Fast Markdown linter and formatter"
  homepage "https://github.com/rvben/rumdl"
  license "MIT"
  version "0.1.4"

  livecheck do
    url :stable
    strategy :github_latest
  end

  # Platform-specific downloads
  on_macos do
    if Hardware::CPU.intel?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-x86_64-apple-darwin.tar.gz"
      sha256 "c968477f2bc930e465c26f5d255d38c6fcf51554d05a4462d15ce3c63b687ecf"
    elsif Hardware::CPU.arm?
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "35efe57bc1147e9944c8dd3aa111c6b01f0e6871697c68043af77e4a5f1641d3"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      # Use static musl binaries for better portability on Linux
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-x86_64-unknown-linux-musl.tar.gz"
      sha256 "6aa49917f9ac3ddf57aa15339ba75206bcda36f1d722f71af4644cedd6836bdb"
    elsif Hardware::CPU.arm?
      # Use static musl binaries for better portability on Linux
      url "https://github.com/rvben/rumdl/releases/download/v#{version}/rumdl-v#{version}-aarch64-unknown-linux-musl.tar.gz"
      sha256 "15a00ece3e0708c06198add11f2b49728f32d734e41171a83bb4ce69cf17483e"
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