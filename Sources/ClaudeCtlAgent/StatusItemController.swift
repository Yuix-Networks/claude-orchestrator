import AppKit
import Darwin
import ClaudeCtlCore
import Foundation

/// Menü çubuğu ikonlarını yönetir.
///
/// Her çalışan/tanımlı instance için bir `NSStatusItem` oluşturur; ikonu
/// Claude ikonudur, etiketi instance adının kısa biçimidir.
public final class StatusItemController {
    private let model: AgentModel
    private let paths: Paths
    private var statusItems: [String: NSStatusItem] = [:]
    private var timer: Timer?

    public init(model: AgentModel, paths: Paths = .default) {
        self.model = model
        self.paths = paths
    }

    /// Agent'ı başlatır. Başka bir agent çalışıyorsa `false` döner.
    @discardableResult
    public func start() -> Bool {
        guard acquireSingleton() else { return false }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        return true
    }

    /// Singleton kilidi: pid dosyasında canlı bir pid varsa bu agent ikinci örnektir.
    public func acquireSingleton() -> Bool {
        let pidFile = paths.stateDirectory.appendingPathComponent("agent.pid")

        if let data = try? Data(contentsOf: pidFile),
           let text = String(data: data, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           ProcessSignal.isAlive(pid) {
            return false
        }

        try? FileManager.default.createDirectory(at: paths.stateDirectory, withIntermediateDirectories: true)
        try? Data(String(Int32(getpid())).utf8).write(to: pidFile)
        return true
    }

    /// Durumları yeniler ve menü çubuğu ikonlarını günceller.
    public func refresh() {
        let statuses = model.refresh()
        let names = Set(statuses.map(\.name))

        for name in statusItems.keys where !names.contains(name) {
            statusItems[name]?.menu = nil
            statusItems[name] = nil
        }

        for status in statuses {
            let item = statusItems[status.name] ?? makeStatusItem()
            statusItems[status.name] = item

            let badge = status.name.count > 2 ? String(status.name.suffix(2)) : status.name
            item.button?.title = status.isRunning ? badge : ""
            item.button?.image = AppKitSupport.claudeIcon()
            item.button?.toolTip = "\(status.name) — \(status.isRunning ? "çalışıyor" : "durdu")"
            item.menu = makeMenu(for: status)
        }
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = AppKitSupport.claudeIcon()
        return item
    }

    private func makeMenu(for status: InstanceStatus) -> NSMenu {
        let menu = NSMenu()
        for entry in model.menuItems(for: status) {
            let item = NSMenuItem(title: entry.title, action: #selector(handleAction(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = entry.isEnabled
            item.representedObject = ActionBox(action: entry.action, name: status.name)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func handleAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox,
              let status = model.refresh().first(where: { $0.name == box.name }) else { return }
        model.perform(box.action, for: status)
    }
}

/// Menü öğesinin taşıdığı eylem bilgisi.
private final class ActionBox: NSObject {
    let action: AgentAction
    let name: String

    init(action: AgentAction, name: String) {
        self.action = action
        self.name = name
    }
}
