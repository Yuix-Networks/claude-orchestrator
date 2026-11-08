class ClaudeCtl < Formula
  desc "Run Claude Desktop as multiple independent instances on macOS"
  homepage "https://github.com/akarca/claude-ctl"
  url "https://github.com/akarca/claude-ctl/releases/download/v0.1.0/claude-ctl-0.1.0.tar.gz"
  version "0.1.0"
  license "MIT"

  sha256 "673d75b170bb46502f4b14f732e4eac7aaea5ba91b279e6055d2fd0618eef475"

  depends_on "macos" => :ventura

  def install
    bin.install "claude-ctl"
  end

  def caveats
    <<~EOS
      Claude Desktop must be installed in /Applications/Claude.app.
    EOS
  end
end
