# TODO

`claude-ctl` v0.1.0 (2026-11-08) sonrası için yapılacaklar. **2026-11-08 güncellemesi:**
§1 ve §2 tamamlandı (araç artık `claude-orchestrator`); açık kalanlar §3 araştırma
başlıkları ve §4'teki dağıtım işleri. Her maddenin altında ne yapıldığı/neden
yapılmadığı not edildi. Bölümler öncelik sırasına göre
değil, bağımlılık sırasına göre dizilmiştir: §1 yol haritasının omurgası, §2–§4 bunu
tamamlayan/serbest bırakılan işler.

Durum işaretleri: `[ ]` yapılmadı · `[~]` kısmen yapıldı · `[x]` bitti

---

## 1. Oturum yönetimi: instance'lar arası konuşma transferi

Bugün `claude-ctl` **instance** yönetiyor; her instance kendi Claude Code config dizinine
sahip, ama oturumlar o instance'a hapsoluyor. Hedef: oturumları instance'lar arasında
taşınabilir kılmak — "1. instance'ın son oturumu 2. instance'a gitsin" senaryosu.

### 1.1 Komut adı: `claude-ctl` → `claude-orchestrator` `[x]`

Araç artık sadece çoklu instance değil, **oturum orkestrasyonu** aracı; adı buna uygun
hale getirilmeli.

- [x] Paket/binary/ürün adı `claude-orchestrator` olsun (`Package.swift` `name`/`products`,
      `ClaudeCtlCore`/`ClaudeCtlAgent` modül adları, `ClaudeCtl` tipi → `Orchestrator`)
      → `OrchestratorCore`, `OrchestratorAgent`, `Orchestrator`, `OrchestratorError`
- [x] `Output`/`Usage` metinleri ve README güncellensin
- [x] Homebrew formülü yeniden adlandırılsın (`Formula/claude-orchestrator.rb`) → tap:
      [Yuix-Networks/homebrew-tap](https://github.com/Yuix-Networks/homebrew-tap); ayrıca
      `install.sh` (curl). Her sürümde tap formülünün `url`/`sha256`'sı elle güncelleniyor
- [x] Release iş akışı yeni adı üretsin
- [x] **Kırıcı değişiklik**: v0.1.0'ı kullananlar için `claude-ctl` → `claude-orchestrator`
      yönlendirmesi (eski ad için sembolik link veya "bu komut taşındı" uyarısı) eklensin
      → **Karar (v0.2.3): yönlendirme yok.** `claude-ctl` takma adı kaldırıldı; tek komut
      `claude-orchestrator`. Veri dizini ve LaunchAgent etiketi eski adıyla kalıyor
- [x] Veri dizini adı kararı: `~/Library/Application Support/claude-ctl/` kalsın mı, yoksa
      `claude-orchestrator/` olsun mu? (Kalsın → mevcut instance'lar bozulmaz; değişirse
      taşıma/migration gerekir. **Öneri: kalsın.**) → **Kaldı.** LaunchAgent etiketi
      `com.claude-ctl.agent` de aynı sebeple korundu.

### 1.2 Oturum modeli ve nerede yaşıyor `[x]`

Claude Code oturumları instance'ın `CLAUDE_CONFIG_DIR` (= `claude-code/`) altında:

```
<config-dir>/
├── projects/<cwd-slug>/
│   ├── <session-id>.jsonl              # oturum transcript'i (her mesaj bir satır)
│   ├── <session-id>/subagents/*.jsonl  # alt ajan transcript'leri
│   └── sessions-index.json             # proje oturum indeksi
├── history.jsonl                       # komut geçmişi
└── todos/<session-id>.json             # oturumun TODO dosyaları
```

- [x] `SessionStore` tipi: `<config-dir>` ağacını okuyup oturum listesi çıkarsın
      (id, cwd-slug, gerçek cwd, başlangıç/bitiş zamanı, mesaj sayısı, ilk/son mesaj özeti)
      → 3,2 GB / 665 transcript'lik gerçek kurulumda tam JSON çözümü 39 sn sürdü; mmap +
      bayt kalıbı süzgeci ile 5 sn, yol/boyut/mtime önbelleğiyle 0,3 sn. Desktop başlığı
      `<profil>/claude-code-sessions/<hesap>/<org>/local_*.json` → `cliSessionId` ile eşleniyor
- [x] `cwd-slug` çözümlemesi: `/Users/x/workspace/vpn` → `-Users-x-workspace-vpn`
      (dikkat: `a-b` ile `a/b` aynı slug'a düşüyor → çakışma tespiti gerekli)
      → hedefteki `sessions-index.json` → `originalPath` farklıysa transfer reddediliyor
- [x] Claude Desktop'un **kendi sohbet geçmişi** ayrı bir konu — profil içindeki
      `IndexedDB/https_claude.ai_0.indexeddb.leveldb` altında, hesaba bağlı.
      Transfer edilebilir mi? (bkz. §1.5) → hayır, bkz. §1.5 kararı

### 1.3 `session` komut ailesi `[x]`

```
claude-orchestrator session list [--instance <ad>] [--project <yol>] [--json]
claude-orchestrator session show <session-id> [--instance <ad>]
claude-orchestrator session move <session-id> --to <instance> [--force]
claude-orchestrator session copy <session-id> --to <instance>
claude-orchestrator session last --from <instance> --to <instance>
```

- [x] `list`: tüm instance'ların oturumlarını bir tabloda göster (instance, proje, zaman,
      mesaj sayısı); varsayılan: çalışan instance'lar → **sapma:** varsayılan *tüm*
      instance'lar, `--running` ile yalnız çalışanlar (hiç instance çalışmıyorken boş
      liste kafa karıştırıyordu)
