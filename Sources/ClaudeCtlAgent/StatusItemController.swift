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
    /// Menüsü en son kurulan durum; değişmediyse menü yeniden kurulmaz.
    private var renderedStatuses: [String: InstanceStatus] = [:]
    private var timer: Timer?
    /// Singleton kilidini tutan dosya tanımlayıcısı (süreç ölünce çekirdek bırakır).
    private var lockDescriptor: Int32 = -1

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

    /// Singleton kilidi: `agent.lock` üzerinde özel `flock`.
    ///
    /// Kilit atomik olarak alınır (TOCTOU yarışı yok) ve süreç öldüğünde
    /// çekirdek tarafından bırakılır; bayat bir pid dosyası agent'ı kalıcı
    /// olarak "zaten çalışıyor" durumuna sokamaz. Pid yalnızca bilgi amaçlı yazılır.
    public func acquireSingleton() -> Bool {
        if lockDescriptor >= 0 { return true }
        try? FileManager.default.createDirectory(at: paths.stateDirectory, withIntermediateDirectories: true)
        let lockPath = paths.stateDirectory.appendingPathComponent("agent.lock").path

        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        ftruncate(descriptor, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(descriptor, $0, strlen($0)) }
        lockDescriptor = descriptor
        return true
    }

    /// Kilidi bırakır (testler ve düzgün kapanış için).
    public func releaseSingleton() {
        guard lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }

    /// Durumları yeniler ve menü çubuğu ikonlarını günceller.
    public func refresh() {
        let statuses = model.refresh()
        let names = Set(statuses.map(\.name))

        // Anahtarların kopyası üzerinde dönülür: sözlük döngü içinde değişiyor.
        for name in Array(statusItems.keys) where !names.contains(name) {
            if let item = statusItems.removeValue(forKey: name) {
                NSStatusBar.system.removeStatusItem(item)
            }
            renderedStatuses[name] = nil
        }

        for status in statuses {
            // Durum değişmediyse menüyü yeniden kurma (gereksiz titreme olmasın).
            if statusItems[status.name] != nil, renderedStatuses[status.name] == status { continue }
            let item = statusItems[status.name] ?? makeStatusItem()
            statusItems[status.name] = item
            renderedStatuses[status.name] = status

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
