# claude-ctl — Claude Desktop çoklu instance yöneticisi (macOS)

Tarih: 2026-11-08
Durum: Onaylandı (tasarım Bölüm 1 + 2)
Kapsam: v1 = CLI çekirdek + menü çubuğu ikonu

---

## 1. Amaç

`/Applications/Claude.app`'i aynı anda, birbirinden bağımsız N instance olarak çalıştıran
bir macOS komut satırı aracı. Her instance'ın:

- ayrı Electron profili (cookie, oturum, ayarlar, log),
- ayrı Claude Code yapılandırması (`~/.claude` eşdeğeri),
- ayrı giriş hesabı,
- ayrı çalışma klasörü (workdir),
- ayrı Dock tile'ı

olması gerekiyor.

Araç **orijinal `Claude.app` bundle'ine dokunmaz**: kopyalamaz, yamalamaz, yeniden imzalamaz.
Bu sayede kod imzası, notarization, otomatik güncelleme ve macOS izinleri bozulmaz.

Referans: https://parall.app (ticari, 10,99 USD) — bu araç onun CLI benzeri, Claude'a özel ve
açık kaynak versiyonudur.

### Kapsam dışı (v1)

- `Claude.app` dışındaki uygulamalar (genel amaçlı multi-instance launcher değil).
- Ayrı Dock ikonu / uygulama adı (aşağıdaki "Bilinen sınırlar"a bakın).
- GUI (SwiftUI ayar uygulaması).
- Parall'ın menü çubuğu ikonu, Web App Shortcut, HOME override modları.

---

## 2. Doğrulanmış bulgular (ölçüm sonuçları)

Bu tasarımın dayandığı deneyler 2026-11-08 tarihinde gerçek `Claude.app` (4.4212.0) üzerinde
yapıldı. Her madde kanıtıyla birlikte kayıtlıdır.

| # | Bulgu | Kanıt |
|---|---|---|
| F1 | `--user-data-dir=<yol>` Electron profilini (Cookies, Local Storage, IndexedDB, Cache) tam olarak taşır | profilde `Cookies`, `Local Storage`, `IndexedDB` oluştu |
| F2 | `CLAUDE_CONFIG_DIR=<yol>` Claude Code yapılandırmasını (`~/.claude`, `.claude.json`, oturumlar) ayırır | `claude-code-home/` altında `sessions/`, `.claude.json` oluştu |
| F3 | `CLAUDE_USER_DATA_DIR` **imzalı build'de yok sayılır** | `~/Library/Logs/Claude/main.log`: `[user-data-dir] CLAUDE_USER_DATA_DIR is set and signed builds ignore it (path kind: local); this launch uses the default data folder` |
| F4 | `open -n` her instance için ayrı bir Dock tile'ı açar | `lsappinfo` → 3 ayrı ASN; Dock ekran görüntüsünde 3 Claude ikonu yan yana |
| F5 | Orijinal bundle'e dokunulmadığı için imza/updater korunur | `codesign -dv` → `Developer ID Application: Anthropic PBC`, notarize; araç bundle'e yazmaz |
| F6 | Claude.app sandbox değil; `Contents/MacOS/Claude` yalnızca 54 KB, `Frameworks` 288 MB, `app.asar` 55 MB | `codesign -d --entitlements -` → `app-sandbox` yok |
| F7 | Electron klonu (stub) yolu macOS güvenlik duvarlarına çarpıyor: (a) library validation — "mapping process and mapped file have different Team IDs"; (b) `disable-library-validation` entitlement'i sonrası "Unable to find helper app" (helper adı `CFBundleName`'den türetiliyor); (c) `CFBundleName` "Claude" yapılınca sandbox extension hatası ve süreç ölümü | Doğrudan deneme, loglar |
| F8 | Native launcher + `execve` kimliği geri döndürüyor: process Claude.app altında yeniden kaydediliyor | `lsappinfo` → launcher'ın bundle ID'si yok, Claude'ın bundle path'i var |
| F9 | `claude://` deep link tek handler'a gider; `disableDeepLinkRegistration` managed config anahtarı mevcut | asar içinde `Disable claude:// deep-link handling` tanımı |
| F10 | Workdir profilde saklanıyor: `claude_desktop_config.json` → `preferences.localAgentModeTrustedFolders` ve `ccd-session-presets.json` → `byAccount[hesapUuid].presets[].target.cwd` | Profil dosyaları okundu |
| F11 | Oturum `safeStorage` ile şifrelenip profil içinde saklanıyor (Keychain yalnızca şifreleme anahtarı) → profil başına ayrı hesap mümkün | asar içinde 138 `safeStorage` referansı |
| F12 | Electron stub'unun `CFBundleName`'i helper adlarını belirliyor (`Claude Helper.app`) | "Unable to find helper app" hatası |

