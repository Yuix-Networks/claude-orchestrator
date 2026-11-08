# claude-ctl v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `/Applications/Claude.app`'i aynı anda birbirinden bağımsız N instance olarak çalıştıran, her instance'a ayrı profil / ayrı `~/.claude` / ayrı hesap / ayrı workdir / ayrı Dock tile'ı sağlayan macOS CLI aracı.

**Architecture:** Tek Swift binary, iki mod (`claude-ctl` CLI, `claude-ctl agent` menü çubuğu). Çekirdek mantık `ClaudeCtlCore` kütüphanesinde (AppKit'siz, test edilebilir); agent mantığı `ClaudeCtlAgent` kütüphanesinde. Instance ayrıştırması `open -n -a /Applications/Claude.app --args --user-data-dir=<profile> --env CLAUDE_CONFIG_DIR=<codeDir>` ile yapılır — orijinal bundle'e hiç dokunulmaz.

**Tech Stack:** Swift 6.0 toolchain, SwiftPM, XCTest, Foundation + AppKit, macOS 13+ (Ventura). Üçüncü parti bağımlılık yok.

**Spec:** `docs/superpowers/specs/2026-11-08-claude-ctl-design.md`

## Global Constraints

- Minimum macOS 13 (Ventura): `open --env` ancak Ventura ve sonrasında var.
- Swift tools version 6.0, **language mode v5** (`swiftLanguageMode(.v5)`) — strict concurrency hataları plana dahil değil.
- **MUTLAK KURAL:** `/Applications/Claude.app` bundle'ine (veya içindeki hiçbir dosyaya) asla yazma, silme, kopyalama, yamala veya yeniden imzalama.
- Instance veri kökü: `~/Library/Application Support/claude-ctl/`.
- Launch komutu tam olarak bu biçimde kurulur (argüman sırası önemli):
  `open -n -a /Applications/Claude.app --args --user-data-dir=<profile> --env CLAUDE_CONFIG_DIR=<codeDir>`
  (ek `--folder <yol>` yalnızca `start --folder` ile verilirse `--args` içine eklenir).
- Exit code: `0` başarılı, `1` çalışma (runtime) hatası, `2` kullanım (usage) hatası.
- Instance adı regex'i: `^[a-z0-9][a-z0-9-]{0,31}$` (`..`, `/`, boş, 32+ karakter reddedilir).
- Claude sürümü `/Applications/Claude.app/Contents/Info.plist` → `CFBundleShortVersionString` okunarak tespit edilir.
- Claude logları paylaşıktır: `~/Library/Logs/Claude/main.log`, satır formatı `YYYY-MM-DD HH:MM:SS [level] [component] message` (yerel saat, ilk 19 karakter zaman damgası).
- Lisans: MIT. Testler `swift test` ile koşar; CI'da Claude kurulu değilse Claude'a bağlı entegrasyon testleri skip edilir.

## Review Focus

Spec'in ima ettiği ama hiçbir görevin testiyle doğrulanmayan, kullanıcıyı en çok yakacak giriş/koşul sınıfları:

1. **Instance adı path traversal / format** — `new ../x`, `new a/b`, `new ""`, `new <33 karakter>` reddedilmeli; mevcut `config.json` bozulmamalı.
2. **Bozuk `config.json`** — geçersiz JSON veya beklenmeyen şema: `list`/`start` boş liste döndürmemeli, dosyayı silmemeli/üzerine yazmamalı, açıklayıcı hata vermeli.
3. **Workdir silinmiş veya erişilemez** — `start` çökmemeli; uyarı vermeli, tohumlamayı atlamalı, instance yine açılmalı.
4. **Profil kilidi (SingletonLock)** — aynı profil zaten açıkken `start` çökmemeli; "bu profil başka bir instance tarafından kullanılıyor" hatası vermeli.
5. **Boşluk / Unicode içeren workdir yolu** — tohumlama JSON'u bozulmadan doğru yola yazmalı.
6. **Claude güncellemesi (sürüm değişimi)** — `start` çökmemeli; `doctor` sürüm farkını bildirmeli.

---

## Dosya yapısı

```
Package.swift
Sources/
  ClaudeCtlCore/          # AppKit'siz çekirdek kütüphane (tüm mantık + testler)
    Paths.swift           # dizin layout'u (root inject edilebilir)
    Errors.swift          # ClaudeCtlError
    Instance.swift        # Instance, Config modelleri
    NameValidator.swift   # instance adı doğrulama
    InstanceStore.swift   # config.json CRUD
    JSONFile.swift        # atomik JSON oku/yaz (Codable)
    ProfileSeeder.swift   # workdir tohumlama (JSON merge)
    ProcessListing.swift  # /bin/ps tabanlı süreç listesi (inject edilebilir)
    Launcher.swift        # open komutu üretimi, SingletonLock, PID bulma
    LogReader.swift       # paylaşılan log'dan zaman aralığına göre filtreleme
    Doctor.swift          # sağlık kontrolleri
    ClaudeCtl.swift       # facade: new/start/stop/list/status/logs/open/signin/doctor
  Sources/ClaudeCtlAgent/ # menü çubuğu agent'ı (AppKit)
    AgentModel.swift      # UI'sız: durum + menü öğeleri üretimi
    StatusItemController.swift # NSStatusItem yönetimi
    LaunchAgentInstaller.swift # login item plist
  Sources/claude-ctl/     # executable (tek binary)
    main.swift            # mod seçimi + komut tablosu
    Output.swift          # tablo/JSON çıktı, exit code
    Commands/
      NewCommand.swift  StartCommand.swift  StopCommand.swift  ListCommand.swift
      StatusCommand.swift  LogsCommand.swift  OpenCommand.swift  SigninCommand.swift
      DoctorCommand.swift  AgentCommand.swift
Tests/ClaudeCtlCoreTests/
  NameValidatorTests.swift  InstanceStoreTests.swift  ProfileSeederTests.swift
  LauncherTests.swift  LogReaderTests.swift  DoctorTests.swift
Tests/ClaudeCtlAgentTests/
  AgentModelTests.swift
Scripts/smoke.sh          # canlı E2E doğrulama betiği
```

---

### Task 1: Proje iskeleti, Paths, Instance modeli, ad doğrulama

**Files:**
- Create: `Package.swift`
- Create: `Sources/ClaudeCtlCore/Paths.swift`
- Create: `Sources/ClaudeCtlCore/Errors.swift`
- Create: `Sources/ClaudeCtlCore/Instance.swift`
- Create: `Sources/ClaudeCtlCore/NameValidator.swift`
- Create: `Tests/ClaudeCtlCoreTests/NameValidatorTests.swift`

**Interfaces:**
- Consumes: —
- Produces:
  - `public struct Paths { public init(root: URL); public static var `default`: Paths; public var configFile: URL; public var instancesRoot: URL; public func instanceDir(_ name: String) -> URL; public func profileDir(_ name: String) -> URL; public func codeDir(_ name: String) -> URL; public func stateFile(_ name: String) -> URL }`
    — `root` = `~/Library/Application Support/claude-ctl` (testler geçici dizin verir).
  - `public enum ClaudeCtlError: Error { case usage(String); case runtime(String); case notFound(String); case invalidName(String); case corruptConfig(URL) }`
  - `public struct Instance: Codable, Equatable { public var name: String; public var workdir: String?; public var createdAt: Date; public var autoStart: Bool; public var iconBadge: String? }`
  - `public struct Config: Codable, Equatable { public var version: Int; public var instances: [String: Instance] }`
  - `public enum NameValidator { public static func validate(_ name: String) throws }` — geçerli ise `()`, değilse `.invalidName` fırlatır.

- [ ] **Step 1: `Package.swift` yaz**

  `swift-tools-version:6.0`, `platforms: [.macOS(.v13)]`, `swiftLanguageMode(.v5)`.
  Targets: `.target(name: "ClaudeCtlCore")`, `.target(name: "ClaudeCtlAgent", dependencies: ["ClaudeCtlCore"])`, `.executableTarget(name: "claude-ctl", dependencies: ["ClaudeCtlCore", "ClaudeCtlAgent"])`,
  `.testTarget(name: "ClaudeCtlCoreTests", dependencies: ["ClaudeCtlCore"])`,
  `.testTarget(name: "ClaudeCtlAgentTests", dependencies: ["ClaudeCtlAgent", "ClaudeCtlCore"])`.

- [ ] **Step 2: `Paths.swift` ve `Errors.swift` yaz**

  `Paths.default.root` = `URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/claude-ctl")`.
  Alt yollar: `config.json`, `instances/`, `instances/<name>/`, `.../profile`, `.../claude-code`, `.../state.json`.

- [ ] **Step 3: `Instance.swift` ve `NameValidator.swift` yaz**

  `Config.version` varsayılan `1`. `NameValidator.validate` regex'i `^[a-z0-9][a-z0-9-]{0,31}$`; eşleşmezse `ClaudeCtlError.invalidName("instance adı '<name>' geçersiz: sadece küçük harf, rakam ve tire, 1-32 karakter")`.

- [ ] **Step 4: `NameValidatorTests.swift` yaz (başarısız test)**

  Testler: `"work"` geçerli; `""`, `"Work"`, `"a/b"`, `"../x"`, `"a b"`, `String(repeating: "a", count: 33)` geçersiz.
  Hata mesajında instance adı geçmeli.

- [ ] **Step 5: Testleri koş ve başarısız olduğunu gör**

  Run: `swift test --filter NameValidatorTests`
  Expected: FAIL — "no such module 'ClaudeCtlCore'" veya "cannot find 'NameValidator' in scope".

- [ ] **Step 6: Step 3-4'teki kodu yazarak testleri geçir**

- [ ] **Step 7: Tüm testleri koş**

  Run: `swift test`
  Expected: PASS (0 hata).

- [ ] **Step 8: Commit**

  ```bash
  git add Package.swift Sources/ClaudeCtlCore Tests/ClaudeCtlCoreTests
  git commit -m "feat(core): proje iskeleti, Paths, Instance modeli, ad doğrulama"
  ```

---

### Task 2: InstanceStore — config.json CRUD

**Files:**
- Create: `Sources/ClaudeCtlCore/InstanceStore.swift`
- Create: `Sources/ClaudeCtlCore/JSONFile.swift`
- Create: `Tests/ClaudeCtlCoreTests/InstanceStoreTests.swift`

**Interfaces:**
- Consumes: `Paths` (Task 1), `Instance`, `Config`, `ClaudeCtlError` (Task 1).
- Produces:
  - `public final class InstanceStore { public init(paths: Paths); public func load() throws -> Config; public func save(_ config: Config) throws; public func instance(named: String) throws -> Instance; public func upsert(_ instance: Instance) throws; public func remove(named: String) throws }`
  - `public enum JSONFile { public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T?; public static func write<T: Encodable>(_ value: T, to url: URL) throws }`
    — `write` atomik: önce `url + ".tmp"` yaz, sonra `FileManager.replaceItemAt`.

- [ ] **Step 1: `InstanceStoreTests.swift` yaz (başarısız test)**

  `setUp` → `paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("claude-ctl-test-\(UUID().uuidString)"))`.
  Testler:
  1. `load()` dosya yokken `Config(version: 1, instances: [:])` döndürür, hata atmaz.
  2. `upsert` sonrası `load()` instance'ı aynı değerlerle döndürür.
  3. `instance(named: "yok")` → `.notFound` hatası.
  4. `remove(named:)` sonrası `load().instances` boş.
  5. **Review Focus #2**: `config.json` içine `"{{{{ bozuk"` yaz → `load()` throws, hata `.corruptConfig(url)`; dosyanın içeriği değişmemiş olmalı (`assertEqual(readFile, "{{{{ bozuk")`).
  6. **Review Focus #1**: `upsert` `name: "../x"` olan bir Instance ile çağrılırsa `.invalidName` fırlatır ve `config.json` yazılmaz.

- [ ] **Step 2: Testleri koş, başarısız olduğunu gör**

  Run: `swift test --filter InstanceStoreTests`
  Expected: FAIL — "cannot find 'InstanceStore' in scope".

- [ ] **Step 3: `JSONFile.swift` yaz**

  `read`: dosya yoksa `nil`; `JSONDecoder` hatası → `ClaudeCtlError.corruptConfig(url)`; okuma hatası → `.runtime`.
  `write`: `JSONEncoder` (`outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`), `.atomic` Data yazımı.

- [ ] **Step 4: `InstanceStore.swift` yaz**

  `load()`: `JSONFile.read(Config.self, from: paths.configFile)` → nil ise boş config; hata propagate.
  `save(_:)`: `paths.configFile` üst dizinini oluştur, `JSONFile.write`.
  `instance(named:)`: `load()` → `config.instances[name]` → yoksa `.notFound("instance '<name>' bulunamadı")`.
  `upsert(_:)`: `NameValidator.validate(instance.name)` → sonra `config.instances[name] = instance`, `save`.
  `remove(named:)`: `config.instances.removeValue(forKey:)` → `save`.

- [ ] **Step 5: Testleri koş, hepsinin geçtiğini gör**

  Run: `swift test --filter InstanceStoreTests`
  Expected: PASS (6 test).

- [ ] **Step 6: Commit**

  ```bash
  git add Sources/ClaudeCtlCore/InstanceStore.swift Sources/ClaudeCtlCore/JSONFile.swift Tests/ClaudeCtlCoreTests/InstanceStoreTests.swift
  git commit -m "feat(core): InstanceStore ile config.json CRUD ve bozuk config koruması"
  ```

---

### Task 3: ProfileSeeder — workdir tohumlama

**Files:**
- Create: `Sources/ClaudeCtlCore/ProfileSeeder.swift`
- Create: `Tests/ClaudeCtlCoreTests/ProfileSeederTests.swift`

**Interfaces:**
- Consumes: `Paths` (Task 1), `Instance` (Task 1), `JSONFile` (Task 2).
- Produces:
  - `public struct SeedResult: Equatable { public var trustedFolderAdded: Bool; public var presetAdded: Bool; public var accountUUID: String? }`
  - `public struct ProfileSeeder { public init(paths: Paths); public func seed(profileDir: URL, workdir: String) throws -> SeedResult }`

- [ ] **Step 1: `ProfileSeederTests.swift` yaz (başarısıl test)**

  `setUp` geçici `profile` dizini; `claude_desktop_config.json` ve `ccd-session-presets.json` testte oluşturulur.
  Testler:
  1. **Mevcut config korunur**: `claude_desktop_config.json` içinde `"mcpServers": {"x": {"command": "y"}}` ve `preferences` altında `"menuBarEnabled": false` varken seed edildiğinde ikisi de dosyada duruyor.
  2. **Güvenli klasör eklenir**: `preferences.localAgentModeTrustedFolders` içine workdir giriyor.
  3. **Idempotent**: aynı workdir iki kez seed edilince dosya içeriği iki kez seed edilenle **byte-byte aynı** (JSON çıktısı sortedKeys olduğu için kararlı).
  4. **Preset eklenir**: `ccd-session-presets.json` = `{"byAccount":{"acct-1":{"presets":[]}}}` iken seed sonrası `byAccount["acct-1"].presets` içinde `target.cwd == workdir` olan bir preset var, `name == workdir` son segmenti.
  5. **Hesap yoksa preset yazılmaz**: `ccd-session-presets.json` `{"byAccount":{}}` ve `bridge-state.json` yok → `seedResult.accountUUID == nil`, `presetAdded == false`.
  6. **Hesap `bridge-state.json`'dan bulunur**: `bridge-state.json` = `{"ws-1:acct-9": {}}` → `accountUUID == "acct-9"`.
  7. **Review Focus #5**: workdir = `"/tmp/boş luk ve ğ"` → seed başarılı, `trustedFolders` içinde tam bu yol var, dosya geçerli JSON.
  8. **Workdir yoksa hata**: `seed(profileDir:workdir: "/tmp/yok-boyle-bir-klasor-\(UUID())")` → `.runtime` hatası (klasör yoksa tohumlama yapılmaz).

- [ ] **Step 2: Testleri koş, başarısız olduğunu gör**

  Run: `swift test --filter ProfileSeederTests`
  Expected: FAIL — "cannot find 'ProfileSeeder' in scope".

- [ ] **Step 3: `ProfileSeeder.swift` yaz**

  - `seed(profileDir:workdir:)`:
    1. `guard FileManager.default.fileExists(atPath: workdir)` else `throw .runtime("workdir bulunamadı: \(workdir)")`.
    2. `trustedFolders` merge → `profileDir/claude_desktop_config.json`:
       - dosya yoksa `["mcpServers": [:], "preferences": [:]]` ile başla;
       - `preferences` yoksa `[:]`; `localAgentModeTrustedFolders` yoksa `[]`;
       - workdir listede yoksa ekle, `trustedFolderAdded = true`.
    3. Hesap UUID'sini bul: önce `ccd-session-presets.json`'daki `byAccount` anahtarları (ilk anahtar), yoksa `bridge-state.json` anahtarlarının `:` sonrası.
    4. Hesap varsa preset merge → `profileDir/ccd-session-presets.json`:
       - `byAccount[uuid].presets` içinde `target.cwd == workdir` olan preset yoksa ekle:
         `{"id": UUID().uuidString, "name": URL(fileURLWithPath: workdir).lastPathComponent, "createdAt": Int64(Date().timeIntervalSince1970 * 1000), "lastUsedAt": <aynı>, "target": {"kind": "local", "cwd": workdir}}`; `presetAdded = true`.
    5. İki dosyayı da `JSONFile.write` ile yaz (`.prettyPrinted, .sortedKeys`).

- [ ] **Step 4: Testleri koş, hepsinin geçtiğini gör**

  Run: `swift test --filter ProfileSeederTests`
  Expected: PASS (8 test).

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/ClaudeCtlCore/ProfileSeeder.swift Tests/ClaudeCtlCoreTests/ProfileSeederTests.swift
  git commit -m "feat(core): workdir tohumlama (güvenli klasörler + session preset)"
  ```

---

### Task 4: Launcher — open komutu, PID bulma, profil kilidi

**Files:**
- Create: `Sources/ClaudeCtlCore/ProcessListing.swift`
- Create: `Sources/ClaudeCtlCore/Launcher.swift`
- Create: `Tests/ClaudeCtlCoreTests/LauncherTests.swift`

**Interfaces:**
- Consumes: `Paths` (Task 1), `ClaudeCtlError` (Task 1).
- Produces:
  - `public struct LaunchRequest: Equatable { public var appPath: String; public var profileDir: String; public var codeDir: String; public var extraArgs: [String] }`
  - `public protocol ProcessListing { func processes() -> [(pid: Int32, command: String)] }`
  - `public struct PsProcessListing: ProcessListing` — `/bin/ps -axo pid=,command=` çalıştırır, parse eder.
  - `public final class Launcher { public init(appPath: String = "/Applications/Claude.app", processListing: ProcessListing = PsProcessListing(), fileManager: FileManager = .default); public func launchArguments(_ request: LaunchRequest) -> [String]; public func isProfileLocked(profileDir: URL) -> Bool; public func runningPid(profileDir: URL) -> Int32?; public func launch(_ request: LaunchRequest) throws }`

- [ ] **Step 1: `LauncherTests.swift` yaz (başarısız test)**

  Testler:
  1. `launchArguments` tam olarak şunu döndürür:
     `["open", "-n", "-a", "/Applications/Claude.app", "--args", "--user-data-dir=/p", "--env", "CLAUDE_CONFIG_DIR=/c"]`
     (`extraArgs` boşken).
  2. `extraArgs = ["/tmp/proje"]` iken `--args` bölümü `--user-data-dir=/p`, `--env`, `CLAUDE_CONFIG_DIR=/c`, `/tmp/proje` sırasıyla gelir.
  3. `isProfileLocked`: profil dizininde `SingletonLock` dosyası varsa `true`, yoksa `false`.
  4. `runningPid`: sahte process listesi `[(123, "/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/p ...")]` → `123` döner; eşleşme yoksa `nil`.
  5. `runningPid` yalnızca **tam yol** eşleşmesinde döner: `--user-data-dir=/p2` arayan, `/p` için `nil` döndürür.

- [ ] **Step 2: Testleri koş, başarısız olduğunu gör**

  Run: `swift test --filter LauncherTests`
  Expected: FAIL — "cannot find 'Launcher' in scope".

- [ ] **Step 3: `ProcessListing.swift` yaz**

  `PsProcessListing.processes()`: `Process` ile `/bin/ps` çalıştır (`-axo pid=,command=`), stdout satırlarını `pid` + `command` olarak ayır (ilk boşluktan ayır), pid'ı `Int32`.

- [ ] **Step 4: `Launcher.swift` yaz**

  - `launchArguments`: yukarıdaki sabit sıra; `--user-data-dir=<profileDir>` ve `CLAUDE_CONFIG_DIR=<codeDir>` mutlaka `--args`/`--env` sonrasında, **tek argüman** olarak (boşluk içeren yollarda bölünmez).
  - `isProfileLocked(profileDir:)`: `profileDir.appendingPathComponent("SingletonLock")` var mı → `true`.
  - `runningPid(profileDir:)`: `processes()` içinde `command` içinde `--user-data-dir=\(profileDir.path)` **ve** `"/Applications/Claude.app/Contents/MacOS/Claude"` geçen kaydın pid'ı; birden fazla eşleşme varsa en küçük pid.
  - `launch(_:)`: `Process` ile `launchArguments` çalıştır (`/usr/bin/open`), hata çıkarsa `.runtime`.

- [ ] **Step 5: Testleri koş, hepsinin geçtiğini gör**

  Run: `swift test --filter LauncherTests`
  Expected: PASS (5 test).

- [ ] **Step 6: Commit**

  ```bash
  git add Sources/ClaudeCtlCore/ProcessListing.swift Sources/ClaudeCtlCore/Launcher.swift Tests/ClaudeCtlCoreTests/LauncherTests.swift
  git commit -m "feat(core): Launcher ile open komutu, PID bulma ve profil kilidi kontrolü"
  ```

---

### Task 5: CLI çekirdeği — new / start / stop

**Files:**
- Create: `Sources/ClaudeCtlCore/ClaudeCtl.swift` (facade; bu görevde `new`, `start`, `stop`)
- Create: `Sources/ClaudeCtlCore/InstanceState.swift`
- Create: `Sources/claude-ctl/Output.swift`
- Create: `Sources/claude-ctl/Commands/NewCommand.swift`
- Create: `Sources/claude-ctl/Commands/StartCommand.swift`
- Create: `Sources/claude-ctl/Commands/StopCommand.swift`
- Create: `Sources/claude-ctl/main.swift`
- Create: `Tests/ClaudeCtlCoreTests/ClaudeCtlStartTests.swift`

**Interfaces:**
- Consumes: `Paths`, `ClaudeCtlError`, `Instance`, `Config` (Task 1); `InstanceStore`, `JSONFile` (Task 2); `ProfileSeeder`, `SeedResult` (Task 3); `Launcher`, `LaunchRequest` (Task 4).
- Produces:
  - `public struct InstanceState: Codable, Equatable { public var pid: Int32; public var startedAt: Date; public var claudeVersion: String? }`
  - `public final class ClaudeCtl { public init(paths: Paths = .default, appPath: String = "/Applications/Claude.app", processListing: ProcessListing = PsProcessListing()); public func new(name: String, workdir: String?) throws -> Instance; public func start(name: String, folder: String?) throws -> StartResult; public func stop(name: String) throws -> StopResult }`
  - `public struct StartResult: Equatable { public var instance: Instance; public var pid: Int32; public var alreadyRunning: Bool; public var seed: SeedResult?; public var warning: String? }`
  - `public struct StopResult: Equatable { public var wasRunning: Bool; public var forced: Bool }`
  - `public enum ExitCode { public static let success: Int32 = 0; public static let runtime: Int32 = 1; public static let usage: Int32 = 2 }`
  - `public enum Output { public static func error(_ message: String, code: Int32) -> Never; public static func line(_ text: String); public static func json(_ value: [String: Any]) }` — `error` mesajı stderr'e yazıp `exit(code)` çağırır.

- [ ] **Step 1: `ClaudeCtlStartTests.swift` yaz (başarısız test)**

  Testler (hepsi geçici `paths.root` ile):
  1. `new(name: "work", workdir: "/tmp")` → instance config'e yazıldı, `profile` ve `claude-code` dizinleri oluşturuldu.
  2. `new` aynı adla ikinci kez → `.runtime` hatası ("zaten var").
  3. `start` çalışan bir instance için `alreadyRunning == true` ve yeni süreç başlatılmaz (sahte ProcessListing, `runningPid` non-nil döner).
  4. **Review Focus #4**: profil dizininde `SingletonLock` dosyası varken `start` → `.runtime` hatası ve mesajda "SingletonLock" geçiyor.
  5. **Review Focus #3**: `workdir` = `/tmp/yok-\(UUID())` iken `start` → hata **atmaz**; `warning` non-nil ve içinde "workdir" geçiyor; `seed == nil`.
  6. `stop` çalışan bir pid'i SIGTERM ile durdurur (ölü süreçte `wasRunning == false`).

- [ ] **Step 2: Testleri koş, başarısız olduğunu gör**

  Run: `swift test --filter ClaudeCtlStartTests`
  Expected: FAIL — "cannot find 'ClaudeCtl' in scope".

- [ ] **Step 3: `InstanceState.swift` ve `ClaudeCtl.swift` (new/start/stop) yaz**

  - `new(name:workdir:)`: `NameValidator.validate` → config'de ad varsa `.runtime("instance '<name>' zaten var")` → `Instance(name:workdir:createdAt: Date(), autoStart: false, iconBadge: nil)` → `store.upsert` → `profile` ve `claude-code` dizinlerini oluştur (`withIntermediateDirectories: true`).
  - `start(name:folder:)`:
    1. `store.instance(named:)` (yoksa `.notFound`).
    2. `launcher.runningPid(profileDir:)` non-nil → `StartResult(alreadyRunning: true, pid: pid)`.
    3. `launcher.isProfileLocked(profileDir:)` → `.runtime("profil kilitli: <path> başka bir Claude instance'ı kullanıyor")`.
    4. Workdir kontrolü: `instance.workdir` verilmişse ve diskte yoksa `warning = "workdir bulunamadı: <path> — tohumlama atlandı"`, `seed = nil`; varsa `seeder.seed(...)`.
    5. `launcher.launch(LaunchRequest(appPath:appPath, profileDir:profile.path, codeDir:codeDir.path, extraArgs: folder.map { [$0] } ?? []))`.
    6. PID bekleme: 10 saniyeye kadar, 250 ms aralıkla `launcher.runningPid(profileDir:)` → bulunamazsa `.runtime("instance başlatılamadı: süreç bulunamadı")`.
    7. `state.json` yaz: `InstanceState(pid:startedAt: Date(), claudeVersion: currentClaudeVersion())`.
  - `stop(name:)`: `state.json` oku (yoksa `wasRunning == false`); pid çalışıyorsa `SIGTERM` gönder (`kill(pid, SIGTERM)`), 5 sn bekle, hâlâ yaşıyorsa `SIGKILL` (`forced = true`); `state.json` sil.
  - `currentClaudeVersion()`: `/Applications/Claude.app/Contents/Info.plist` → `PropertyListSerialization` → `CFBundleShortVersionString`; okunamazsa `nil`.

- [ ] **Step 4: `Output.swift` ve komut dosyalarını yaz**

  `main.swift`: `argv[1]` "agent" ise agent moduna git (Task 7'de eklenir; o ana kadar "agent modu henüz yok" hatası + exit 2), aksi halde komut tablosu: `new`, `start`, `stop` (Task 6'da `list`, `status`, `logs`, `open`, `signin`, `doctor`, `agent` eklenir).
  `NewCommand`: `--workdir <yol>` zorunlu; `--workdir` yoksa `Output.error("new: --workdir zorunlu", .usage)`.
  `StartCommand`: `--folder <yol>` opsiyonel.
  `StopCommand`: isim zorunlu.
  Tüm komutlar: `ClaudeCtlError.usage` → exit 2, diğer hatalar → exit 1, hata mesajı stderr'e `hata: <mesaj>` olarak.

- [ ] **Step 5: Testleri koş, hepsinin geçtiğini gör**

  Run: `swift test --filter ClaudeCtlStartTests`
  Expected: PASS (6 test).

- [ ] **Step 6: Binary'yi elle dene**

  Run:
  ```bash
  swift build -c release
  XDG_TMP=$(mktemp -d)
  ./build/release/claude-ctl new demo --workdir "$XDG_TMP"
  ./build/release/claude-ctl start demo
  ```
  Expected: `demo` instance'ı başlar, `~/Library/Application Support/claude-ctl/instances/demo/profile` altında `Cookies` dosyası oluşur. (Elle doğrulama; Claude kurulu değilse bu adım atlanır.)

- [ ] **Step 7: Commit**

  ```bash
  git add Sources/ClaudeCtlCore/ClaudeCtl.swift Sources/ClaudeCtlCore/InstanceState.swift Sources/claude-ctl
  git commit -m "feat(cli): new/start/stop komutları ve ClaudeCtl facade"
  ```

---

### Task 6: CLI çekirdeği — list / status / logs / open / signin / doctor

**Files:**
- Create: `Sources/ClaudeCtlCore/LogReader.swift`
- Create: `Sources/ClaudeCtlCore/Doctor.swift`
- Create: `Sources/claude-ctl/Commands/ListCommand.swift`
- Create: `Sources/claude-ctl/Commands/StatusCommand.swift`
- Create: `Sources/claude-ctl/Commands/LogsCommand.swift`
- Create: `Sources/claude-ctl/Commands/OpenCommand.swift`
- Create: `Sources/claude-ctl/Commands/SigninCommand.swift`
- Create: `Sources/claude-ctl/Commands/DoctorCommand.swift`
- Modify: `Sources/claude-ctl/main.swift` (komut tablosunu genişlet)
- Create: `Tests/ClaudeCtlCoreTests/LogReaderTests.swift`
- Create: `Tests/ClaudeCtlCoreTests/DoctorTests.swift`

**Interfaces:**
- Consumes: Task 1-5 çıktıları (`ClaudeCtl`, `InstanceStore`, `Launcher`, `InstanceState`, `Output`, `ExitCode`).
- Produces:
  - `public struct LogReader { public init(logDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Claude")); public func lines(since: Date, pid: Int32? = nil, limit: Int = 50) -> [String] }`
  - `public struct InstanceStatus: Equatable { public var name: String; public var workdir: String?; public var isRunning: Bool; public var pid: Int32?; public var startedAt: Date?; public var profileSizeBytes: Int64; public var accountSignedIn: Bool }`
  - `public enum CheckStatus: String, Equatable { case ok, warn, fail }`
  - `public struct DoctorCheck: Equatable { public var name: String; public var status: CheckStatus; public var detail: String }`
  - `ClaudeCtl` genişletmeleri: `public func list() throws -> [InstanceStatus]`, `public func status(name: String) throws -> InstanceStatus`, `public func logs(name: String, lines: Int) throws -> [String]`, `public func open(name: String, target: OpenTarget) throws`, `public func signin(name: String) throws -> SigninPlan`, `public func doctor(name: String?) throws -> [DoctorCheck]`
  - `public enum OpenTarget { case workdir; case profile }`
  - `public struct SigninPlan: Equatable { public var instance: String; public var handlerInstance: String?; public var otherInstancesRunning: [String]; public var instructions: [String] }`

- [ ] **Step 1: `LogReaderTests.swift` ve `DoctorTests.swift` yaz (başarısıl test)**

  `LogReaderTests`:
  1. Log dosyası yoksa `lines(since:limit:)` boş dizi döner (hata atmaz).
  2. Satırlar `YYYY-MM-DD HH:MM:SS` ile başlıyorsa ve `since` tarihinden eskiyse elenir.
  3. `pid` verildiğinde, satır `electron_main:<pid>` içermiyorsa elenir.
  4. `limit` verildiğinde **son** `limit` satır döner.

  `DoctorTests`:
  5. **Review Focus #6**: `state.json`'daki `claudeVersion` ile güncel sürüm farklıysa `doctor` "sürüm değişti" uyarısı üretir (`status == .warn`).
  6. Profil dizini yoksa `.fail`; `SingletonLock` varsa `.warn` ("başka instance kullanıyor").
  7. Disk: profil boyutu 5 GB üzerindeyse `warn`.

- [ ] **Step 2: Testleri koş, başarısız olduğunu gör**

  Run: `swift test --filter "LogReaderTests|DoctorTests"`
  Expected: FAIL — "cannot find 'LogReader' in scope".

- [ ] **Step 3: `LogReader.swift` yaz**

  `main.log` dosyasını satır satır oku; her satırın ilk 19 karakteri `yyyy-MM-dd HH:mm:ss` formatında → `DateFormatter` ("yyyy-MM-dd HH:mm:ss", `Locale(identifier: "en_US_POSIX")`, mevcut timezone) ile parse; parse edilemeyen satır `since` filtresinden **geçirilmez** (silinmez) ama pid filtresi uygulanır. `since` sonrası + pid eşleşen satırları topla, son `limit` tanesini döndür.

- [ ] **Step 4: `Doctor.swift` yaz**

  Kontroller (her biri `DoctorCheck`):
  - `claude-app`: `/Applications/Claude.app` var mı → yoksa `fail`.
  - `claude-version`: `state.json`'daki `claudeVersion` ile güncel `CFBundleShortVersionString` karşılaştır → farklıysa `warn` ("sürüm değişti: <eski> → <yeni>"), aynıysa `ok`.
  - `profile-dir`: profil dizini var mı → yoksa `fail`.
  - `profile-lock`: `SingletonLock` var mı → `warn`.
  - `disk`: profil boyutu → 5 GB üstü `warn`, altı `ok`.
  - `workdir`: instance.workdir diskte var mı → yoksa `warn`.
  - `signin`: profil `Cookies` dosyası var mı → `ok` / `warn`.

- [ ] **Step 5: `ClaudeCtl` facade'i genişlet**

  - `list()`: her instance için `runningPid` → `isRunning`/`pid`; `state.json` → `startedAt`; profil boyutu (`FileManager` recursive size, `Int64`); `accountSignedIn` = profilde `Cookies` dosyası var mı. **Bayat state temizliği**: pid ölüyse `state.json` silinir ve `startedAt`/`pid` `nil` raporlanır.
  - `status(name:)`: `list()` içinden ilgili instance.
  - `logs(name:lines:)`: `state.json`'daki `startedAt` + pid ile `LogReader.lines(...)`.
  - `open(name:target:)`: `workdir` → `NSWorkspace`-e açmak yerine `Process` ile `/usr/bin/open <yol>`; `profile` → profil dizini.
  - `signin(name:)`: hedef instance'ın profilindeki `Cookies`/`Local Storage` kontrolü; `handlerInstance`: `claude://` handler'ın hangi instance'a gittiği ölçülemiyorsa `nil`; `otherInstancesRunning`: `list()`'ten çalışan diğer instance adları; `instructions`: sabit metinler ("1) Diğer instance'ları kapat 2) 'claude://' handler hedefte olmalı 3) Tarayıcıda giriş yap").
  - `doctor(name:)`: `name` verilmişse o instance, verilmemişse tüm instance'lar (her instance için kontroller + app kontrolleri).

- [ ] **Step 6: Komut dosyalarını ve `main.swift`'i yaz**

  `list` → tablo (ad, durum, pid, workdir, boyut); `--json` → `[{name, isRunning, pid, workdir, startedAt, profileSizeBytes}]`.
  `status <ad>` → detay; `--json`.
  `logs <ad> [-n N] [-f]` → satırları yaz; `-f` varsa dosyayı tail et (yeni satır geldikçe yaz, Ctrl-C ile çık).
  `open <ad> [--target workdir|profile]`.
  `signin <ad>` → `instructions` satırlarını numaralı yaz.
  `doctor [<ad>]` → kontrolleri listeler; herhangi biri `fail` ise exit 1, hepsi `ok`/`warn` ise exit 0.

- [ ] **Step 7: Testleri koş, hepsinin geçtiğini gör**

  Run: `swift test`
  Expected: PASS (tüm testler).

- [ ] **Step 8: Commit**

  ```bash
  git add Sources/ClaudeCtlCore/LogReader.swift Sources/ClaudeCtlCore/Doctor.swift Sources/claude-ctl Tests/ClaudeCtlCoreTests
  git commit -m "feat(cli): list/status/logs/open/signin/doctor komutları"
  ```

---

### Task 7: Menü çubuğu agent'ı

**Files:**
- Create: `Sources/ClaudeCtlAgent/AgentModel.swift`
- Create: `Sources/ClaudeCtlAgent/StatusItemController.swift`
- Create: `Sources/ClaudeCtlAgent/LaunchAgentInstaller.swift`
- Create: `Sources/claude-ctl/Commands/AgentCommand.swift`
- Create: `Tests/ClaudeCtlAgentTests/AgentModelTests.swift`
- Modify: `Sources/claude-ctl/main.swift` ("agent" modu)

**Interfaces:**
- Consumes: `ClaudeCtl`, `InstanceStatus`, `InstanceStore`, `Launcher`, `Paths` (Task 1-6).
- Produces:
  - `public enum AgentAction: Equatable { case activate; case stop; case openWorkdir; case openProfile; case showLogs; case signinHelp }`
  - `public struct AgentMenuItem: Equatable { public var title: String; public var action: AgentAction; public var isEnabled: Bool }`
  - `public final class AgentModel { public init(ctl: ClaudeCtl); public func refresh() -> [InstanceStatus]; public func menuItems(for status: InstanceStatus) -> [AgentMenuItem] }`
  - `public final class StatusItemController { public init(model: AgentModel); public func start() }` — her instance için `NSStatusItem` (ikon: Claude ikonu + rozet metni).
  - `public struct LaunchAgentInstaller { public init(label: String = "com.claude-ctl.agent"); public func install(executablePath: String) throws -> URL; public func uninstall() throws }`
  - `AgentCommand`: `claude-ctl agent` → agent modunu **bu process içinde** çalıştırır (ayrı süreç değil — `main.swift` "agent" argümanıyla `StatusItemController` başlatır); `claude-ctl agent --install` → LaunchAgent plist yazar + `launchctl bootstrap`; `--uninstall` → plist siler + `launchctl bootout`.

- [ ] **Step 1: `AgentModelTests.swift` yaz (başarısıl test)**

  Testler:
  1. `refresh()` çalışan ve durmuş instance'ları doğru `isRunning` ile döndürür.
  2. `menuItems(for:)` çalışan instance için "Durdur" ve "Öne Getir" maddelerini içerir, durmuş instance için "Durdur" maddesini içermez (`isEnabled == false`).
  3. Menüde her zaman "Workdir'yi Aç", "Loglar", "Sign-in Yardımı" maddeleri var.

- [ ] **Step 2: Testleri koş, başarısız olduğunu gör**

  Run: `swift test --filter AgentModelTests`
  Expected: FAIL — "cannot find 'AgentModel' in scope".

- [ ] **Step 3: `AgentModel.swift` yaz**

  `refresh()` → `ctl.list()`. `menuItems(for:)` → sıra: "Öne Getir" (çalışıyorsa enabled), "Durdur" (çalışıyorsa enabled), "Workdir'yi Aç", "Profil Klasörünü Aç", "Loglar", "Sign-in Yardımı".

- [ ] **Step 4: `StatusItemController.swift` yaz**

  Singleton: `paths.state/agent.pid` dosyası; dosya varsa içindeki pid canlıysa bu agent ikinci bir örnektir → `start()` hemen çıkış yapar ("agent zaten çalışıyor"), pid ölüyse dosya silinip yenisi yazılır.
  `start()`: `AgentModel.refresh()` → her instance için `NSStatusItem`; `button.image` = Claude ikonu (`/Applications/Claude.app/Contents/Resources/electron.icns` okunup `NSImage` yapılır) + `button.title` = rozet (instance adının son 2 karakteri); `button.menu` = `NSMenu` (menuItems → `NSMenuItem`, `target/action` ile `AgentAction`'a bağlanır).
  aksiyonlar: `activate` → `NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])`; `stop` → `ctl.stop(name:)`; `openWorkdir`/`openProfile` → `ctl.open(...)`; `showLogs` → `ctl.logs(...)` çıktısını bir pencereye yaz (basit `NSTextView` içeren `NSWindow`) veya `open -a Terminal <log dosyası>`; `signinHelp` → `ctl.signin(name:)` çıktısını aynı pencereye yaz.
  5 sn'de bir `Timer` ile `refresh()` çağrılır ve menüler yenilenir (config değişikliği bu yoklamayla yakalanır).

- [ ] **Step 5: `LaunchAgentInstaller.swift` yaz**

  `install(executablePath:)`: `~/Library/LaunchAgents/com.claude-ctl.agent.plist` yaz:
  ```xml
  <key>ProgramArguments</key><array><string>/usr/local/bin/claude-ctl</string><string>agent</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  ```
  sonra `launchctl bootstrap gui/$UID <plist>` (hata vermezse uyarı metni yazılır, exit 1).
  `uninstall()`: `launchctl bootout gui/$UID/com.claude-ctl.agent` + plist sil.

- [ ] **Step 6: `AgentCommand.swift` ve `main.swift` yaz**

  `main.swift`: `argv[1] == "agent"` → `--install`/`--uninstall` yoksa `StatusItemController(model:).start()` + `NSApplication.shared.run()`; `--install`/`--uninstall` → `LaunchAgentInstaller` çağrısı ve çıkış.

- [ ] **Step 7: Testleri koş, hepsinin geçtiğini gör**

  Run: `swift test`
  Expected: PASS (tüm testler).

- [ ] **Step 8: Elle doğrulama**

  Run:
  ```bash
  swift build -c release
  ./build/release/claude-ctl agent &
  ```
  Expected: menü çubuğunda instance başına bir ikon görünür; ikonu tıklayınca menü açılır.

- [ ] **Step 9: Commit**

  ```bash
  git add Sources/ClaudeCtlAgent Sources/claude-ctl/Commands/AgentCommand.swift Sources/claude-ctl/main.swift Tests/ClaudeCtlAgentTests
  git commit -m "feat(agent): menü çubuğu ikonları ve LaunchAgent kurulumu"
  ```

---

### Task 8: Dağıtım — README, LICENSE, Homebrew tap, release iş akışı

**Files:**
- Create: `README.md`
- Create: `LICENSE` (MIT, 2026 Serdar)
- Create: `Formula/claude-ctl.rb`
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: Task 1-7 çıktıları (derlenen binary `claude-ctl`).
- Produces: dağıtım artefaktları — yeni arayüz (tip) üretmez.

- [ ] **Step 1: `README.md` yaz**

  Bölümler: Ne yapar (2-3 cümle, "Claude Desktop'u çoklu instance"), hızlı başlangış
  (`brew install --formula ./Formula/claude-ctl.rb` veya Releases'dan `curl` ile kurulum),
  komut tablosu (Task 6'daki komutlarla birebir aynı), **nasıl çalışır** (F1/F2 mekanizması:
  `--user-data-dir` + `CLAUDE_CONFIG_DIR`, orijinal bundle'e dokunulmaz), bilinen sınırlar
  (ayrı Dock ikonu yok, loglar paylaşılır, `claude://` handler tek instance), lisans.

- [ ] **Step 2: `LICENSE` yaz** — MIT, "Copyright (c) 2026 Serdar".

- [ ] **Step 3: `Formula/claude-ctl.rb` yaz**

  `class ClaudeCtl < Formula`; `desc "Claude Desktop çoklu instance yöneticisi"`; `homepage` GitHub repo URL'si; `license "MIT"`; `version "0.1.0"`;
  `url "https://github.com/<OWNER>/claude-ctl/releases/download/v0.1.0/claude-ctl-0.1.0.tar.gz"`; `sha256 "<SHA256>"`.
  `depends_on "macos" => :ventura`; `bin.install "claude-ctl"`.
  **`<OWNER>` ve `<SHA256>` yer tutucuları bu görevde bilinçli olarak bırakılır**; ikisi de ilk release
  sonrası doldurulur (aşağıdaki iki adım). Yer tutucu bırakılan tek dosya budur.

- [ ] **Step 4: `.github/workflows/release.yml` yaz**

  Trigger: `on: push: tags: ["v*"]`. Job: `runs-on: macos-14`; adımlar: `swift build -c release --arch arm64 --arch x86_64` (universal), `swift test`, `tar` arşivi + `shasum -a 256` hesapla, `gh release create` ile yükle.

- [ ] **Step 5: GitHub reposunu oluştur ve `<OWNER>` yer tutucusunu çöz**

  Run: `gh repo create claude-ctl --public --source=. --remote=origin --push && gh repo view --json owner -q .owner.login`
  Expected: remote eklenir ve `<OWNER>` yerine gerçek kullanıcı adı yazılır (Formula + workflow).

- [ ] **Step 6: İlk release'i oluştur ve `<SHA256>` yer tutucusunu doldur**

  Run: `git tag v0.1.0 && git push origin v0.1.0` (workflow release'i otomatik yükler), sonra
  `curl -sL https://github.com/<OWNER>/claude-ctl/releases/download/v0.1.0/claude-ctl-0.1.0.tar.gz | shasum -a 256`
  Expected: SHA256 çıktısı Formula'daki `sha256` alanına yazılır ve commit'lenir.

- [ ] **Step 7: `swift build -c release` hatasız tamamlanıyor ve `swift test` geçiyor**

  Run: `swift build -c release && swift test`
  Expected: build başarılı, testler PASS.

- [ ] **Step 8: Commit**

  ```bash
  git add README.md LICENSE Formula .github
  git commit -m "docs: README, MIT lisansı, Homebrew formülü ve release iş akışı"
  ```

---

### Task 9: E2E smoke betiği ve canlı doğrulama

**Files:**
- Create: `Scripts/smoke.sh`

**Interfaces:**
- Consumes: derlenmiş `claude-ctl` binary'si (`build/release/claude-ctl`), gerçek `Claude.app`.
- Produces: `Scripts/smoke.sh` — çıkış kodu 0 (hepsi geçti) / 1 (bir şey başarısız).

- [ ] **Step 1: `Scripts/smoke.sh` yaz**

  Bash, `set -euo pipefail`. Adımlar:
  1. `BIN` = `build/release/claude-ctl` (yoksa `swift build -c release` ile üret).
  2. `WORK=$(mktemp -d)`; `SMOKE_NAME="smoke-$$"`.
  3. `$BIN new "$SMOKE_NAME" --workdir "$WORK"` → exit 0.
  4. `$BIN start "$SMOKE_NAME"` → exit 0; 10 sn bekle.
  5. `PROFILE=~/Library/Application\ Support/claude-ctl/instances/$SMOKE_NAME/profile` → `test -f "$PROFILE/Cookies"` (profil ayrıştı ✓).
  6. `$BIN list --json` → çıktıda `"$SMOKE_NAME"` geçiyor ve `"isRunning": true`.
  7. `$BIN status "$SMOKE_NAME"` → exit 0.
  8. `$BIN doctor "$SMOKE_NAME"` → exit 0 veya 1 (fail yoksa 0) — çıktıda "claude-app" geçiyor.
  9. `$BIN logs "$SMOKE_NAME" -n 5` → exit 0.
  10. `$BIN stop "$SMOKE_NAME"` → exit 0; 3 sn bekle; `$BIN list --json` → `"isRunning": false`.
  11. `$BIN new "$SMOKE_NAME" --workdir "$WORK"` → **exit != 0** (duplicate reddi) — hata "`zaten var`" içeriyor.
  12. `$BIN new "GEÇERSİZ AD" --workdir "$WORK"` → exit 2 (usage hatası, geçersiz ad).
  13. `$BIN new "gecersiz-ad"` → exit 2 (eksik `--workdir`).
  14. **İki instance izolasyonu**: ikinci bir instance (`smoke2-$$`) oluşturulur, ikisi de başlatılır,
      sonra `PROFILE1` ve `PROFILE2` içinde `Cookies` dosyası **var** ve **farklı dizinlerde** olduğu doğrulanır;
      `PROFILE1/Cookies` ile `PROFILE2/Cookies` boyutlarının/ içeriklerinin birbirine karışmadığı kontrol edilir
      (her biri kendi profilinde `Local Storage` ve `IndexedDB` dizinine sahip olmalı).
  15. İkinci instance durdurulur.
  16. Sonunda: `$BIN stop "$SMOKE_NAME" || true`, `$BIN stop "smoke2-$$" || true` ve `rm -rf "$WORK"`.

- [ ] **Step 2: Betiği çalıştır ve doğrula**

  Run: `chmod +x Scripts/smoke.sh && ./Scripts/smoke.sh`
  Expected: tüm adımlar başarılı, betik exit 0 döner, `echo` çıktıları hangi adımın geçtiğini gösterir.

- [ ] **Step 3: Manuel doğrulama (spec §13 açık noktaları)**

  Kontrol listesi (insan gözüyle):
  1. **Workdir tohumlama**: `smoke` instance'ının Code sekmesi açıldığında seçili klasör `WORK` içindeki
     proje klasörü mü? (Ayrıca `claude_desktop_config.json` → `localAgentModeTrustedFolders` ve
     `ccd-session-presets.json` → preset girdisi doğru mu?)
  2. **Ayrı hesap**: ikinci instance'ta farklı bir Anthropic hesabıyla giriş yapılabiliyor mu?
     (Birinci instance'ın oturumu etkilenmemeli.)
  3. **Dock**: iki instance çalışırken Dock'ta iki ayrı Claude tile'ı görünüyor mu?
  4. **`claude://`**: yeni bir instance'ta "Sign in" akışı başlatıldığında tarayıcıdaki geri dönüş
     hangi instance'a düşüyor?
  5. **Güncelleme**: Claude Desktop güncellendikten sonra `doctor <ad>` sürüm farkını bildiriyor mu,
     `start` çökmeden yeni sürümle mi açılıyor?

- [ ] **Step 3: Commit**

  ```bash
  git add Scripts/smoke.sh
  git commit -m "test: canlı E2E smoke betiği"
  ```
