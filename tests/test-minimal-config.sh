#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SBOX_REALITY_TEST_MODE=1
# Install entry point: a fresh config should contain only selected inbounds.
(
  set --
  source "$ROOT/install.sh"
  selected_inbounds_json() { printf '[{"type":"mixed","tag":"test-in","listen":"127.0.0.1","listen_port":24567}]'; }
  write_fresh_server_config "$TMP/fresh.json"
)
jq -e 'keys == ["inbounds"] and .inbounds[0].tag == "test-in"' "$TMP/fresh.json" >/dev/null
# Merge must not invent outbounds, and must preserve custom routing.
(
  set --
  source "$ROOT/install.sh"
  SERVER_CONF="$TMP/merge.json"
  CONFIG_POLICY=merge
  WARP_INSTALL_ACTIVE=0
  begin_install_transaction() { :; }
  run_sing_box() { if [[ -n "${SING_BOX_TEST_BIN:-}" ]]; then "$SING_BOX_TEST_BIN" "$@"; else return 0; fi; }
  selected_inbounds_json() { printf '[]'; }
  printf '{"inbounds":[],"route":{"rules":[]}}' > "$SERVER_CONF"
  write_server_config
  jq -e 'has("outbounds") | not' "$SERVER_CONF" >/dev/null
  jq -e '.route == {rules:[]}' "$SERVER_CONF" >/dev/null
)
# Exercise manager rendering without executing its CLI entry point.
(
  # shellcheck disable=SC1090
  source <(sed '$d' "$ROOT/sbox-manager.sh")
  SERVER_CONF="$TMP/manager.json"
  printf '{"schema":1,"nodes":[]}' > "$TMP/nodes.json"
  render_server_config "$TMP/nodes.json" "$TMP/generated.json"
  jq -e 'keys == ["inbounds"]' "$TMP/generated.json" >/dev/null
  cp "$TMP/fresh.json" "$SERVER_CONF"
  render_server_config "$TMP/nodes.json" "$TMP/generated.json"
  jq -e 'keys == ["inbounds"] and .inbounds[0].tag == "test-in"' "$TMP/generated.json" >/dev/null
  printf '{"inbounds":[],"outbounds":[{"type":"direct","tag":"custom"}],"route":{"final":"custom"}}' > "$SERVER_CONF"
  render_server_config "$TMP/nodes.json" "$TMP/generated.json"
  jq -e '.outbounds == [{type:"direct",tag:"custom"}] and .route.final == "custom"' "$TMP/generated.json" >/dev/null
)
# WARP added to a minimal config must be removable without leaving scaffolding.
(
  set --
  source "$ROOT/install.sh"
  printf '{"config":{"client_id":"AQID","interface":{"addresses":{"v4":"172.16.0.2/32","v6":"2606:4700:110:8765::2/128"}}}}' > "$TMP/registration.json"
  key="$(head -c 32 /dev/zero | base64 | tr -d '\n')"
  warp_parse_registration_response "$TMP/registration.json" "$key" "$key" "$TMP/credentials"
  warp_merge_config "$TMP/fresh.json" "$TMP/credentials" '["youtube"]' "$TMP/warp.json"
  jq -e '
    keys == ["endpoints","inbounds","outbounds","route"]
    and .endpoints[0].type == "wireguard"
    and .outbounds == [{type:"direct",tag:"sbox-warp-direct",connect_timeout:"15s"}]
    and .route.rule_set[0].http_client.detour == "sbox-warp-direct"
    and (.route.rule_set[0] | has("download_detour") | not)
  ' "$TMP/warp.json" >/dev/null
  if [[ -n "${SING_BOX_TEST_BIN:-}" ]]; then
    "$SING_BOX_TEST_BIN" check -c "$TMP/warp.json"
  fi
  warp_remove_config "$TMP/warp.json" "$TMP/off.json"
  diff -u <(jq -S . "$TMP/fresh.json") <(jq -S . "$TMP/off.json")
)
if [[ -n "${SING_BOX_TEST_BIN:-}" ]]; then
  "$SING_BOX_TEST_BIN" check -c "$TMP/fresh.json"
fi
printf 'PASS: minimal server configuration\n'
