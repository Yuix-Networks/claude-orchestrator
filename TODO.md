# TODO

`claude-ctl` v0.1.0 (2026-11-08) sonrası için yapılacaklar. Bölümler öncelik sırasına göre
değil, bağımlılık sırasına göre dizilmiştir: §1 yol haritasının omurgası, §2–§4 bunu
tamamlayan/serbest bırakılan işler.

Durum işaretleri: `[ ]` yapılmadı · `[~]` kısmen yapıldı · `[x]` bitti

---

## 1. Oturum yönetimi: instance'lar arası konuşma transferi

Bugün `claude-ctl` **instance** yönetiyor; her instance kendi Claude Code config dizinine
sahip, ama oturumlar o instance'a hapsoluyor. Hedef: oturumları instance'lar arasında
taşınabilir kılmak — "1. instance'ın son oturumu 2. instance'a gitsin" senaryosu.

### 1.1 Komut adı: `claude-ctl` → `claude-orchestrator` `[ ]`

Araç artık sadece çoklu instance değil, **oturum orkestrasyonu** aracı; adı buna uygun
hale getirilmeli.

- [ ] Paket/binary/ürün adı `claude-orchestrator` olsun (`Package.swift` `name`/`products`,
      `ClaudeCtlCore`/`ClaudeCtlAgent` modül adları, `ClaudeCtl` tipi → `Orchestrator`)
- [ ] `Output`/`Usage` metinleri ve README güncellensin
- [ ] Homebrew formülü yeniden adlandırılsın (`Formula/claude-orchestrator.rb`)
- [ ] Release iş akışı yeni adı üretsin
- [ ] **Kırıcı değişiklik**: v0.1.0'ı kullananlar için `claude-ctl` → `claude-orchestrator`
      yönlendirmesi (eski ad için sembolik link veya "bu komut taşındı" uyarısı) eklensin
- [ ] Veri dizini adı kararı: `~/Library/Application Support/claude-ctl/` kalsın mı, yoksa
      `claude-orchestrator/` olsun mu? (Kalsın → mevcut instance'lar bozulmaz; değişirse
      taşıma/migration gerekir. **Öneri: kalsın.**)

### 1.2 Oturum modeli ve nerede yaşıyor `[ ]`

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

- [ ] `SessionStore` tipi: `<config-dir>` ağacını okuyup oturum listesi çıkarsın
      (id, cwd-slug, gerçek cwd, başlangıç/bitiş zamanı, mesaj sayısı, ilk/son mesaj özeti)
- [ ] `cwd-slug` çözümlemesi: `/Users/x/workspace/vpn` → `-Users-x-workspace-vpn`
      (dikkat: `a-b` ile `a/b` aynı slug'a düşüyor → çakışma tespiti gerekli)
- [ ] Claude Desktop'un **kendi sohbet geçmişi** ayrı bir konu — profil içindeki
      `IndexedDB/https_claude.ai_0.indexeddb.leveldb` altında, hesaba bağlı.
      Transfer edilebilir mi? (bkz. §1.5)

### 1.3 `session` komut ailesi `[ ]`

```
claude-orchestrator session list [--instance <ad>] [--project <yol>] [--json]
claude-orchestrator session show <session-id> [--instance <ad>]
claude-orchestrator session move <session-id> --to <instance> [--force]
claude-orchestrator session copy <session-id> --to <instance>
claude-orchestrator session last --from <instance> --to <instance>
```

- [ ] `list`: tüm instance'ların oturumlarını bir tabloda göster (instance, proje, zaman,
      mesaj sayısı); varsayılan: çalışan instance'lar
- [ ] `show`: tek oturumun ayrıntısı (cwd, mesaj önizlemesi, araç çağrıları, süre)
- [ ] `move`: oturumu hedef instance'ın config dizinine **taşı** (kaynak silinir)
- [ ] `copy`: kopyala (kaynak kalır)
- [ ] `last --from --to`: "1. instance'ın son oturumunu 2. instance'a taşı" — istenen
      senaryonun kısayolu (`move` + "en son" seçimi)
- [ ] Her komut `--json` desteklesin (mevcut komutlarla tutarlılık)

### 1.4 Transfer mekaniği `[ ]`

- [ ] Kopyalanacak dosyalar: `projects/<slug>/<session-id>.jsonl`, varsa
      `projects/<slug>/<session-id>/` (alt ajanlar), `todos/<session-id>.json`,
      ve hedefte `sessions-index.json` kaydının eklenmesi/güncellenmesi
- [ ] **Hedef instance çalışıyorsa** uyarılmalı (dosya kilidi riski) — ya durdurulsun ya da
      `--force` ile devam edilsin
- [ ] Hedef instance'ın CLI sürümü kaynakla farklıysa uyarı (transcript formatı değişebilir)
- [ ] Çakışma: hedefte aynı `session-id` varsa ne olacağı açıkça tanımlansın
      (varsayılan: reddet, `--force` ile üzerine yaz)
