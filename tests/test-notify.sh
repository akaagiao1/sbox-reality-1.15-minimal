#!/usr/bin/env bash
# Telegram 通知测试：mock curl，验证 notify_send 的请求格式与多 Chat ID 展开。
# 不发真实请求。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MGR="$ROOT/sbox-manager.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"; CLIENTS="$TMP/clients"
mkdir -p "$STATE/traffic" "$CLIENTS" "$TMP/bin"
cat > "$STATE/users.json" << 'USERS_EOF'
{"version": 1, "server": {"ss_port": 18001, "vless_port": 18002, "snell_port": 18003, "reality_domain": "www.apple.com", "reality_private_key": "x", "reality_public_key": "y", "reality_short_id": "ae5e997988324f7f", "v2ray_api_port": 18000, "snell_psk": "z", "ss_password": "w"}, "users": []}
USERS_EOF
export SBOX_MANAGER_TEST_MODE=1
export SBOX_STATE_DIR_OVERRIDE="$STATE"
export SBOX_CLIENTS_ROOT_OVERRIDE="$CLIENTS"
export SBOX_SERVER_CONF_OVERRIDE="$TMP/server-config.json"
export SING_BOX_BIN="${SING_BOX_BIN:-/usr/local/bin/sing-box}"
export PATH="$TMP/bin:$PATH"
PASS=0; FAIL=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $label";
  else FAIL=$((FAIL+1)); echo "FAIL - $label"; fi
}

# mock curl：记录调用参数到 $TMP/curl.log，返回成功
cat > "$TMP/bin/curl" << 'CURL_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$CURL_LOG"
printf '{"ok":true,"result":{"message_id":1}}'
exit 0
CURL_EOF
chmod +x "$TMP/bin/curl"
export CURL_LOG="$TMP/curl.log"

bash "$MGR" notify setup 'TEST_TOKEN_123' '111,222' >/dev/null
check "notify.env 保存 token" grep -q "TEST_TOKEN_123" "$STATE/notify.env"
check "notify.env 权限 600" test "$(stat -c %a "$STATE/notify.env")" = "600"
bash "$MGR" notify test >/dev/null
check "测试消息发给两个 Chat ID" test "$(grep -c 'chat_id=111\|chat_id=222' "$CURL_LOG")" = "2"
check "请求打到 api.telegram.org" grep -q "api.telegram.org/botTEST_TOKEN_123/sendMessage" "$CURL_LOG"

echo
echo "通过 $PASS，失败 $FAIL"
[[ "$FAIL" == "0" ]]