### Uygulama seçimi

F1 + F2 birlikte, doğrulanmış ve uygulanabilir tek ayrıştırma mekanizmasını veriyor:

```
open -n -a /Applications/Claude.app \
     --args --user-data-dir=<profile> \
     --env  CLAUDE_CONFIG_DIR=<codeDir>
```

`open --env` macOS 13 (Ventura) ve sonrasında mevcut → **minimum macOS 13**.

---

## 3. Mimari

Tek Swift binary, iki mod.

```
claude-ctl              # CLI modu (varsayılan)
claude-ctl agent        # menü çubuğu ikonları
```

### Bileşenler

| Bileşen | Sorumluluk |
|---|---|
| `Command` katmanı | Alt komut ayrıştırma, `--json` çıktı, exit code'ları |
| `InstanceStore` | `config.json` okuma/yazma, instance CRUD, path üretimi |
| `Launcher` | `open -n` çağrısı, PID yakalama, profil kilidi kontrolü |
| `ProfileSeeder` | Workdir → güvenli klasörler + session preset yazımı (idempotent merge) |
| `Agent` | `NSStatusItem` üretimi, instance durumu izleme, aksiyon menüleri |
| `Doctor` | Sürüm uyumu, kilit, izin, disk kontrolleri |

### Modüller arası bağımlılık yönü

`Command` → (`InstanceStore`, `Launcher`, `ProfileSeeder`, `Doctor`) ve
`Agent` → (`InstanceStore` + `Launcher`).
Hiçbir modül diğerini doğrudan çağırmaz; hepsi `InstanceStore` üzerinden veriye erişir.

---

## 4. Veri yerleşimi

Tüm veriler `~/Library/Application Support/claude-ctl/` altında:

```
~/Library/Application Support/claude-ctl/
├── config.json                       # instance tanımları
├── state/
│   └── agent.pid                     # agent singleton kilidi
└── instances/
    └── <name>/
        ├── profile/                  # Electron profili  (--user-data-dir)
        ├── claude-code/              # ayrı ~/.claude    (CLAUDE_CONFIG_DIR)
        └── state.json                # pid, startedAt, son bilinen sürüm, hesap durumu
```

### `config.json` şeması

```json
{
  "version": 1,
  "instances": {
    "work": {
      "name": "work",
      "workdir": "/Users/serdar/workspace/nameocean",
      "createdAt": "2026-11-08T10:00:00Z",
      "autoStart": false,
      "iconBadge": null
    }
  }
}
```

`profile` ve `claude-code` yolları türetilir (config'de saklanmaz), böylece ana dizin
taşınırsa instance'lar bozulmaz.

---

## 5. Komut yüzeyi

| Komut | İşlev | Notlar |
|---|---|---|
| `new <ad> --workdir <yol>` | Instance oluşturur, profili tohumlar | Var olan ad → hata |
| `start <ad>` | Instance'ı başlatır | Çalışıyorsa no-op; `--folder <yol>` ile tek seferlik klasör argümanı (§7 yedek yol) |
| `stop <ad>` | Instance'ı durdurur | Önce nazik (SIGTERM), sonra zor |
| `list` | Tablo: ad, durum, pid, workdir, profil boyutu | `--json` destekler |
| `status <ad>` | Detay: yollar, son sürüm, hesap durumu, son log satırı | `--json` destekler |
| `logs <ad>` | Claude loglarını yazdırır | `-f/--follow`, `--lines N`. Loglar **tüm instance'lar arasında paylaşılır** (`~/Library/Logs/Claude/main.log`); çıktı instance'ın başlangıç zamanına göre filtrelenir |
| `signin <ad>` | Giriş rehberi + `claude://` handler yönlendirmesi | Bkz. §9 |
| `open <ad>` | Workdir / profil klasörünü Finder'da aç | `--target workdir\|profile` |
| `agent --install` | Menü çubuğu ikonunu LaunchAgent olarak kurar | `--uninstall` de var |
| `doctor [<ad>]` | Sağlık kontrolü | Tüm instance'lar veya tek instance |

Çıktı sözleşmesi: exit code `0` başarılı, `1` çalışma hatası, `2` kullanım hatası.
Tüm komutlar `--json` destekler; hata mesajları eyleme dönük olur ("şunu çalıştır: …").

---

## 6. Başlatma akışı

```
claude-ctl start <ad>
 1. Instance var mı?          → yoksa hata (2)
 2. Çalışıyor mu?             → PID canlıysa no-op (0)
 3. Profil kilidi var mı?     → SingletonLock doluysa: "başka instance kullanıyor" (1)
 4. Workdir hâlâ geçerli mi?  → yoksa uyar, seed'i atla
 5. Profili tohumla           → idempotent merge (bkz. §7)
 6. open -n -a ... --args --user-data-dir --env
 7. PID'yi bekle (max 10 sn)  → bulunamazsa hata (1)
 8. state.json güncelle       → pid, startedAt, claudeVersion
 9. Agent menüsü güncellenir  → agent 5 saniyede bir yoklama yapar (anlık bildirim yok)
```

`stop`: SIGTERM → 5 sn bekle → hâlâ yaşıyorsa SIGKILL. `state.json` temizlenir.

---

## 7. Workdir tohumlama (profil seeding)

Claude Desktop'ta Code sekmesinin klasörü profilin içinde tutulur. Instance oluşturulurken
ve her başlatmadan önce (instance kapalıyken) iki dosya yazılır:

**a) `profile/claude_desktop_config.json`**

