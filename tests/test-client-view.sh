#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SBOX_MANAGER_TEST_MODE=1
export SBOX_STATE_DIR_OVERRIDE="$TMP/state"
export SBOX_CLIENTS_ROOT_OVERRIDE="$TMP/clients"
export SBOX_SERVER_CONF_OVERRIDE="$TMP/config.json"
# shellcheck disable=SC1090
source <(sed '$d' "$ROOT/sbox-manager.sh")
init_state
cat > "$NODES_FILE" <<'JSON'
{"schema":1,"nodes":[
 {"id":"alice-snell6","customer":"alice","protocol":"snell6","port":24567,"enabled":true,"quota_bytes":0,"expires_at":0},
 {"id":"bob-vless","customer":"bob","protocol":"vless","port":24568,"enabled":true,"quota_bytes":0,"expires_at":0},
 {"id":"relay","customer":"bob","protocol":"direct","port":24569,"target_address":"1.1.1.1","target_port":443,"enabled":true,"quota_bytes":0,"expires_at":0}
]}
JSON
mkdir -p "$CLIENTS_ROOT/alice-snell6" "$CLIENTS_ROOT/bob-vless"
printf '{"outbounds":[{"type":"snell","psk":"alice-test-key"}]}' > "$CLIENTS_ROOT/alice-snell6/sing-box.json"
printf 'Alice=snell,example.com,24567,psk="alice-test-key",version=6\n' > "$CLIENTS_ROOT/alice-snell6/surge.conf"
printf 'snell://alice-test-key@example.com:24567\n' > "$CLIENTS_ROOT/alice-snell6/url.txt"
printf '{"outbounds":[{"type":"vless","uuid":"bob-test-uuid"}]}' > "$CLIENTS_ROOT/bob-vless/sing-box.json"
printf 'vless://bob-test-uuid@example.com:24568\n' > "$CLIENTS_ROOT/bob-vless/url.txt"
PASS=0
assert_contains() {
  grep -Fq -- "$2" "$1" || { printf 'FAIL: missing %s\n' "$3" >&2; exit 1; }
  PASS=$((PASS + 1))
}
cmd_node_list > "$TMP/list"
assert_contains "$TMP/list" 'node clients' 'CLI configuration viewing hint'
# Reading saved credentials must not call the generator.
write_client_files() { echo 'FAIL: viewing saved files regenerated credentials' >&2; return 1; }
cmd_node_clients alice-snell6 > "$TMP/view"
assert_contains "$TMP/view" 'Alice=snell,example.com,24567' 'Surge config'
assert_contains "$TMP/view" '"psk":"alice-test-key"' 'sing-box config'
assert_contains "$TMP/view" 'snell://alice-test-key' 'share URL'
if grep -Fq 'bob-test-uuid' "$TMP/view"; then echo 'FAIL: another customer leaked' >&2; exit 1; fi
PASS=$((PASS + 1))
cmd_node_clients bob-vless > "$TMP/vless"
assert_contains "$TMP/vless" 'Surge 不支持' 'unsupported protocol explanation'
assert_contains "$TMP/vless" 'bob-test-uuid' 'VLESS sing-box config'
cmd_node_clients relay > "$TMP/direct"
assert_contains "$TMP/direct" '1.1.1.1:443' 'Direct target'
# The real CLI must print configuration contents too.
bash "$ROOT/sbox-manager.sh" node clients alice-snell6 > "$TMP/cli"
assert_contains "$TMP/cli" 'alice-test-key' 'CLI config contents'
# Choose a user from the actual menu, then return to it and quit.
printf '2\n1\n0\n0\n' | bash "$ROOT/sbox-manager.sh" menu > "$TMP/menu"
assert_contains "$TMP/menu" 'Alice=snell,example.com,24567' 'menu config selection'
assert_contains "$TMP/menu" 'alice-test-key' 'menu sing-box config'
printf 'PASS: %s assertions (client config viewing)\n' "$PASS"
