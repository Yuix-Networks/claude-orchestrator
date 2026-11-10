#!/bin/sh
#
# claude-orchestrator installer.
#
#   curl -fsSL https://raw.githubusercontent.com/Yuix-Networks/claude-orchestrator/main/install.sh | sh
#
# Environment variables:
#   CLAUDE_ORCHESTRATOR_VERSION   Version to install (e.g. 0.2.2). Default: the latest release.
#   CLAUDE_ORCHESTRATOR_DIR       Install directory. Default: /usr/local/bin if it is
#                                 writable, otherwise ~/.local/bin.
#
# To uninstall:
#   curl -fsSL https://raw.githubusercontent.com/Yuix-Networks/claude-orchestrator/main/install.sh | sh -s -- --uninstall
#
# The script never uses sudo, and it only installs if the sha256 of the downloaded
# tarball matches the value published with the release.

set -eu

REPO="Yuix-Networks/claude-orchestrator"
BINARY="claude-orchestrator"

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

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
    if [ -e "$dir/$BINARY" ]; then
        rm -f "$dir/$BINARY"
        say "removed: $dir/$BINARY"
    else
        say "no $BINARY installed in $dir"
    fi
    say "instance data is kept: ~/Library/Application Support/claude-ctl/"
    exit 0
}

case "${1:-}" in
    --uninstall) uninstall ;;
    "") ;;
    *) die "unknown argument: $1 (only --uninstall is supported)" ;;
esac

# --- Prerequisites -----------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "claude-orchestrator only runs on macOS"

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$macos_major" -ge 13 ] || die "macOS 13 (Ventura) or later is required (this machine: $(sw_vers -productVersion))"

for tool in curl tar shasum; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found"
done

# --- Version -----------------------------------------------------------------

version="${CLAUDE_ORCHESTRATOR_VERSION:-}"
if [ -z "$version" ]; then
    # Follow the redirect instead of calling the API, so we don't hit the GitHub API's
    # unauthenticated rate limit.
    latest_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" \
        || die "could not determine the latest release"
    version="${latest_url##*/}"
fi
version="${version#v}"
case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) die "invalid version: '$version'" ;;
esac

archive="$BINARY-$version.tar.gz"
base="https://github.com/$REPO/releases/download/v$version"

# --- Download and verify -----------------------------------------------------

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

say "downloading claude-orchestrator ${version}…"
curl -fsSL -o "$tmp/$archive" "$base/$archive" || die "download failed: $base/$archive"
curl -fsSL -o "$tmp/$archive.sha256" "$base/$archive.sha256" || die "could not download the checksum"

expected="$(awk '{print $1}' "$tmp/$archive.sha256")"
actual="$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')"
[ -n "$expected" ] && [ "$expected" = "$actual" ] \
    || die "sha256 mismatch (expected $expected, got $actual); nothing was installed"

tar -xzf "$tmp/$archive" -C "$tmp" "$BINARY" || die "could not extract the archive"
chmod 755 "$tmp/$BINARY"
"$tmp/$BINARY" --version >/dev/null 2>&1 || die "the downloaded binary does not run on this machine"

# --- Install -----------------------------------------------------------------

dir="$(choose_dir)"
mkdir -p "$dir" || die "could not create directory: $dir"
[ -w "$dir" ] || die "$dir is not writable; choose another directory with CLAUDE_ORCHESTRATOR_DIR"

if command -v brew >/dev/null 2>&1 && brew list --formula "$BINARY" >/dev/null 2>&1; then
    warn "also installed with Homebrew; which one runs depends on your PATH order (brew uninstall $BINARY)"
fi

# Atomic replace from a temporary file, so a running copy is not corrupted.
cp "$tmp/$BINARY" "$dir/.$BINARY.new"
mv -f "$dir/.$BINARY.new" "$dir/$BINARY"

say "installed: $dir/$BINARY ($("$dir/$BINARY" --version))"

case ":$PATH:" in
    *":$dir:"*) ;;
    *)
        warn "$dir is not in your PATH. Add it to your shell config:"
        say "  echo 'export PATH=\"$dir:\$PATH\"' >> ~/.zshrc && exec zsh"
        ;;
esac

[ -d /Applications/Claude.app ] || warn "Claude Desktop was not found at /Applications/Claude.app"

say ""
say "to get started:"
say "  $BINARY new work && $BINARY signin work --exclusive"
say "  $BINARY help"