- [x] `show`: tek oturumun ayrıntısı (cwd, mesaj önizlemesi, araç çağrıları, süre)
- [x] `move`: oturumu hedef instance'ın config dizinine **taşı** (kaynak silinir)
- [x] `copy`: kopyala (kaynak kalır)
- [x] `last --from --to`: "1. instance'ın son oturumunu 2. instance'a taşı" — istenen
      senaryonun kısayolu (`move` + "en son" seçimi); `--copy` ile kopyalar
- [x] Her komut `--json` desteklesin (mevcut komutlarla tutarlılık)
- [x] Ek: `default` adı instance dışı Claude kurulumunu (`~/.claude`) gösteriyor; yeni
      instance'a bu ad verilemiyor. Oturum kimliği yerine benzersiz önek kabul ediliyor

### 1.4 Transfer mekaniği `[x]`

- [x] Kopyalanacak dosyalar: `projects/<slug>/<session-id>.jsonl`, varsa
      `projects/<slug>/<session-id>/` (alt ajanlar), `todos/<session-id>.json`,
      ve hedefte `sessions-index.json` kaydının eklenmesi/güncellenmesi (kayıttaki mutlak
      config yolları hedefe çevriliyor). Ek olarak Desktop kenar çubuğu üst verisi hedefin
      etkin hesap/org dizinine, hesaba bağlı alanları atılarak yazılıyor — **deneysel:**
      girişli iki hesapla canlı doğrulanmadı
- [x] **Hedef instance çalışıyorsa** uyarılmalı (dosya kilidi riski) — ya durdurulsun ya da
      `--force` ile devam edilsin (`move` kaynağın da durmuş olmasını istiyor)
- [x] Hedef instance'ın CLI sürümü kaynakla farklıysa uyarı (transcript formatı değişebilir)
- [x] Çakışma: hedefte aynı `session-id` varsa ne olacağı açıkça tanımlansın
      (varsayılan: reddet, `--force` ile üzerine yaz)
