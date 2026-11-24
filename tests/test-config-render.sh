#!/usr/bin/env bash
# 渲染配置测试：空用户 / 单用户 / 被踢用户 不进配置；渲染结果须通过 sing-box check。
# 需要 SING_BOX_BIN（默认 /usr/local/bin/sing-box）；未提供时只做 JSON 结构断言。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MGR="$ROOT/sbox-manager.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"; CLIENTS="$TMP/clients"; CONF="$TMP/server-config.json"
mkdir -p "$STATE/traffic" "$CLIENTS" "$TMP/bin"
cat > "$TMP/bin/systemctl" << 'SYS_EOF'
#!/usr/bin/env bash
exit 0
SYS_EOF
chmod +x "$TMP/bin/systemctl"
cat > "$TMP/bin/grpcurl" << 'MOCK_EOF'
#!/usr/bin/env bash
echo '{}'
MOCK_EOF
chmod +x "$TMP/bin/grpcurl"
cat > "$STATE/users.json" << 'USERS_EOF'
{
  "version": 1,
  "server": {
    "ss_port": 18001, "vless_port": 18002, "snell_port": 18003,
    "reality_domain": "www.apple.com",
    "reality_private_key": "GBP9apYm51voxbr0eZHzinDxbIrkuDAK7YeYNukLL1U",
    "reality_public_key": "ci1o_amGAJp_7Mm_zAaXSgJHRvcUy1HdT1TVRiqTWDc",
    "reality_short_id": "ae5e997988324f7f",
    "v2ray_api_port": 18000,
    "snell_psk": "gQogN6bCqXSBE7jjMYObWA==",
    "ss_password": "aK32Dpx5jXTVZz37PPD+wg=="
  },
  "users": []
}
USERS_EOF
export SBOX_MANAGER_TEST_MODE=1
export SBOX_STATE_DIR_OVERRIDE="$STATE"
export SBOX_CLIENTS_ROOT_OVERRIDE="$CLIENTS"
export SBOX_SERVER_CONF_OVERRIDE="$CONF"
export SING_BOX_BIN="${SING_BOX_BIN:-/usr/local/bin/sing-box}"
export GRPCURL_BIN="$TMP/bin/grpcurl"
export PATH="$TMP/bin:$PATH"
PASS=0; FAIL=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $label";
  else FAIL=$((FAIL+1)); echo "FAIL - $label"; fi
}
check_config() {
  local label="$1"
  if command -v "$SING_BOX_BIN" >/dev/null 2>&1; then
    check "$label（sing-box check）" "$SING_BOX_BIN" check -c "$CONF"
  else
    check "$label（JSON 可解析）" jq -e . "$CONF"
  fi
}

# 空用户：三个入站 users 为空数组，v2ray_api users 为空
bash "$MGR" internal render >/dev/null
check "空用户 ss users 为空" test "$(jq -r '.inbounds[0].users | length' "$CONF")" = "0"
check "空用户 vless users 为空" test "$(jq -r '.inbounds[1].users | length' "$CONF")" = "0"
check "空用户 snell users 为空" test "$(jq -r '.inbounds[2].users | length' "$CONF")" = "0"
check_config "空用户配置"

# 加 alice 与 bob：都在三个入站
bash "$MGR" user add alice --quota 100G >/dev/null
bash "$MGR" user add bob --quota 0 >/dev/null
check "两用户 ss 都有" test "$(jq -r '.inbounds[0].users | length' "$CONF")" = "2"
check "v2ray_api users 含两人" test "$(jq -r '.experimental.v2ray_api.stats.users | length' "$CONF")" = "2"
check_config "两用户配置"

# 手动暂停 bob：bob 不进配置，alice 还在
bash "$MGR" traffic pause bob >/dev/null
check "暂停后 ss 只剩 alice" test "$(jq -r '.inbounds[0].users[0].name' "$CONF")" = "alice"
check "暂停后 ss 只有 1 人" test "$(jq -r '.inbounds[0].users | length' "$CONF")" = "1"
check_config "暂停后配置"

# 删 bob：彻底消失
bash "$MGR" user remove bob >/dev/null
check "删除后 users 只剩 alice" test "$(jq -r '.users | length' "$STATE/users.json")" = "1"
check_config "删除后配置"

echo
echo "通过 $PASS，失败 $FAIL"
[[ "$FAIL" == "0" ]]
