/// OrchestratorCore — `claude-orchestrator` aracının çekirdek mantığı.
///
/// Bu modül AppKit'e bağımlı değildir; tüm dosya sistemi, süreç ve JSON
/// işlemleri burada yaşar ve XCTest ile test edilir. Menü çubuğu arayüzü
/// ayrı bir modüldedir (OrchestratorAgent).
///
/// Global kural: `/Applications/Claude.app` bundle'ine asla yazılmaz.
