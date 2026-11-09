import Foundation

/// Çalışan instance'ları kapatıp oturumu taşıyan, sonra yeniden açan akış
/// (etkileşimli `session move`).
///
/// Adımlar dışarıdan verilir; böylece sıra ve hata davranışı gerçek süreç
/// başlatıp durdurmadan test edilebilir.
public struct SessionMovePlan {
    public struct Outcome {
        /// Durdurulan (ve yeniden açılması denenen) instance'lar, sırayla.
        public var stopped: [String]
        public var restarted: [String]
        /// Yeniden açılamayanlar ve sebebi.
        public var restartFailures: [(name: String, error: String)]
        public var result: TransferResult
    }

    /// Kaynak, hedef: aynı sırayla durdurulur ve yeniden açılır.
    public var instances: [String]
    public var isRunning: (String) -> Bool
    public var stop: (String) throws -> Void
    public var start: (String) throws -> Void
    /// Instance'lar kapandıktan sonra çağrılır.
    public var transfer: () throws -> TransferResult
    public var progress: (String) -> Void

    public init(
        instances: [String],
        isRunning: @escaping (String) -> Bool,
        stop: @escaping (String) throws -> Void,
        start: @escaping (String) throws -> Void,
        transfer: @escaping () throws -> TransferResult,
        progress: @escaping (String) -> Void = { _ in }
    ) {
        self.instances = instances
        self.isRunning = isRunning
        self.stop = stop
        self.start = start
        self.transfer = transfer
        self.progress = progress
    }

    /// Transfer başarısız olsa bile durdurulan instance'lar yeniden açılır;
    /// ardından transfer hatası fırlatılır.
    public func run() throws -> Outcome {
        var stopped: [String] = []
        var transferResult: Result<TransferResult, Error>

        do {
            for name in instances where isRunning(name) {
                progress("Shutting down \(name)…")
                try stop(name)
                stopped.append(name)
            }
            progress("Moving session…")
            transferResult = .success(try transfer())
        } catch {
            transferResult = .failure(error)
        }

        var restarted: [String] = []
        var failures: [(name: String, error: String)] = []
        for name in stopped {
            progress("Restarting \(name)…")
            do {
                try start(name)
                restarted.append(name)
            } catch {
                failures.append((name, "\(error)"))
            }
        }

        let result = try transferResult.get()
        return Outcome(stopped: stopped, restarted: restarted, restartFailures: failures, result: result)
    }
}

extension Orchestrator {
    /// Oturumu taşır; kaynak ve hedef çalışıyorsa önce sırayla kapatılır,
    /// taşımadan sonra yeniden açılır.
    public func moveSessionRestarting(
        _ located: LocatedSession,
        to targetName: String,
        progress: @escaping (String) -> Void = { _ in }
    ) throws -> SessionMovePlan.Outcome {
        let target = try endpoint(targetName)
        for endpoint in [located.endpoint, target] where endpoint.isDefault && endpoint.isRunning {
            throw OrchestratorError.runtime(
                "varsayılan Claude (instance dışı) çalışıyor — önce kendin kapat"
            )
        }
        let plan = SessionMovePlan(
            instances: [located.endpoint.name, target.name].filter { $0 != SessionEndpoint.defaultName },
            isRunning: { [self] name in (try? endpoint(name).isRunning) ?? false },
            stop: { [self] name in
                _ = try stop(name: name)
                if (try? endpoint(name).isRunning) == true {
                    throw OrchestratorError.runtime("instance durdurulamadı: \(name)")
                }
            },
            start: { [self] name in _ = try start(name: name, folder: nil) },
            transfer: { [self] in
                // Uç noktalar durdurmadan sonra yeniden okunur (isRunning güncel olsun).
                let fresh = LocatedSession(endpoint: try endpoint(located.endpoint.name), session: located.session)
                return try transfer(fresh, to: targetName, move: true)
            },
            progress: progress
        )
        return try plan.run()
    }
}
