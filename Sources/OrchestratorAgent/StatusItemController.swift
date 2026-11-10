import AppKit
import Darwin
import OrchestratorCore
import Foundation

/// Manages the menu bar icons.
///
/// Creates one `NSStatusItem` per defined instance; its icon is the Claude
/// icon and its label is a short form of the instance name.
public final class StatusItemController {
    private let model: AgentModel
    private let paths: Paths
    private var statusItems: [String: NSStatusItem] = [:]
    /// Status each menu was last built for; the menu is not rebuilt if it hasn't changed.
    private var renderedStatuses: [String: InstanceStatus] = [:]
    private var timer: Timer?
    /// File descriptor holding the singleton lock (the kernel releases it when the process dies).
    private var lockDescriptor: Int32 = -1

    public init(model: AgentModel, paths: Paths = .default) {
        self.model = model
        self.paths = paths
    }

    /// Starts the agent. Returns `false` if another agent is already running.
    @discardableResult
    public func start() -> Bool {
        guard acquireSingleton() else { return false }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        return true
    }

    /// Singleton lock: an exclusive `flock` on `agent.lock`.
    ///
    /// The lock is taken atomically (no TOCTOU race) and the kernel releases it
    /// when the process dies, so a stale pid file can never leave the agent stuck
    /// as "already running". The pid is written for information only.
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

    /// Releases the lock (for tests and clean shutdown).
    public func releaseSingleton() {
        guard lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }

    /// Refreshes the statuses and updates the menu bar icons.
    public func refresh() {
        let statuses = model.refresh()
        let names = Set(statuses.map(\.name))

        // Iterate over a copy of the keys: the dictionary changes inside the loop.
        for name in Array(statusItems.keys) where !names.contains(name) {
            if let item = statusItems.removeValue(forKey: name) {
                NSStatusBar.system.removeStatusItem(item)
            }
            renderedStatuses[name] = nil
        }

        for status in statuses {
            // Don't rebuild the menu if the status hasn't changed (avoids flicker).
            if statusItems[status.name] != nil, renderedStatuses[status.name] == status { continue }
            let item = statusItems[status.name] ?? makeStatusItem()
            statusItems[status.name] = item
            renderedStatuses[status.name] = status

            let badge = status.name.count > 2 ? String(status.name.suffix(2)) : status.name
            item.button?.title = status.isRunning ? badge : ""
            item.button?.image = AppKitSupport.claudeIcon()
            item.button?.toolTip = "\(status.name) — \(status.isRunning ? "running" : "stopped")"
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

/// The action info carried by a menu item.
private final class ActionBox: NSObject {
    let action: AgentAction
    let name: String

    init(action: AgentAction, name: String) {
        self.action = action
        self.name = name
    }
}
