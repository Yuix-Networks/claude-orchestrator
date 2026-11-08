class ClaudeOrchestrator < Formula
  desc "Run multiple Claude Desktop instances and move sessions between them"
  homepage "https://github.com/Yuix-Networks/claude-orchestrator"
  url "https://github.com/Yuix-Networks/claude-orchestrator/releases/download/v0.2.6/claude-orchestrator-0.2.6.tar.gz"
  version "0.2.6"
  sha256 "bf19ee2f08dc81360e27433b5ee6e8aaf20584cfdf43bcd5c9af65b589e8cfa5"
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
