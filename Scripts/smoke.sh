#!/usr/bin/env bash
#
# Canlı uçtan uca doğrulama.
#
# Gerçek Claude Desktop instance'ları başlatır, profillerin ayrıştığını doğrular
# ve tüm adımları temizler. Kullanıcının makinelerinde Claude kurulu olmalıdır.
#
# Kullanım: ./Scripts/smoke.sh

set -uo pipefail

cd "$(dirname "$0")/.."

BIN=".build/release/claude-ctl"
if [ ! -x "$BIN" ]; then
    echo ">> binary yok, derleniyor..."
    swift build -c release || exit 1
fi

WORK="$(mktemp -d)"
SMOKE_NAME="smoke-$$"
SMOKE2_NAME="smoke2-$$"
FAILURES=0

cleanup() {
    "$BIN" stop "$SMOKE_NAME" >/dev/null 2>&1 || true
    "$BIN" stop "$SMOKE2_NAME" >/dev/null 2>&1 || true
    "$BIN" remove "$SMOKE_NAME" --purge --permanent --yes >/dev/null 2>&1 || true
    "$BIN" remove "$SMOKE2_NAME" --purge --permanent --yes >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

step() { printf '\n== %s ==\n' "$1"; }
ok()   { printf '   ok    %s\n' "$1"; }
fail() { printf '   HATA  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

profile_dir() {
    echo "$HOME/Library/Application Support/claude-ctl/instances/$1/profile"
}

json_field() {
    # $1: json, $2: instance adı, $3: alan
    printf '%s' "$1" | python3 -c "
import json,sys
data = json.load(sys.stdin)
for item in data.get('instances', []):
    if item.get('name') == '$2':
        print(item.get('$3'))
        break
"
}

step "new"
if "$BIN" new "$SMOKE_NAME" --workdir "$WORK" >/dev/null 2>&1; then
    ok "instance oluşturuldu: $SMOKE_NAME"
else
    fail "new başarısız"
fi

step "start"
if "$BIN" start "$SMOKE_NAME" >/dev/null 2>&1; then
    ok "instance başlatıldı"
else
    fail "start başarısız"
fi
sleep 12

step "profil ayrışması"
PROFILE1="$(profile_dir "$SMOKE_NAME")"
if [ -f "$PROFILE1/Cookies" ]; then
    ok "profil ayrı: $PROFILE1/Cookies"
else
    fail "profil dizininde Cookies yok"
fi

step "Claude Code yapılandırması ayrışması"
CODE1="$HOME/Library/Application Support/claude-ctl/instances/$SMOKE_NAME/claude-code"
if [ -d "$CODE1" ]; then
    ok "ayrı CLAUDE_CONFIG_DIR: $CODE1"
else
    fail "claude-code dizini oluşmadı"
fi
# Not: Claude Code CLI, instance giriş yapılana kadar spawn olmayabilir; bu
# durumda dizin boş kalır (beklenen). Doluysa ayrışma doğrulanmış olur.
if [ -n "$(ls -A "$CODE1" 2>/dev/null)" ]; then
    ok "Claude Code yapılandırması instance dizininde"
else
    ok "Claude Code dizini boş (CLI henüz çalışmadı — giriş sonrası dolar)"
fi

step "list --json"
LIST_JSON="$("$BIN" list --json 2>/dev/null)"
RUNNING="$(json_field "$LIST_JSON" "$SMOKE_NAME" isRunning)"
if [ "$RUNNING" = "True" ]; then
    ok "list isRunning=true"
else
    fail "list isRunning=$RUNNING"
fi

step "status"
if "$BIN" status "$SMOKE_NAME" >/dev/null 2>&1; then
    ok "status çalıştı"
else
    fail "status başarısız"
fi

step "doctor"
DOCTOR_OUT="$("$BIN" doctor "$SMOKE_NAME" 2>&1)"
if echo "$DOCTOR_OUT" | grep -q "claude-app"; then
    ok "doctor çalıştı"
else
    fail "doctor çıktısı bekleneni içermiyor"
fi

step "logs"
if "$BIN" logs "$SMOKE_NAME" -n 5 >/dev/null 2>&1; then
    ok "logs çalıştı"
else
    fail "logs başarısız"
fi

step "stop"
if "$BIN" stop "$SMOKE_NAME" >/dev/null 2>&1; then
    ok "instance durduruldu"
else
    fail "stop başarısız"
fi
sleep 3
STOPPED_JSON="$("$BIN" list --json 2>/dev/null)"
STOPPED="$(json_field "$STOPPED_JSON" "$SMOKE_NAME" isRunning)"
if [ "$STOPPED" = "False" ]; then
    ok "list isRunning=false"
else
    fail "list isRunning=$STOPPED (false olmalı)"
fi

step "duplicate reddi"
if "$BIN" new "$SMOKE_NAME" --workdir "$WORK" >/dev/null 2>&1; then
    fail "duplicate ad kabul edildi"
else
    ok "duplicate ad reddedildi"
fi

step "geçersiz ad"
"$BIN" new "GEÇERSİZ AD" --workdir "$WORK" >/dev/null 2>&1
if [ $? -eq 2 ]; then
    ok "geçersiz ad exit=2"
else
    fail "geçersiz ad exit=$? (2 olmalı)"
fi

step "eksik --workdir"
"$BIN" new "workdirsuz" >/dev/null 2>&1
if [ $? -eq 2 ]; then
    ok "eksik --workdir exit=2"
else
    fail "eksik --workdir exit=$? (2 olmalı)"
fi

step "iki instance izolasyonu"
"$BIN" new "$SMOKE2_NAME" --workdir "$WORK" >/dev/null 2>&1
"$BIN" start "$SMOKE2_NAME" >/dev/null 2>&1
sleep 12
PROFILE2="$(profile_dir "$SMOKE2_NAME")"
if [ -f "$PROFILE2/Cookies" ] && [ "$PROFILE1" != "$PROFILE2" ]; then
    ok "iki ayrı profil: $PROFILE1 ve $PROFILE2"
else
    fail "ikinci profil oluşmadı veya dizinler aynı"
fi
if [ -f "$PROFILE1/Cookies" ] && [ -f "$PROFILE2/Cookies" ]; then
    INODE1="$(stat -f %i "$PROFILE1/Cookies")"
    INODE2="$(stat -f %i "$PROFILE2/Cookies")"
    if [ "$INODE1" != "$INODE2" ]; then
        ok "cookie veritabanları ayrı dosyalar"
    else
        fail "cookie veritabanları aynı dosya (inode $INODE1)"
    fi
fi
"$BIN" stop "$SMOKE2_NAME" >/dev/null 2>&1 || true

printf '\n== sonuç ==\n'
if [ "$FAILURES" -eq 0 ]; then
    echo "tüm adımlar geçti"
    exit 0
fi
echo "$FAILURES adım başarısız"
exit 1
