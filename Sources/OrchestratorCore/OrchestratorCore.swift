/// OrchestratorCore — the core logic of `claude-orchestrator`.
///
/// This module does not depend on AppKit; all file system, process and JSON
/// work lives here and is tested with XCTest. The menu bar UI lives in a
/// separate module (OrchestratorAgent).
///
/// Global rule: nothing is ever written to the `/Applications/Claude.app` bundle.
