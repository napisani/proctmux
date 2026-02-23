class Proctmux < Formula
  desc "tmux-based process manager with interactive TUI"
  homepage "https://github.com/napisani/proctmux"
  version "0.1.6"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-darwin-arm64.tar.gz"
      sha256 "d7ede3f39cdbbd78adf31b3b36a1882d81023bbfba1a44fba235c7b0d3c96126"
    else
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-darwin-amd64.tar.gz"
      sha256 "e0284b8a79c351f78c643aa4029c94b0882152b5d5b60923ea70301bdcd99504"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-linux-arm64.tar.gz"
      sha256 "6754c2f95b0bb6a891999aa342fb2a27b4d796d9eddd611b9998c6da2dad4773"
    else
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-linux-amd64.tar.gz"
      sha256 "978ebadd0a70d00b30d83570123496fa0f29f1699555faf41e6ea99a4b1e97c1"
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
