class ClaudeOrchestrator < Formula
  desc "Run multiple Claude Desktop instances and move sessions between them"
  homepage "https://github.com/Yuix-Networks/claude-orchestrator"
  url "https://github.com/Yuix-Networks/claude-orchestrator/releases/download/v0.2.11/claude-orchestrator-0.2.11.tar.gz"
  version "0.2.11"
  sha256 "65a45722229b740b6aff5decac1f7079375587690c50335472270eed3e129fdb"
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
