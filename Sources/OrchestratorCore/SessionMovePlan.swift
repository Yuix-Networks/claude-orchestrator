import Foundation

/// Flow that shuts down running instances, moves the session, then reopens them
/// (interactive `session move`).
///
/// The steps are passed in, so ordering and error handling can be tested
/// without starting or stopping real processes.
public struct SessionMovePlan {
    public struct Outcome {
        /// Instances that were stopped (and that we tried to reopen), in order.
        public var stopped: [String]
        public var restarted: [String]
        /// Instances that couldn't be reopened, and why.
        public var restartFailures: [(name: String, error: String)]
        public var result: TransferResult
    }

    /// Source, target: stopped and reopened in this order.
    public var instances: [String]
    public var isRunning: (String) -> Bool
    public var stop: (String) throws -> Void
    public var start: (String) throws -> Void
    /// Called after the instances have shut down.
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

    /// Stopped instances are reopened even if the transfer fails;
    /// the transfer error is thrown afterwards.
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
    /// Moves the session; if the source and target are running, they are shut
    /// down in turn first and reopened after the move.
    public func moveSessionRestarting(
        _ located: LocatedSession,
        to targetName: String,
        progress: @escaping (String) -> Void = { _ in }
    ) throws -> SessionMovePlan.Outcome {
        try transferSessionRestarting(located, to: targetName, move: true, progress: progress)
    }

    /// Copies or moves the session. The instances written to (only the target for
    /// a copy, source + target for a move) are shut down in turn if running, and
    /// reopened after the transfer.
    public func transferSessionRestarting(
        _ located: LocatedSession,
        to targetName: String,
        move: Bool,
        progress: @escaping (String) -> Void = { _ in }
    ) throws -> SessionMovePlan.Outcome {
        let target = try endpoint(targetName)
        let touched = move ? [located.endpoint, target] : [target]
        for endpoint in touched where endpoint.isDefault && endpoint.isRunning {
            throw OrchestratorError.runtime(
                "the default Claude (not an instance) is running — quit it yourself first"
            )
        }
        let plan = SessionMovePlan(
            instances: touched.map(\.name).filter { $0 != SessionEndpoint.defaultName },
            isRunning: { [self] name in (try? endpoint(name).isRunning) ?? false },
            stop: { [self] name in
                _ = try stop(name: name)
                if (try? endpoint(name).isRunning) == true {
                    throw OrchestratorError.runtime("couldn't stop instance: \(name)")
                }
            },
            start: { [self] name in _ = try start(name: name, folder: nil) },
            transfer: { [self] in
                // Re-read the endpoints after stopping so isRunning is up to date.
                let fresh = LocatedSession(endpoint: try endpoint(located.endpoint.name), session: located.session)
                return try transfer(fresh, to: targetName, move: move)
            },
            progress: { progress(move ? $0 : $0.replacingOccurrences(of: "Moving", with: "Copying")) }
        )
        return try plan.run()
    }
}
