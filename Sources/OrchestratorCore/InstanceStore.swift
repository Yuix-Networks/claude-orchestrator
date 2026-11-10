import Foundation

/// Instance CRUD operations on `config.json`.
public final class InstanceStore {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    /// Reads the config file. Returns an empty config if the file doesn't exist.
    ///
    /// Invalid instance names in a hand-edited config are rejected (path
    /// traversal risk): a name outside the naming policy could be used to build
    /// a path outside the instances root.
    public func load() throws -> Config {
        guard let config = try JSONFile.read(Config.self, from: paths.configFile) else {
            return Config()
        }
        for (key, instance) in config.instances {
            guard NameValidator.isValid(key), key == instance.name else {
                throw OrchestratorError.corruptConfig(paths.configFile)
            }
        }
        return config
    }

    /// Writes the config file.
    public func save(_ config: Config) throws {
        try JSONFile.write(config, to: paths.configFile)
    }

    /// Returns the instance with the given name; throws `notFound` if there is none.
    public func instance(named name: String) throws -> Instance {
        let config = try load()
        guard let instance = config.instances[name] else {
            throw OrchestratorError.notFound("instance '\(name)' not found")
        }
        return instance
    }

    /// Adds or updates an instance. Invalid names are rejected.
    public func upsert(_ instance: Instance) throws {
        try NameValidator.validate(instance.name)
        var config = try load()
        config.instances[instance.name] = instance
        try save(config)
    }

    /// Removes an instance; throws `notFound` if there is none.
    public func remove(named name: String) throws {
        var config = try load()
        guard config.instances.removeValue(forKey: name) != nil else {
            throw OrchestratorError.notFound("instance '\(name)' not found")
        }
        try save(config)
    }
}
