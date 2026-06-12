class Proctmux < Formula
  desc "Terminal process manager with interactive TUI"
  homepage "https://github.com/napisani/proctmux"
  version "0.2.6"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-darwin-arm64.tar.gz"
      sha256 "4ef261d6157679a5fee6c83afb457c36f4c732e81e07aa62b15da53cf973843a"
    else
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-darwin-amd64.tar.gz"
      sha256 "8ccfc30a096a52cef98899a57c231e306e8d8d0e2bc4ae12e0f8887cbeca1a25"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-linux-arm64.tar.gz"
      sha256 "db4b67451f5fccc3daa42795af39406b1a3cf5679a68867be54657646596fc0e"
    else
      url "https://github.com/napisani/proctmux/releases/download/v#{version}/proctmux-linux-amd64.tar.gz"
      sha256 "79189bc517b774d7b563490b8a46593f6b58afe89752760368acdabd1fb87375"
    end
  end

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
      To use proctmux:
        1. Create a proctmux.yaml file with: proctmux config-init
        2. Run proctmux in your terminal

      See https://github.com/napisani/proctmux for configuration and usage.
    EOS
  end

  test do
    assert_match "proctmux #{version}", shell_output("#{bin}/proctmux --version")
  end
end