```jsonc
// preferences.localAgentModeTrustedFolders dizisine workdir eklenir
"preferences": {
  "localAgentModeTrustedFolders": ["/Users/serdar/workspace/nameocean"]
}
```

**b) `profile/ccd-session-presets.json`**

```jsonc
// byAccount[<accountUuid>].presets içine workdir için preset eklenir
{
  "byAccount": {
    "<accountUuid>": {
      "presets": [
        {
          "id": "<uuid>",
          "name": "nameocean",
          "createdAt": 1791993478191,
          "lastUsedAt": 1791993478191,
          "target": { "kind": "local", "cwd": "/Users/serdar/workspace/nameocean" }
        }
      ]
    }
  }
}
```

`<accountUuid>` profil dosyalarından bulunur (`ccd-session-presets.json` anahtarları,
`bridge-state.json`); hesap henüz yoksa (ilk girişten önce) preset yazılmaz, güvenli klasör
yazılır ve preset ilk `start` sonrası (hesap oluşunca) tamamlanır.

**Idempotency:** her iki merge de "yol zaten varsa ekleme" kuralıyla çalışır; tohumlama N kez
çalıştırılsa da sonuç aynıdır. Mevcut dosya içeriği korunur, yalnızca ilgili alanlar
güncellenir (JSON'u baştan yazmadan, hedef alanı merge ederek).

**Alternatif (yedek yol):** `claude-ctl start <ad> --folder <yol>` → klasör uygulama argümanı
olarak geçirilir. Kalıcı ayar yazmaz; profil tohumlaması başarısız olursa bu kullanılır.

---

## 8. Menü çubuğu agent'ı

Tek process (`claude-ctl agent`), tüm instance'lar için birer `NSStatusItem`.

- İkon: Claude ikonu + instance rozeti (sayı veya kısa ad). Template image olarak işlenir.
- Menü: **Öne getir** / **Durdur** / **Workdir'yi aç** / **Profil klasörünü aç** / **Loglar** /
  **Sign-in yardımı**.
- "Öne getir": `state.json`'daki PID üzerinden `NSRunningApplication.activate(options:
  [.activateAllWindows])`.
- Durum güncellemesi: 5 saniyede bir yoklama ile `config.json` ve PID canlılığı kontrol edilir,
  menüler yenilenir (anlık bildirim/FSEvents kullanılmaz).
- Singleton: `state/agent.pid` dosyası; içindeki pid canlıysa ikinci agent başlamaz.
- Kurulum: `claude-ctl agent --install` → `~/Library/LaunchAgents/com.claude-ctl.agent.plist`
  (RunAtLoad + KeepAlive) yazılır.

v1'de menüde "Yeni pencere" yoktur: Electron uygulamasına AppleScript ile yeni pencere
açtırmak güvenilir değil; "Öne getir" yeterlidir.

---

## 9. Edge case'ler ve kararlar

| Durum | Karar |
|---|---|
| Log dosyaları paylaşılıyor | Claude logları `~/Library/Logs/Claude/` altına yazar ve bu yol `--user-data-dir`'dan etkilenmez (`app.setPath("logs", …)` yalnızca yok sayılan `CLAUDE_USER_DATA_DIR` için çalışır). `logs` komutu instance'ın `startedAt` zamanına göre filtreler; kesin ayrım yoktur |
| Aynı profil iki instance'da | Chromium `SingletonLock` → ikinci açılış reddedilir. `start` kilidi önceden kontrol eder, çökmez |
| Claude güncellemesi | Bundle'e dokunulmaz → sonraki açılışta yeni sürüm. `doctor` sürüm değişimini fark eder, profili yeniden tohumlar |
| Ölü instance / bayat state | `list` PID canlılığını doğrular; bayat `state.json` temizlenir |
| `claude://` giriş yönlendirmesi | `signin` hedef instance'ı yeniden başlatır (handler en son kaydeden olur) ve diğer instance'ların kapalı olmasını ister. Hangi instance'ın handler olduğu uygulama sırasında ölçülür ve buna göre kesinleştirilir |
| Disk | Instance başına ~500 MB (kendi Claude Code CLI kopyası) + profil büyümesi. `list` boyut gösterir, `doctor` eşiği aşınca uyarır |
| macOS izinleri (kamera/mikrofon) | Aynı bundle ID → orijinal app'in izinleri paylaşılır; instance başına yeni izin istemi çıkmaz |
| İlk açılış yavaş | Her instance kendi Claude Code CLI'sini indirir (ağ gerekir) |
| Durum dosyası bozulursa | `config.json` geçerli JSON değilse `start`/`list` açıklayıcı hata verir, dosyayı silmez/üzerine yazmaz |
| Instance adı normalizasyonu | `[a-z0-9-]`, 1-32 karakter; `..` ve `/` reddedilir (path traversal) |
| Workdir silinmişse | `start` uyarır, seed'i atlar, instance yine açılır |

