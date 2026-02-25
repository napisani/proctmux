class Proctmux < Formula
  desc "tmux-based process manager with interactive TUI"
  homepage "https://github.com/napisani/proctmux"
  version "0.1.8"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-darwin-arm64.tar.gz"
      sha256 "e18615adc71680eb7784d443e31eff7b4f85a4a3eedb8c7a59101a964d1dcdaa"
    else
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-darwin-amd64.tar.gz"
      sha256 "a8a7fe4ddeca14c18140e7b7f6e184f807c8778b10874ffb107c0b35ef80732e"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-linux-arm64.tar.gz"
      sha256 "d1783d5eecee52bfd0eccc7d618041ded8e3b054e239c79594cfc74fe77d6ecc"
    else
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-linux-amd64.tar.gz"
      sha256 "b8af37883d159ae6cd6644e5d154ca82aacd8cd8c397ccceb39961c6526c3401"
    end
  end

  depends_on "tmux"

  def install
    if OS.mac?
      bin.install "proctmux-darwin-arm64" => "proctmux" if Hardware::CPU.arm?
      bin.install "proctmux-darwin-amd64" => "proctmux" if Hardware::CPU.intel?
    elsif OS.linux?
      bin.install "proctmux-linux-arm64" => "proctmux" if Hardware::CPU.arm?
      bin.install "proctmux-linux-amd64" => "proctmux" if Hardware::CPU.intel?
    end
  end

  def caveats
    <<~EOS
      proctmux requires tmux to be running.

      To use proctmux:
        1. Start a tmux session: tmux
        2. Run proctmux inside the tmux session

      See https://github.com/napisani/proctmux for configuration and usage.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/proctmux --version 2>&1", 1)
  end
end
