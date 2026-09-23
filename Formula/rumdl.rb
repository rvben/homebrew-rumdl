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
    # Same as homebrew-core's rumdl formula, so a user moving between the two
    # keeps working `rumdl <TAB>` completions instead of silently losing them.
    generate_completions_from_executable(bin/"rumdl", "completions")
  end

  test do
    assert_match "rumdl #{version}", shell_output("#{bin}/rumdl --version")

    # --no-config on both runs: without it these assertions depend on no config
    # file being discovered by walking up from the test's working directory,
    # which is true on a CI runner and not necessarily true on a contributor's
    # machine.
    (testpath/"valid.md").write <<~EOS
      # Valid Heading

      This is valid markdown with proper spacing.

      - List item 1
      - List item 2
    EOS

    assert_match "Success", shell_output("#{bin}/rumdl check --no-config #{testpath}/valid.md")

    (testpath/"invalid.md").write <<~EOS
      # Bad Heading
      Missing blank line below heading
    EOS

    # The rule id and the exit status, and deliberately not the wording of the
    # message. Asserting the sentence "Expected 1 blank line below heading" tied
    # this formula to a format string in another repository
    # (src/rules/md022_blanks_around_headings.rs), so any rewording of a
    # diagnostic there would fail validation here, after release, pointing at the
    # formula instead of at the commit that caused it.
    output = shell_output("#{bin}/rumdl check --no-config #{testpath}/invalid.md 2>&1", 1)
    assert_match "MD022", output
  end
end