---

## 10. Bilinen sınırlar

1. **Ayrı Dock ikonu yok.** Tüm tile'lar Claude ikonunu gösterir (F4). Instance'ları ayırmak için
   menü çubuğu ikonu + pencere başlıkları kullanılır. Parall'ın ayrı Dock ikonu, hedef app'in
   bundle kimliğini değiştirmeyi gerektirir; bu da Electron klonunun güvenlik duvarlarına
   çarptığı yoldur (F7, F8).
2. **Uygulama menüsü adı "Claude" kalır** — Electron `productName`'i bundle'e gömülü.
3. **Ayrı hesap çalışması** profil başına `safeStorage` blob'larına dayanır (F11) ve ilk
   uygulama sırasında doğrulanacaktır.
4. `claude://` handler tek instance'a gider (§9).
5. **Log dosyaları paylaşılır** (`~/Library/Logs/Claude/`); instance başına ayrı log yok (§9).
6. Araç yalnızca macOS 13+ ve `Claude.app` `PATH`/bilinen konumlarda ise çalışır.

---

## 11. Test stratejisi

**1. Birim testleri (XCTest)**
- `InstanceStore`: config okuma/yazma, ad normalizasyonu, path traversal reddi, varsayılan config.
- `ProfileSeeder`: JSON merge idempotency'si (aynı seed 2× → aynı çıktı), mevcut alanların
  korunması, eksik dosya durumu, hesap bulunamadığında davranış.
- `Command`: alt komut ayrıştırma, `--json` çıktı biçimi, exit code'ları.
- `Launcher`: komut üretimi (argüman dizisi doğru sırada, yollar boşluk içeriyorsa kaçışlı).

**2. Entegrasyon testleri** (macOS, Claude kurulu)
- `open -n` ile iki instance başlatılır → profiller farklı dizinlerde ve birbirinden bağımsız
  (biri diğerinde `Cookies` görmemeli).
- `--user-data-dir` gerçekten profile yazıyor mu (dosya var mı).
- Aynı profili iki kez açma → SingletonLock davranışı doğru raporlanıyor.
- CI'da Claude kurulu değilse skip.

**3. E2E smoke (manuel, macOS)**
`new` → `start` → iki instance paralel → workdir tohumlama doğrulama (Code sekmesinde doğru proje)
→ menü çubuğu ikonları → `stop` → profil dosyaları duruyor.

---

## 12. Dağıtım

- GitHub Releases: derlenmiş tek binary (universal: arm64 + x86_64).
- Homebrew tap: `brew install serdar/tap/claude-ctl` (kendi tap repo'su).
- Kurulum yolu: `/usr/local/bin` veya `/opt/homebrew/bin` (Homebrew yönetir).
- Lisans: MIT.

---

## 13. Uygulama sırasında ölçülecek açık noktalar

1. `claude://` deep link hangi instance'a gidiyor? (en son başlatılan mı, öne alınan mı?)
2. `open --env` + `--args` birlikte, her macOS 13 sürümünde aynı mı?
3. `open -n` ile açılan instance'ın PID'ini güvenilir almak: `open` PID döndürmüyor → süreç
   `--user-data-dir=<benzersiz yol>` argümanıyla eşleştirilerek bulunacak.
4. Profile tohumlama `selected-folder` (Local Storage/leveldb) yerine yeterli mi, yoksa
   `claude_desktop_config.json` + `ccd-session-presets.json` yeterli mi? (F10 doğruladı; ilk
   smoke testinde teyit edilecek.)
5. `localAgentModeTrustedFolders` değişikliği uygulamada "güvenilir klasör" onayı gerektiriyor mu?
6. İki farklı Anthropic hesabıyla iki instance gerçekten ayrı oturum tutuyor mu (F11 varsayımının
   doğrulaması)?
