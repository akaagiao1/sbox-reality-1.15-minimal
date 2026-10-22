#!/usr/bin/env bash
# JSON fixtures are literal HTTP response bodies, not shell commands.
# shellcheck disable=SC2089,SC2090
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck disable=SC1090
source "$ROOT/sbox-manager.sh"
NOTIFY_ENV="$TMP/notify.env"
printf 'TG_BOT_TOKEN=123456:TEST_ONLY\nTG_CHAT_ID=12345\n' > "$NOTIFY_ENV"
unset SBOX_NOTIFY_DRY_RUN_FILE
PASS=0
FAKE_RESPONSE='{"ok":true,"result":{"message_id":1}}'
FAKE_EXIT=0
FAKE_BAD_CHAT=''
curl() {
  local arg chat=''
  for arg in "$@"; do
    [[ "$arg" != chat_id=* ]] || chat="${arg#chat_id=}"
  done
  if [[ -n "$FAKE_BAD_CHAT" && "$chat" == "$FAKE_BAD_CHAT" ]]; then
    printf '{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}'
    return 22
  fi
  printf '%s' "$FAKE_RESPONSE"
  return "$FAKE_EXIT"
}
expect_result() {
  local expected="$1" label="$2" actual=0
  notify_send 'regression test' 2>"$TMP/stderr" || actual=$?
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s (expected %s, actual %s)\n' "$label" "$expected" "$actual" >&2
    cat "$TMP/stderr" >&2
    exit 1
  fi
  if [[ "$expected" == 0 && -s "$TMP/stderr" ]]; then
    printf 'FAIL: successful response produced an error\n' >&2
    exit 1
  fi
  PASS=$((PASS + 1))
}
expect_result 0 'Telegram ok:true must be reported as success'
FAKE_RESPONSE='{"ok":false,"error_code":403,"description":"Forbidden"}'
FAKE_EXIT=22
expect_result 1 'Telegram HTTP failure must remain a failure'
FAKE_EXIT=0
FAKE_RESPONSE='{"ok":false}'
expect_result 1 'Telegram API rejection must remain a failure'
FAKE_RESPONSE=''
expect_result 1 'empty response must fail'
FAKE_RESPONSE='not json'
expect_result 1 'invalid response must fail'
FAKE_RESPONSE='{"ok":true,"result":{"message_id":1}}'
printf 'TG_BOT_TOKEN=123456:TEST_ONLY\nTG_CHAT_ID=12345,-100999\n' > "$NOTIFY_ENV"
expect_result 0 'all successful recipients must return success'
FAKE_BAD_CHAT=-100999
expect_result 1 'one rejected recipient must return failure'
# Exercise the real CLI with an isolated config and mocked HTTP transport.
FAKE_BAD_CHAT=''
export FAKE_RESPONSE FAKE_EXIT FAKE_BAD_CHAT
export -f curl
if ! env SBOX_MANAGER_TEST_MODE=1 SBOX_STATE_DIR_OVERRIDE="$TMP" \
  bash "$ROOT/sbox-manager.sh" notify test >"$TMP/cli-output" 2>"$TMP/stderr"; then
  printf 'FAIL: notify test CLI rejected a successful Telegram response\n' >&2
  exit 1
fi
[[ -s "$TMP/cli-output" && ! -s "$TMP/stderr" ]]
PASS=$((PASS + 1))
FAKE_RESPONSE='{"ok":false,"error_code":403,"description":"Forbidden"}'
FAKE_EXIT=22
export FAKE_RESPONSE FAKE_EXIT
if env SBOX_MANAGER_TEST_MODE=1 SBOX_STATE_DIR_OVERRIDE="$TMP" \
  bash "$ROOT/sbox-manager.sh" notify test >"$TMP/cli-output" 2>"$TMP/stderr"; then
  printf 'FAIL: notify test CLI accepted a rejected Telegram response\n' >&2
  exit 1
fi
[[ ! -s "$TMP/cli-output" ]]
PASS=$((PASS + 1))
printf 'PASS: %s assertions (Telegram response handling)\n' "$PASS"
