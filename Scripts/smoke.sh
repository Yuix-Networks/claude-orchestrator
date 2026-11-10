#!/usr/bin/env bash
#
# Live end-to-end check.
#
# Starts real Claude Desktop instances, verifies that their profiles are separate,
# and cleans up after every step. Claude must be installed on the machine.
#
# Usage: ./Scripts/smoke.sh

set -uo pipefail

cd "$(dirname "$0")/.."

BIN=".build/release/claude-orchestrator"
if [ ! -x "$BIN" ]; then
    echo ">> no binary, building..."
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
fail() { printf '   FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

profile_dir() {
    echo "$HOME/Library/Application Support/claude-ctl/instances/$1/profile"
}

json_field() {
    # $1: json, $2: instance name, $3: field
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
    ok "instance created: $SMOKE_NAME"
else
    fail "new failed"
fi

step "start"
if "$BIN" start "$SMOKE_NAME" >/dev/null 2>&1; then
    ok "instance started"
else
    fail "start failed"
fi
sleep 12

step "profile isolation"
PROFILE1="$(profile_dir "$SMOKE_NAME")"
if [ -f "$PROFILE1/Cookies" ]; then
    ok "separate profile: $PROFILE1/Cookies"
else
    fail "no Cookies in the profile directory"
fi

step "Claude Code config isolation"
CODE1="$HOME/Library/Application Support/claude-ctl/instances/$SMOKE_NAME/claude-code"
if [ -d "$CODE1" ]; then
    ok "separate CLAUDE_CONFIG_DIR: $CODE1"
else
    fail "claude-code directory was not created"
fi
# Note: the Claude Code CLI may not be spawned until the instance is signed in; in
# that case the directory stays empty (expected). If it has files, isolation is confirmed.
if [ -n "$(ls -A "$CODE1" 2>/dev/null)" ]; then
    ok "Claude Code config is in the instance directory"
else
    ok "Claude Code directory is empty (CLI has not run yet; it fills after sign in)"
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
    ok "status ran"
else
    fail "status failed"
fi

step "doctor"
DOCTOR_OUT="$("$BIN" doctor "$SMOKE_NAME" 2>&1)"
if echo "$DOCTOR_OUT" | grep -q "claude-app"; then
    ok "doctor ran"
else
    fail "doctor output is missing the expected text"
fi

step "logs"
if "$BIN" logs "$SMOKE_NAME" -n 5 >/dev/null 2>&1; then
    ok "logs ran"
else
    fail "logs failed"
fi

step "stop"
if "$BIN" stop "$SMOKE_NAME" >/dev/null 2>&1; then
    ok "instance stopped"
else
    fail "stop failed"
fi
sleep 3
STOPPED_JSON="$("$BIN" list --json 2>/dev/null)"
STOPPED="$(json_field "$STOPPED_JSON" "$SMOKE_NAME" isRunning)"
if [ "$STOPPED" = "False" ]; then
    ok "list isRunning=false"
else
    fail "list isRunning=$STOPPED (should be false)"
fi

step "duplicate rejection"
if "$BIN" new "$SMOKE_NAME" --workdir "$WORK" >/dev/null 2>&1; then
    fail "duplicate name was accepted"
else
    ok "duplicate name was rejected"
fi

step "invalid name"
"$BIN" new "INVALID NAME" --workdir "$WORK" >/dev/null 2>&1
if [ $? -eq 2 ]; then
    ok "invalid name exit=2"
else
    fail "invalid name exit=$? (should be 2)"
fi

step "--workdir without a value"
"$BIN" new "noworkdir-$$" --workdir >/dev/null 2>&1
if [ $? -eq 2 ]; then
    ok "--workdir without a value exit=2"
else
    fail "--workdir without a value exit=$? (should be 2)"
fi
"$BIN" remove "noworkdir-$$" >/dev/null 2>&1 || true

step "two-instance isolation"
"$BIN" new "$SMOKE2_NAME" --workdir "$WORK" >/dev/null 2>&1
"$BIN" start "$SMOKE2_NAME" >/dev/null 2>&1
sleep 12
PROFILE2="$(profile_dir "$SMOKE2_NAME")"
if [ -f "$PROFILE2/Cookies" ] && [ "$PROFILE1" != "$PROFILE2" ]; then
    ok "two separate profiles: $PROFILE1 and $PROFILE2"
else
    fail "second profile was not created, or the directories are the same"
fi
if [ -f "$PROFILE1/Cookies" ] && [ -f "$PROFILE2/Cookies" ]; then
    INODE1="$(stat -f %i "$PROFILE1/Cookies")"
    INODE2="$(stat -f %i "$PROFILE2/Cookies")"
    if [ "$INODE1" != "$INODE2" ]; then
        ok "cookie databases are separate files"
    else
        fail "cookie databases are the same file (inode $INODE1)"
    fi
fi
"$BIN" stop "$SMOKE2_NAME" >/dev/null 2>&1 || true

step "session transfer"
# Write a fake Claude Code session into the first instance and move it to the second.
SID="smoke-session-$$"
PROJ="$CODE1/projects/-tmp-smoke"
mkdir -p "$PROJ"
printf '%s\n' \
  "{\"type\":\"user\",\"cwd\":\"/tmp/smoke\",\"sessionId\":\"$SID\",\"timestamp\":\"2026-11-08T10:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}" \
  > "$PROJ/$SID.jsonl"
"$BIN" stop "$SMOKE2_NAME" >/dev/null 2>&1 || true
if "$BIN" session move "$SID" --to "$SMOKE2_NAME" >/dev/null 2>&1 \
   && "$BIN" session show "$SID" --instance "$SMOKE2_NAME" >/dev/null 2>&1 \
   && [ ! -e "$PROJ/$SID.jsonl" ]; then
    ok "session moved and is visible in the target"
else
    fail "session could not be moved"
fi
rm -rf "$HOME/Library/Application Support/claude-ctl/backups/"*"-$SID"

printf '\n== result ==\n'
if [ "$FAILURES" -eq 0 ]; then
    echo "all steps passed"
    exit 0
fi
echo "$FAILURES step(s) failed"
exit 1