- [~] Transfer sonrası doğrulama: hedefte `claude --resume <session-id>` çalışıyor mu?
      (otomatik test: `session show` hedefte oturumu görebiliyor) → transfer sonunda hedef
      `SessionStore` oturumu bulamazsa hata; smoke testi `session show` ile doğruluyor.
      Gerçek `claude --resume` girişli bir instance gerektirdiği için otomatikleştirilmedi
- [x] Kopyalama **atomik** olsun (yarım kalmış transcript olmasın): geçici dosya + rename
- [x] Geri alma: `move` öncesi yedek alınsın mı? (`backups/` Claude Code'un kendi
      `~/.claude/backups` mekanizmasına benzer) → `move` kaynağı silmiyor,
      `backups/<zaman>-<id>/` altına taşıyor (+ `manifest.json`). Otomatik geri yükleme
      komutu yok; dosyalar elle geri konabilir

### 1.5 Claude Desktop sohbet geçmişi (ayrı ve zor başlık) `[x]` — karar: yapılmayacak

- [x] Chat sekmesinin konuşmaları profilin IndexedDB'sinde; hesaba bağlı (claude.ai).
      Instance'lar farklı hesaplarla girildiyse taşımanın anlamı nedir? karar verilsin
      → Sohbetler claude.ai sunucusunda yaşıyor; IndexedDB yalnızca önbellek. Aynı hesaplı
      instance onları zaten görüyor, farklı hesaplı instance göremez. Taşıma anlamsız.
- [x] Aynı hesapla iki instance arasında taşıma mümkün mü? (IndexedDB kopyalama,
      uygulama kapalıyken, LevelDB bütünlüğü korunarak)
- [x] Alternatif: taşıma yerine **paylaşma** (symlink) — gerek yok (yukarıdaki sebep) — Parall'ın Cowork için yaptığı gibi

### 1.6 Instance yaşam döngüsü `[x]`

- [x] `new` komutu instance'ı "boş" değil, **oturumlarıyla** birlikte oluşturabilsin
      ("yeni bir instance yaratacak, içinde oturumlar olacak") → `new --sessions-from`.
      Ayrıca `--workdir` artık isteğe bağlı (hesap başına instance senaryosu)
