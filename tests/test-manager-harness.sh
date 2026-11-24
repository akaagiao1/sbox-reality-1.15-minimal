#!/usr/bin/env bash
# sbox-manager 按用户管理 + V2Ray API 统计 + 30 天周期 + 自动踢人 的 harness 测试。
# 用 mock grpcurl（返回可控的累计流量）和 mock systemctl（重启为 no-op），
# 不需要真实 sing-box 服务、不发真实 Telegram。
# 要求：sing-box 二进制（SING_BOX_BIN，默认 /usr/local/bin/sing-box）用于 check 渲染出的配置；
# 未提供时跳过 check，只验证状态文件与渲染结果的 JSON 结构。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MGR="$ROOT/sbox-manager.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STATE="$TMP/state"; CLIENTS="$TMP/clients"; CONF="$TMP/server-config.json"
mkdir -p "$STATE/traffic" "$CLIENTS" "$TMP/bin"

# --- mock grpcurl：按 $MOCK_STATS_FILE 返回累计流量 ---
cat > "$TMP/bin/grpcurl" << 'MOCK_EOF'
#!/usr/bin/env bash
if [[ -n "${MOCK_STATS_FILE:-}" && -s "$MOCK_STATS_FILE" ]]; then
  python3 -c "
import json
stats = json.load(open('$MOCK_STATS_FILE'))
out = {'stat': []}
for user, total in stats.items():
    out['stat'].append({'name': f'user>>>{user}>>>traffic>>>uplink', 'value': str(total // 2)})
    out['stat'].append({'name': f'user>>>{user}>>>traffic>>>downlink', 'value': str(total - total // 2)})
print(json.dumps(out))
"
else
  echo '{}'
fi
MOCK_EOF
chmod +x "$TMP/bin/grpcurl"

# --- mock systemctl：重启为 no-op ---
cat > "$TMP/bin/systemctl" << 'SYS_EOF'
#!/usr/bin/env bash
exit 0
SYS_EOF
chmod +x "$TMP/bin/systemctl"

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
export MOCK_STATS_FILE="$TMP/stats.json"
export PATH="$TMP/bin:$PATH"

PASS=0; FAIL=0
check() { # check <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $label";
  else FAIL=$((FAIL+1)); echo "FAIL - $label"; fi
}
jq_field() { jq -r "$2" "$1"; }

echo '{"alice": 0}' > "$MOCK_STATS_FILE"

# 1. 添加用户
bash "$MGR" user add alice --quota 1G >/dev/null
check "user add 创建用户" test "$(jq -r '.users[0].id' "$STATE/users.json")" = "alice"
check "user add 额度 1G" test "$(jq -r '.users[0].quota_bytes' "$STATE/users.json")" = "1073741824"
check "user add 生成流量状态" test -s "$STATE/traffic/state.json"

# 2. 渲染配置：三个入站都有 alice，且 sing-box check 通过（有二进制时）
check "渲染配置包含 alice（ss）" jq -e '.inbounds[0].users[0].name == "alice"' "$CONF"
check "渲染配置包含 alice（vless）" jq -e '.inbounds[1].users[0].name == "alice"' "$CONF"
check "渲染配置包含 alice（snell）" jq -e '.inbounds[2].users[0].name == "alice"' "$CONF"
check "渲染配置含 v2ray_api" jq -e '.experimental.v2ray_api.stats.users[0] == "alice"' "$CONF"
if command -v "$SING_BOX_BIN" >/dev/null 2>&1; then
  check "渲染配置通过 sing-box check" "$SING_BOX_BIN" check -c "$CONF"
fi

# 3. ss 客户端密码须为 server:user（冒号连接）
SS_PASS="$(jq -r '.outbounds[0].password' "$CLIENTS/alice/sing-box.json")"
check "ss 客户端密码为 server:user" bash -c "[[ \"$SS_PASS\" == *:* ]]"

# 4. 500MB 流量累计，不踢
echo '{"alice": 524288000}' > "$MOCK_STATS_FILE"
bash "$MGR" traffic check >/dev/null
check "500MB 累计正确" test "$(jq -r '.alice.used_bytes' "$STATE/traffic/state.json")" = "524288000"
check "500MB 未踢" test "$(jq -r '.alice.paused_reasons | length' "$STATE/traffic/state.json")" = "0"

# 5. 超 1G 额度，自动踢人
echo '{"alice": 1288490188}' > "$MOCK_STATS_FILE"
bash "$MGR" traffic check >/dev/null
check "超额后 paused_reasons=quota" test "$(jq -r '.alice.paused_reasons[0]' "$STATE/traffic/state.json")" = "quota"
check "超额后配置去掉 alice" test "$(jq -r '.inbounds[0].users | length' "$CONF")" = "0"

# 6. 流量重置，立即恢复
bash "$MGR" traffic reset alice >/dev/null
check "重置后 used=0" test "$(jq -r '.alice.used_bytes' "$STATE/traffic/state.json")" = "0"
check "重置后 paused 清空" test "$(jq -r '.alice.paused_reasons | length' "$STATE/traffic/state.json")" = "0"
check "重置后配置恢复 alice" test "$(jq -r '.inbounds[0].users | length' "$CONF")" = "1"

# 7. 手动暂停 / 恢复
bash "$MGR" traffic pause alice >/dev/null
check "暂停后配置去掉 alice" test "$(jq -r '.inbounds[0].users | length' "$CONF")" = "0"
bash "$MGR" traffic resume alice >/dev/null
check "恢复后配置恢复 alice" test "$(jq -r '.inbounds[0].users | length' "$CONF")" = "1"

# 8. 30 天周期重置
NOW="$(date +%s)"; OLD=$((NOW - 31*86400))
jq --argjson old "$OLD" '.alice.cycle_start = $old | .alice.used_bytes = 838860800 | .alice.last_counter_bytes = 838860800' \
  "$STATE/traffic/state.json" > "$TMP/state.tmp" && mv "$TMP/state.tmp" "$STATE/traffic/state.json"
jq --argjson old "$OLD" '.users[0].cycle_start = $old' "$STATE/users.json" > "$TMP/users.tmp" && mv "$TMP/users.tmp" "$STATE/users.json"
echo '{"alice": 838860800}' > "$MOCK_STATS_FILE"
bash "$MGR" traffic check >/dev/null
check "30 天后 used 清零" test "$(jq -r '.alice.used_bytes' "$STATE/traffic/state.json")" = "0"

# 9. 到期踢人
PAST=$((NOW - 86400))
jq --argjson past "$PAST" '.users[0].expires_at = $past' "$STATE/users.json" > "$TMP/users.tmp" && mv "$TMP/users.tmp" "$STATE/users.json"
echo '{"alice": 100}' > "$MOCK_STATS_FILE"
bash "$MGR" traffic check >/dev/null
check "到期后 paused_reasons=expired" test "$(jq -r '.alice.paused_reasons[0]' "$STATE/traffic/state.json")" = "expired"
check "到期后配置去掉 alice" test "$(jq -r '.inbounds[0].users | length' "$CONF")" = "0"

echo
echo "通过 $PASS，失败 $FAIL"
[[ "$FAIL" == "0" ]]
