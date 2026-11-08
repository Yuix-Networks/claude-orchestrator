class ClaudeOrchestrator < Formula
  desc "Run multiple Claude Desktop instances and move sessions between them"
  homepage "https://github.com/Yuix-Networks/claude-orchestrator"
  url "https://github.com/Yuix-Networks/claude-orchestrator/releases/download/v0.2.4/claude-orchestrator-0.2.4.tar.gz"
  version "0.2.4"
  sha256 "c18c7f37601ebd23d9d6024e72b75ca6ace2d90c0a74b62f729bc0b898defe7b"
  license "MIT"

  depends_on macos: :ventura

  def install
    bin.install "claude-orchestrator"
  end

  def caveats
    <<~EOS
      Claude Desktop must be installed in /Applications/Claude.app.
      Existing instances in ~/Library/Application Support/claude-ctl keep working.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/claude-orchestrator --version")
  end
end
