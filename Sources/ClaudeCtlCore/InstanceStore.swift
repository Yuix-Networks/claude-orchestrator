import Foundation

/// `config.json` üzerinde instance CRUD işlemleri.
public final class InstanceStore {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    /// Config dosyasını okur. Dosya yoksa boş config döner.
    public func load() throws -> Config {
        try JSONFile.read(Config.self, from: paths.configFile) ?? Config()
    }

    /// Config dosyasını yazar.
    public func save(_ config: Config) throws {
        try JSONFile.write(config, to: paths.configFile)
    }

    /// Adıyla instance'ı getirir; yoksa `notFound` hatası.
    public func instance(named name: String) throws -> Instance {
        let config = try load()
        guard let instance = config.instances[name] else {
            throw ClaudeCtlError.notFound("instance '\(name)' bulunamadı")
        }
        return instance
    }

    /// Instance'ı ekler veya günceller. Geçersiz ad reddedilir.
    public func upsert(_ instance: Instance) throws {
        try NameValidator.validate(instance.name)
        var config = try load()
        config.instances[instance.name] = instance
        try save(config)
    }

    /// Instance'ı siler; yoksa `notFound` hatası.
    public func remove(named name: String) throws {
        var config = try load()
        guard config.instances.removeValue(forKey: name) != nil else {
            throw ClaudeCtlError.notFound("instance '\(name)' bulunamadı")
        }
        try save(config)
    }
}
