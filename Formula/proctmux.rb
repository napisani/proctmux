class Proctmux < Formula
  desc "tmux-based process manager with interactive TUI"
  homepage "https://github.com/napisani/proctmux"
  version "0.1.9"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-darwin-arm64.tar.gz"
      sha256 "5c76e57f2d6debdad35abfdc13106ba27f347c25f6ae43c1a79d3392e897d220"
    else
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-darwin-amd64.tar.gz"
      sha256 "07f2b58e9e636c7676960d471b0159bddb4ccc5e4fc24beb9a2400b02ac9ba0d"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-linux-arm64.tar.gz"
      sha256 "04fc88c04d2cc9928e4b6f15e26c39b55c85abf867761ce2d4a9417046e4e684"
    else
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-linux-amd64.tar.gz"
      sha256 "4fa73d562ab8e2eedf8caed6791332af4d926387e764c87033000010665f115a"
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
