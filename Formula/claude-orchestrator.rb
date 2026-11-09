class ClaudeOrchestrator < Formula
  desc "Run multiple Claude Desktop instances and move sessions between them"
  homepage "https://github.com/Yuix-Networks/claude-orchestrator"
  url "https://github.com/Yuix-Networks/claude-orchestrator/releases/download/v0.2.8/claude-orchestrator-0.2.8.tar.gz"
  version "0.2.8"
  sha256 "9d58f1e01354338a73762b1ec6a01f24d71d260b3bdd1a4a61eb76b37f6f6efd"
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
