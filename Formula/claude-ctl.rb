class ClaudeCtl < Formula
  desc "Run Claude Desktop as multiple independent instances on macOS"
  homepage "https://github.com/akarca/claude-ctl"
  url "https://github.com/akarca/claude-ctl/releases/download/v0.1.0/claude-ctl-0.1.0.tar.gz"
  version "0.1.0"
  license "MIT"

  # TODO(release): `sha256` ilk release sonrası doldurulur.
  # `curl -sL <url> | shasum -a 256` çıktısı buraya yazılır.
  sha256 "SHA256_YER_TUTUCUSU"

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
