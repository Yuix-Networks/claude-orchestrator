class ClaudeOrchestrator < Formula
  desc "Run multiple Claude Desktop instances and move sessions between them"
  homepage "https://github.com/Yuix-Networks/claude-orchestrator"
  url "https://github.com/Yuix-Networks/claude-orchestrator/releases/download/v0.2.5/claude-orchestrator-0.2.5.tar.gz"
  version "0.2.5"
  sha256 "527fec124b2f087ffec4c8232c815e20b6dd41769f7bc3b12aedb09fc9f86c9e"
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
