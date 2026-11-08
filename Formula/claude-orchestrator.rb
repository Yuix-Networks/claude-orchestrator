class ClaudeOrchestrator < Formula
  desc "Run multiple Claude Desktop instances and move sessions between them"
  homepage "https://github.com/Yuix-Networks/claude-orchestrator"
  url "https://github.com/Yuix-Networks/claude-orchestrator/releases/download/v0.2.2/claude-orchestrator-0.2.2.tar.gz"
  version "0.2.2"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on macos: :ventura

  def install
    bin.install "claude-orchestrator"
    # v0.1.0 adıyla geriye dönük uyumluluk: eski ad uyarı verip çalışır.
    bin.install_symlink "claude-orchestrator" => "claude-ctl"
  end

  def caveats
    <<~EOS
      Claude Desktop must be installed in /Applications/Claude.app.
      `claude-ctl` is kept as a deprecated alias of `claude-orchestrator`.
      Existing instances in ~/Library/Application Support/claude-ctl keep working.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/claude-orchestrator --version")
  end
end