- [x] `remove --purge` oturumları da silmeli (şu an config dizinini siliyor ✓ doğrula)
- [x] Instance klonlama: `claude-orchestrator clone <instance> --as <yeni-ad>` —
      profil + config dizini + oturumlarla birlikte → `clone <ad> --as <yeni>`; kaynak
      çalışırken reddediliyor; APFS klonu (400 MB'lık denemede ek disk ~0)

### 1.7 Ortak projeler (Desktop "environment") `[x]`

- [x] Projeler merkezi kayıtta (`config.json` → `projects`); `project add/list/remove/sync/import`
      (takma ad `env`). Ortam = `ccd-session-presets.json` → `byAccount[hesap].presets[]`
- [x] `new` ve her `start` kayıtlı projeleri uygular; giriş öncesi yalnızca güvenli klasör
- [x] Profildeki tüm hesaplara yazılır; aynı klasörde var olan ortamın ayarlarına dokunulmaz
- [ ] Canlı doğrulama: girişli bir instance'ta yazılan ortamın Code sekmesinde göründüğü
      henüz gözle doğrulanmadı (dosya biçimi gerçek profildeki ortamlarla aynı)
- [x] `project apply` / `project export`: elle düzenlenen `projects.json`
      (`~/.config/claude-orchestrator/`), önce tüm dosya doğrulanır, `--dry-run`, `--prune`
- [x] `defaults` (ortak ek klasörler, izin modu) ve proje başına `permissionMode`
      (`preferences.epitaxyPrefs` → `epitaxy-folder-permission-mode-v2.<hesap>`); org kısıtına
      (`bypassPermissionsGateByAccount`) dokunulmuyor
- [ ] İzin modunun Desktop'ta gerçekten varsayılan olarak seçildiği girişli bir instance'ta
      gözle doğrulanmadı (anahtarlar gerçek profildeki kayıtlarla aynı biçimde)
- [x] `memory`: `~/.claude/CLAUDE.md` her instance'ın config dizinine sembolik bağ
- [x] Desktop ortam listesini arayüz deposunda (`Local Storage` → `ccd-session-presets.<hesap>`)
      tutuyor; `ccd-session-presets.json`'u hesap başına yalnızca ilk açılışta içeri alıyor
      (`fileMirrored`), sonra ezip geçiyor. `--reset-desktop` profil kapalıyken `Local Storage`'ı
      yedekleyip listeyi yeniden içeri aldırıyor (serdar'da canlı doğrulandı: açılış sonrası 41 ortam
      korundu, Claude dosyayı yeniden yazmadı)
- [ ] Daha hassas yol: yalnızca `ccd-session-presets.<hesap>` anahtarını LevelDB'de düzenlemek
      (arayüz tercihleri korunur; Claude'un iç biçimine bağlı)
- [ ] Çalışan instance'a anında yansıtma yok (Claude dosyayı bellekte tutuyor; yeniden
      başlatma gerekiyor)

---

## 2. Ertelenen inceleme bulguları `[x]`

`claude-ctl v1` için yapılan kod incelemesinde bulunan, bilinçli olarak ertelenen küçük
işler. Hepsi çalışma ama önceliği düşük.

- [x] `list --json` çıktısı `{"instances":[…]}` sarmalayıcısı kullanıyor; düz dizi bekleniyor
      geriye dönük uyum gerekiyor. (JSON tipi düzeltildi: `profileSizeBytes` artık sayı.)
      → **Karar: sarmalayıcı kalıyor** (smoke testi ve betikler `instances` anahtarına bağlı;
      sarmalayıcı yeni alan eklemeye izin veriyor). Tüm JSON çıktılarına `schemaVersion: 1`
- [x] Tohumlama çoklu hesapta **alfabetik ilk** hesabı seçiyor; aktif hesabı belirleyen
      mantık yok → preset yanlış hesaba yazılabiliyor
      (`ProfileSeeder.addSessionPreset`) → `config.json` → `lastKnownAccountUuid`, sonra
      `bootSideSessions.accountUuid`; belirsizse preset yazılmıyor (tahmin yok)
- [x] `LogReader` tüm `main.log` dosyasını belleğe alıyor (son N satır için gereksiz);
      `logs -f` dosya döndürmeyi (rotation) takip etmiyor, takip sessizce duruyor
      → 64 KB bloklarla sondan okuma; `LogFollower` inode/boyut değişimini algılıyor
- [x] `launchctl bootstrap` hatası yutuluyor; CLI "kuruldu" diyor ama agent yüklenmemiş
      olabilir. Ayrıca `KeepAlive: true` + duplicate başlatmada launchctl respawn döngüsü
      (`LaunchAgentInstaller`, `AgentCommand`) → önce `bootout`, `bootstrap` hatası
      raporlanıyor; `KeepAlive: {SuccessfulExit: false}` ve ikinci örnek 0 ile çıkıyor
- [x] Agent singleton kilidi `O_EXCL` ile değil yaz-oku ile alınıyor → TOCTOU yarışı;
      ayrıca ölmüş PID dosyası agent'ın kalıcı olarak "zaten çalışıyor" demesine yol açıyor
      (`StatusItemController.acquireSingleton`) → `agent.lock` üzerinde `flock`
- [x] `remove --purge` için onay/yedek yok; tek komut ~500 MB + oturumları siliyor
      → onay soruyor (terminal yoksa `--yes` şart), varsayılan Çöp Kutusu, `--permanent`
      ile kalıcı
- [x] `ProfileSeeder.seed(instanceName:workdir:)` ölü kod → silindi
- [x] `StatusItemController.refresh()` `statusItems` sözlüğünü iterasyon sırasında
      değiştiriyor (bugün güvenli, kırılgan) ve her 5 saniyede tüm menüleri yeniden
      kuruyor (UI gereksiz titreme) → anahtar kopyası üzerinde dönülüyor; menü yalnızca
      durum değişince kuruluyor. Ek: durmuş instance için menüye "Başlat" eklendi

---

## 3. Bilinen sınırların kaldırılması

README'de "bilinen sınırlar" olarak belgelenenler. Hiçbiri v1 için engel değildi.

- [ ] **Ayrı Dock ikonu / menü çubuğu adı.** Instance'lar aynı Claude ikonunu paylaşıyor.
      Ayrı kimlik için hedef app'in bundle kimliğinin değişmesi gerekiyor; bu yol macOS'un
      hardened-runtime / library-validation duvarlarına çarpıyor (Electron klonu denendi:
      sandbox extension + helper adlandırma engelleri). Parall bu alanda reverse
      engineering ile çözmüş — açık kaynak olarak yeniden üretmek ayrı bir araştırma projesi.
      Ara yol: rozetli menü çubuğu ikonu (mevcut) + `app.dock.setBadge` benzeri bir kanal
- [ ] **Paylaşılan log dosyaları** (`~/Library/Logs/Claude/`). Instance başına ayrı log için
      `app.setPath("logs", …)` gerekiyor; Claude bunu yalnızca `CLAUDE_USER_DATA_DIR`
      (imzalı build'de yok sayılıyor) altında yapıyor. `logs` şu an başlangıç zamanına
      göre filtreliyor (kesin ayrım yok)
- [~] **`claude://` handler çakışması.** Derin bağlantı tek instance'a gidiyor; ölçüm
      (hangi instance'a gittiği) hâlâ yapılmadı → §1.1/§1.3 ile birlikte çözülebilir
      → `signin --exclusive` diğer instance'ları giriş süresince kapatıp sonra açıyor;
      instance dışı Claude açıksa uyarıyor. Ölçüm yapılmadı: kullanıcının açık ana
      Claude'una deneme URL'i göndermek riskliydi
- [ ] **Her instance kendi Claude Code CLI'sini indiriyor** (~525 MB, instance başına).
      Paylaşım (symlink) veya "tek CLI, çok config dir" modu araştırılabilir
      → Bulgu: CLI `CLAUDE_CONFIG_DIR`'de değil, **profilde** (`<profil>/claude-code/<sürüm>/`).
      `clone` APFS klonu kullandığı için klonlanan instance ek yer kaplamıyor; ayrı
      oluşturulan instance'lar için paylaşım hâlâ açık (eşzamanlı güncelleme yarışı riski)

---

## 4. Altyapı ve bakım

- [ ] CI: `swift test`'in yanına **macOS 13** (Ventura, `open --env`'in minimum sürümü)
      üzerinde bir smoke job — `open --env` davranışı sürüme göre değişebilir
      → GitHub `macos-13` runner'larını kullanımdan kaldırdı; ayrıca smoke testi kurulu
      Claude Desktop gerektiriyor. Kendi barındırılan runner olmadan yapılamaz
- [ ] CI: release iş akışı `xcodebuild` ile universal binary üretiyor ✓; `macos-15`
      runner'ı kullanıyor (arm64 runner sorunu nedeniyle) — runner bulunabilirliği izlenmeli
- [~] `brew audit --strict` / `brew style` ile formül denetimi → `brew style` temiz;
      `brew audit --strict` tap gerektiriyor ve sha256 release sonrası belli olacak
- [ ] Kod imzası ve notarizasyon: dağıtım `brew` üzerinden çalışıyor ama doğrudan
      indirilen binary imzasız — imzalı/notarize sürüm üretilmeli mi?
- [ ] Çoklu mimi test: `swift test` yalnızca arm64'de koşuyor; `x86_64` (Intel) için
      ayrı doğrulama
- [x] `doctor` çıktısı JSON şeması sürümlensin (ileride otomasyon için) → tüm JSON
      çıktılarında `schemaVersion`
