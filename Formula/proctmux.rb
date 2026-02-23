class Proctmux < Formula
  desc "tmux-based process manager with interactive TUI"
  homepage "https://github.com/napisani/proctmux"
  version "0.1.7"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-darwin-arm64.tar.gz"
      sha256 "0af007c9c26a1521f0fe732a55284fe8c0a141735e918d30eeefddf537edafd0"
    else
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-darwin-amd64.tar.gz"
      sha256 "ee3c7cee1cfc3da0b682a57c7f7a9d9337308a52f7d0e0d014a92856487b67c5"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-linux-arm64.tar.gz"
      sha256 "e1f7d3e65d73c1463f8769fbd3b73245c9d7bc236595b55bcb8565b624ddeb6a"
    else
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-linux-amd64.tar.gz"
      sha256 "d45808e50b668fdf8f6163d3f1d18f5f7aed9e0b713ed3316d6d73b2779d7b64"
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