- [ ] Transfer sonrası doğrulama: hedefte `claude --resume <session-id>` çalışıyor mu?
      (otomatik test: `session show` hedefte oturumu görebiliyor)
- [ ] Kopyalama **atomik** olsun (yarım kalmış transcript olmasın): geçici dosya + rename
- [ ] Geri alma: `move` öncesi yedek alınsın mı? (`backups/` Claude Code'un kendi
      `~/.claude/backups` mekanizmasına benzer)

### 1.5 Claude Desktop sohbet geçmişi (ayrı ve zor başlık) `[ ]`

- [ ] Chat sekmesinin konuşmaları profilin IndexedDB'sinde; hesaba bağlı (claude.ai).
      Instance'lar farklı hesaplarla girildiyse taşımanın anlamı nedir? karar verilsin
- [ ] Aynı hesapla iki instance arasında taşıma mümkün mü? (IndexedDB kopyalama,
      uygulama kapalıyken, LevelDB bütünlüğü korunarak)
- [ ] Alternatif: taşıma yerine **paylaşma** (symlink) — Parall'ın Cowork için yaptığı gibi

### 1.6 Instance yaşam döngüsü `[ ]`

- [ ] `new` komutu instance'ı "boş" değil, **oturumlarıyla** birlikte oluşturabilsin
      ("yeni bir instance yaratacak, içinde oturumlar olacak")
- [ ] `remove --purge` oturumları da silmeli (şu an config dizinini siliyor ✓ doğrula)
- [ ] Instance klonlama: `claude-orchestrator clone <instance> --as <yeni-ad>` —
      profil + config dizini + oturumlarla birlikte

---

## 2. Ertelenen inceleme bulguları

`claude-ctl v1` için yapılan kod incelemesinde bulunan, bilinçli olarak ertelenen küçük
işler. Hepsi çalışma ama önceliği düşük.

- [ ] `list --json` çıktısı `{"instances":[…]}` sarmalayıcısı kullanıyor; düz dizi bekleniyor
      geriye dönük uyum gerekiyor. (JSON tipi düzeltildi: `profileSizeBytes` artık sayı.)
- [ ] Tohumlama çoklu hesapta **alfabetik ilk** hesabı seçiyor; aktif hesabı belirleyen
      mantık yok → preset yanlış hesaba yazılabiliyor
      (`ProfileSeeder.addSessionPreset`)
- [ ] `LogReader` tüm `main.log` dosyasını belleğe alıyor (son N satır için gereksiz);
      `logs -f` dosya döndürmeyi (rotation) takip etmiyor, takip sessizce duruyor
- [ ] `launchctl bootstrap` hatası yutuluyor; CLI "kuruldu" diyor ama agent yüklenmemiş
      olabilir. Ayrıca `KeepAlive: true` + duplicate başlatmada launchctl respawn döngüsü
      (`LaunchAgentInstaller`, `AgentCommand`)
- [ ] Agent singleton kilidi `O_EXCL` ile değil yaz-oku ile alınıyor → TOCTOU yarışı;
      ayrıca ölmüş PID dosyası agent'ın kalıcı olarak "zaten çalışıyor" demesine yol açıyor
      (`StatusItemController.acquireSingleton`)
- [ ] `remove --purge` için onay/yedek yok; tek komut ~500 MB + oturumları siliyor
- [ ] `ProfileSeeder.seed(instanceName:workdir:)` ölü kod
- [ ] `StatusItemController.refresh()` `statusItems` sözlüğünü iterasyon sırasında
      değiştiriyor (bugün güvenli, kırılgan) ve her 5 saniyede tüm menüleri yeniden
      kuruyor (UI gereksiz titreme)

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
- [ ] **`claude://` handler çakışması.** Derin bağlantı tek instance'a gidiyor; ölçüm
      (hangi instance'a gittiği) hâlâ yapılmadı → §1.1/§1.3 ile birlikte çözülebilir
- [ ] **Her instance kendi Claude Code CLI'sini indiriyor** (~525 MB, instance başına).
      Paylaşım (symlink) veya "tek CLI, çok config dir" modu araştırılabilir

---

## 4. Altyapı ve bakım

- [ ] CI: `swift test`'in yanına **macOS 13** (Ventura, `open --env`'in minimum sürümü)
      üzerinde bir smoke job — `open --env` davranışı sürüme göre değişebilir
- [ ] CI: release iş akışı `xcodebuild` ile universal binary üretiyor ✓; `macos-15`
      runner'ı kullanıyor (arm64 runner sorunu nedeniyle) — runner bulunabilirliği izlenmeli
- [ ] `brew audit --strict` / `brew style` ile formül denetimi
- [ ] Kod imzası ve notarizasyon: dağıtım `brew` üzerinden çalışıyor ama doğrudan
      indirilen binary imzasız — imzalı/notarize sürüm üretilmeli mi?
- [ ] Çoklu mimi test: `swift test` yalnızca arm64'de koşuyor; `x86_64` (Intel) için
      ayrı doğrulama
- [ ] `doctor` çıktısı JSON şeması sürümlensin (ileride otomasyon için)
