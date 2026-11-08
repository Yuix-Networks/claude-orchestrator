#!/bin/sh
#
# claude-orchestrator kurulum betiği.
#
#   curl -fsSL https://raw.githubusercontent.com/Yuix-Networks/claude-orchestrator/main/install.sh | sh
#
# Ortam değişkenleri:
#   CLAUDE_ORCHESTRATOR_VERSION   Kurulacak sürüm (örn. 0.2.2). Varsayılan: en son sürüm.
#   CLAUDE_ORCHESTRATOR_DIR       Kurulum dizini. Varsayılan: /usr/local/bin yazılabilirse
#                                 orası, değilse ~/.local/bin.
#
# Kaldırmak için:
#   curl -fsSL https://raw.githubusercontent.com/Yuix-Networks/claude-orchestrator/main/install.sh | sh -s -- --uninstall
#
# Betik sudo kullanmaz; yalnızca indirdiği tarball'ın sha256'sı sürümle birlikte
# yayınlanan değerle eşleşirse kurar.

set -eu

REPO="Yuix-Networks/claude-orchestrator"
BINARY="claude-orchestrator"
LEGACY="claude-ctl"

say()  { printf '%s\n' "$*"; }
warn() { printf 'uyarı: %s\n' "$*" >&2; }
die()  { printf 'hata: %s\n' "$*" >&2; exit 1; }

choose_dir() {
    if [ -n "${CLAUDE_ORCHESTRATOR_DIR:-}" ]; then
        printf '%s' "$CLAUDE_ORCHESTRATOR_DIR"
    elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
        printf '%s' /usr/local/bin
    else
        printf '%s' "$HOME/.local/bin"
    fi
}

uninstall() {
    dir="$(choose_dir)"
    removed=0
    for name in "$BINARY" "$LEGACY"; do
        if [ -e "$dir/$name" ] || [ -L "$dir/$name" ]; then
            rm -f "$dir/$name"
            say "silindi: $dir/$name"
            removed=1
        fi
    done
    [ "$removed" -eq 1 ] || say "$dir içinde kurulu $BINARY bulunamadı"
    say "instance verileri korunur: ~/Library/Application Support/claude-ctl/"
    exit 0
}

case "${1:-}" in
    --uninstall) uninstall ;;
    "") ;;
    *) die "bilinmeyen argüman: $1 (yalnızca --uninstall)" ;;
esac

# --- Ön koşullar -------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "claude-orchestrator yalnızca macOS'ta çalışır"

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$macos_major" -ge 13 ] || die "macOS 13 (Ventura) veya üstü gerekli (bu makine: $(sw_vers -productVersion))"

for tool in curl tar shasum; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' bulunamadı"
done

# --- Sürüm -------------------------------------------------------------------

version="${CLAUDE_ORCHESTRATOR_VERSION:-}"
if [ -z "$version" ]; then
    # API yerine yönlendirme kullanılır: GitHub API'nin oturumsuz istek sınırına takılmaz.
    latest_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" \
        || die "en son sürüm öğrenilemedi"
    version="${latest_url##*/}"
fi
version="${version#v}"
case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) die "geçersiz sürüm: '$version'" ;;
esac

archive="$BINARY-$version.tar.gz"
base="https://github.com/$REPO/releases/download/v$version"

# --- İndirme ve doğrulama ----------------------------------------------------

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

say "claude-orchestrator $version indiriliyor…"
curl -fsSL -o "$tmp/$archive" "$base/$archive" || die "indirilemedi: $base/$archive"
curl -fsSL -o "$tmp/$archive.sha256" "$base/$archive.sha256" || die "sağlama toplamı indirilemedi"

expected="$(awk '{print $1}' "$tmp/$archive.sha256")"
actual="$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')"
[ -n "$expected" ] && [ "$expected" = "$actual" ] \
    || die "sha256 uyuşmuyor (beklenen $expected, inen $actual) — kurulum yapılmadı"

tar -xzf "$tmp/$archive" -C "$tmp" "$BINARY" || die "arşiv açılamadı"
chmod 755 "$tmp/$BINARY"
"$tmp/$BINARY" --version >/dev/null 2>&1 || die "indirilen binary bu makinede çalışmadı"

# --- Kurulum -----------------------------------------------------------------

dir="$(choose_dir)"
mkdir -p "$dir" || die "dizin oluşturulamadı: $dir"
[ -w "$dir" ] || die "$dir yazılabilir değil — CLAUDE_ORCHESTRATOR_DIR ile başka bir dizin seç"

if command -v brew >/dev/null 2>&1 && brew list --formula "$BINARY" >/dev/null 2>&1; then
    warn "Homebrew ile de kurulu; PATH sırasına göre hangisinin çalışacağı değişir (brew uninstall $BINARY)"
fi

# Geçici dosyadan atomik yer değiştirme: çalışan bir kopya bozulmaz.
cp "$tmp/$BINARY" "$dir/.$BINARY.new"
mv -f "$dir/.$BINARY.new" "$dir/$BINARY"
ln -sf "$BINARY" "$dir/$LEGACY"

say "kuruldu: $dir/$BINARY ($("$dir/$BINARY" --version))"

case ":$PATH:" in
    *":$dir:"*) ;;
    *)
        warn "$dir PATH'te değil. Kabuk yapılandırmana ekle:"
        say "  echo 'export PATH=\"$dir:\$PATH\"' >> ~/.zshrc && exec zsh"
        ;;
esac

[ -d /Applications/Claude.app ] || warn "Claude Desktop /Applications/Claude.app konumunda bulunamadı"

say ""
say "başlamak için:"
say "  $BINARY new is && $BINARY signin is --exclusive"
say "  $BINARY help"
