#!/usr/bin/env bash
# sbox-node / sbox-traffic -- 多用户合租节点管理（重构版）
#
# 架构：sing-box（源码编译，with_v2ray_api）按用户统计流量；
# 定时脚本（sbox-traffic check，每 5 分钟）管到期、算累计流量、
# 发 Telegram 提醒、自动踢人。协议：ss / VLESS+Reality / Snell v6。
# 周期固定 30 天，流量按 GB。
#
# 用法（sbox-node）：
#   sbox-node user add <name> --quota 100G --expires 2026-12-31
#   sbox-node user remove <name>
#   sbox-node user list
#   sbox-node user clients <name>
#   sbox-node user set <name> --quota 200G [--expires 2027-03-31]
#   sbox-node traffic show
#   sbox-node traffic set <name> --quota 200G
#   sbox-node traffic reset <name>
#   sbox-node traffic pause <name> / resume <name>
#   sbox-node notify setup <token> <chat_id,...>
#   sbox-node notify test
#   sbox-node internal render
# 用法（sbox-traffic）：sbox-traffic check（定时器调用）
set -euo pipefail
umask 077

STATE_DIR="/etc/sbox-reality"
USERS_FILE="$STATE_DIR/users.json"
TRAFFIC_DIR="$STATE_DIR/traffic"
TRAFFIC_STATE="$TRAFFIC_DIR/state.json"
NOTIFY_ENV="$STATE_DIR/notify.env"
SERVER_HOST_FILE="$STATE_DIR/server-host"
CLIENTS_ROOT="/root/sbox-reality/clients"
SERVER_CONF="/etc/sing-box/config.json"
TIMEZONE="Asia/Shanghai"
CYCLE_DAYS=30
CYCLE_SECONDS=$((CYCLE_DAYS * 86400))

if [[ "${SBOX_MANAGER_TEST_MODE:-0}" == "1" ]]; then
  STATE_DIR="${SBOX_STATE_DIR_OVERRIDE:-$STATE_DIR}"
  USERS_FILE="$STATE_DIR/users.json"
  TRAFFIC_DIR="$STATE_DIR/traffic"
  TRAFFIC_STATE="$TRAFFIC_DIR/state.json"
  NOTIFY_ENV="$STATE_DIR/notify.env"
  SERVER_HOST_FILE="$STATE_DIR/server-host"
  CLIENTS_ROOT="${SBOX_CLIENTS_ROOT_OVERRIDE:-$CLIENTS_ROOT}"
  SERVER_CONF="${SBOX_SERVER_CONF_OVERRIDE:-$SERVER_CONF}"
fi

SING_BOX_BIN="${SING_BOX_BIN:-/usr/local/bin/sing-box}"
GRPCURL_BIN="${GRPCURL_BIN:-/usr/local/bin/grpcurl}"
LOCK_FILE="$STATE_DIR/.lock"

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
warn() { printf '警告：%s\n' "$*" >&2; }

require_root() { [[ ${EUID:-0} -eq 0 ]] || die "请使用 root 运行"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

validate_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]]
}

# 流量额度解析：支持 100 / 100G / 100GB / 1.5T 等，0 = 不限。输出字节数。
gb_to_bytes() {
  local value="$1"
  awk -v v="$value" '
    BEGIN {
      if (v !~ /^[0-9]+([.][0-9]+)?([KMGTP]i?B?|B)?$/) exit 1
      unit = v
      sub(/^[0-9]+([.][0-9]+)?/, "", unit)
      num = v
      sub(/([KMGTP]i?B?|B)$/, "", num)
      mult = 1
      if (unit ~ /^K/) mult = 1024
      else if (unit ~ /^M/) mult = 1024 * 1024
      else if (unit ~ /^G/) mult = 1024 * 1024 * 1024
      else if (unit ~ /^T/) mult = 1024 * 1024 * 1024 * 1024
      else if (unit ~ /^P/) mult = 1024 * 1024 * 1024 * 1024 * 1024
      bytes = num * mult
      if (bytes > 9007199254740991 || (num > 0 && bytes < 1)) exit 1
      printf "%.0f\n", bytes
    }
  ' 2>/dev/null
}

format_bytes() {
  local bytes="${1:-0}"
  awk -v b="$bytes" '
    BEGIN {
      split("B KB MB GB TB PB", u, " ")
      i = 1
      while (b >= 1024 && i < 6) { b /= 1024; i++ }
      if (i == 1) printf "%.0f%s", b, u[i]
      else printf "%.2f%s", b, u[i]
    }
  '
}

format_gb() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN { printf "%.2f", b / 1024 / 1024 / 1024 }'
}

parse_expiry_epoch() {
  local value="$1"
  [[ -n "$value" ]] || { printf '0'; return; }
  if [[ "$value" =~ ^[0-9]+$ ]]; then printf '%s' "$value"; return; fi
  [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && value="$value 23:59:59"
  TZ="$TIMEZONE" date -d "$value" +%s 2>/dev/null \
    || die "无法解析到期时间：$1（用 YYYY-MM-DD 或 YYYY-MM-DD HH:MM:SS）"
}

format_time() {
  local epoch="${1:-0}"
  (( epoch > 0 )) || { printf '未设置'; return; }
  TZ="$TIMEZONE" date -d "@$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$epoch"
}

acquire_lock() {
  require_cmd flock
  mkdir -p "$STATE_DIR"
  exec 9>"$LOCK_FILE"
  flock -w 60 9 || die "等待状态锁超时"
}

with_state_lock() (
  acquire_lock
  init_state
  "$@"
)

init_state() {
  mkdir -p "$STATE_DIR" "$TRAFFIC_DIR" "$CLIENTS_ROOT"
  [[ -s "$USERS_FILE" ]] || die "用户状态文件不存在：$USERS_FILE（请先运行 install.sh --setup）"
  [[ -s "$TRAFFIC_STATE" ]] || printf '{}\n' > "$TRAFFIC_STATE"
}

server_field() {
  jq -r --arg f "$1" '.server[$f]' "$USERS_FILE"
}

user_json_by_id() {
  jq -c --arg id "$1" '.users[] | select(.id == $id)' "$USERS_FILE" 2>/dev/null | head -n 1
}

user_exists() {
  [[ -n "$(user_json_by_id "$1")" ]]
}

server_host() {
  if [[ -s "$SERVER_HOST_FILE" ]]; then
    cat "$SERVER_HOST_FILE"
    return 0
  fi
  local host
  host="$(curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$host" ]]; then printf '%s' "$host"; return 0; fi
  hostname -f 2>/dev/null || hostname
}

url_encode() {
  local s="$1" i c out=""
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

b64url() {
  base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '='
}

# ---------- 服务端配置渲染 ----------
# 只把“可用”用户写进三个入站的 users：
#   手动暂停（users[].paused=true）或被定时脚本踢掉（traffic state 里
#   paused_reasons 非空）的用户不写进配置，重启后即断开。
# 返回 0 表示配置有变化（调用方据此决定是否重启），1 表示无变化。
render_server_config() {
  init_state
  local tmp new_hash old_hash
  tmp="$(mktemp)"
  jq --slurpfile traffic "$TRAFFIC_STATE" '
    . as $root
    | ($root.server) as $s
    | ([$root.users[] | select(
        (.paused // false) != true
        and (($traffic[0][.id].paused_reasons // []) | length == 0)
      )]) as $active
    | {
        log: {level: "warn", timestamp: true},
        dns: {servers: [{type: "local", tag: "local", detour: "direct"}]},
        inbounds: [
          {
            type: "shadowsocks", tag: "ss-in",
            listen: "0.0.0.0", listen_port: $s.ss_port,
            method: "2022-blake3-aes-128-gcm",
            password: $s.ss_password,
            users: [$active[] | {name: .id, password: .ss_password}]
          },
          {
            type: "vless", tag: "vless-in",
            listen: "0.0.0.0", listen_port: $s.vless_port,
            users: [$active[] | {name: .id, uuid: .vless_uuid, flow: "xtls-rprx-vision"}],
            tls: {
              enabled: true,
              server_name: $s.reality_domain,
              reality: {
                enabled: true,
                handshake: {server: $s.reality_domain, server_port: 443},
                private_key: $s.reality_private_key,
                short_id: [$s.reality_short_id]
              }
            }
          },
          {
            type: "snell", tag: "snell-in",
            listen: "0.0.0.0", listen_port: $s.snell_port,
            version: 6,
            psk: $s.snell_psk,
            users: [$active[] | {name: .id, userkey: .snell_userkey}],
            mode: "default"
          }
        ],
        outbounds: [{type: "direct", tag: "direct"}],
        experimental: {
          v2ray_api: {
            listen: ("127.0.0.1:" + ($s.v2ray_api_port | tostring)),
            stats: {
              enabled: true,
              inbounds: ["ss-in", "vless-in", "snell-in"],
              users: [$root.users[].id]
            }
          }
        }
      }
  ' "$USERS_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }

  # 校验：配置非法直接报错，不覆盖线上配置
  if ! "$SING_BOX_BIN" check -c "$tmp" >/dev/null 2>&1; then
    warn "生成的配置未通过 sing-box check，已保留原配置"
    "$SING_BOX_BIN" check -c "$tmp" 2>&1 | head -n 5 >&2 || true
    rm -f "$tmp"
    return 1
  fi
  old_hash="$(sha256sum "$SERVER_CONF" 2>/dev/null | awk '{print $1}')"
  new_hash="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$old_hash" == "$new_hash" ]]; then
    rm -f "$tmp"
    return 1
  fi
  mkdir -p "$(dirname "$SERVER_CONF")"
  mv "$tmp" "$SERVER_CONF"
  chmod 600 "$SERVER_CONF"
  return 0
}

restart_sing_box() {
  if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled sing-box.service >/dev/null 2>&1; then
    systemctl restart sing-box.service || die "重启 sing-box 失败"
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start \
      || die "重启 sing-box 失败"
  else
    pkill -x sing-box >/dev/null 2>&1 || true
    sleep 1
    nohup "$SING_BOX_BIN" run -c "$SERVER_CONF" >/var/log/sing-box.log 2>&1 &
  fi
}

# 渲染配置，有变化则重启 sing-box
sync_config() {
  if render_server_config; then
    info "配置已更新，重启 sing-box ..."
    restart_sing_box
  fi
}

atomic_json_from_tmp() {
  local tmp="$1" dest="$2"
  mv "$tmp" "$dest"
  chmod 600 "$dest" 2>/dev/null || true
}

# ---------- 客户端配置 ----------
write_client_files() {
  local id="$1" user_json host dir
  user_json="$(user_json_by_id "$id")" || die "用户不存在：$id"
  host="$(server_host)"
  dir="$CLIENTS_ROOT/$id"
  mkdir -p "$dir"
  local ss_port vless_port snell_port domain pubkey shortid snell_psk
  local ss_password vless_uuid snell_userkey server_ss_password
  ss_port="$(server_field ss_port)"
  vless_port="$(server_field vless_port)"
  snell_port="$(server_field snell_port)"
  domain="$(server_field reality_domain)"
  pubkey="$(server_field reality_public_key)"
  shortid="$(server_field reality_short_id)"
  snell_psk="$(server_field snell_psk)"
  server_ss_password="$(server_field ss_password)"
  ss_password="$(jq -r '.ss_password' <<<"$user_json")"
  # 2022-blake3 多用户：客户端密码须为 server_password:user_password（冒号连接）
  ss_password="${server_ss_password}:${ss_password}"
  vless_uuid="$(jq -r '.vless_uuid' <<<"$user_json")"
  snell_userkey="$(jq -r '.snell_userkey' <<<"$user_json")"

  # sing-box 客户端 outbounds 片段
  jq -n \
    --arg host "$host" \
    --argjson ss_port "$ss_port" --argjson vless_port "$vless_port" \
    --argjson snell_port "$snell_port" \
    --arg domain "$domain" --arg pubkey "$pubkey" --arg shortid "$shortid" \
    --arg snell_psk "$snell_psk" \
    --arg ss_password "$ss_password" --arg vless_uuid "$vless_uuid" \
    --arg snell_userkey "$snell_userkey" --arg id "$id" '
    {
      outbounds: [
        {
          type: "shadowsocks", tag: "ss-\($id)",
          server: $host, server_port: $ss_port,
          method: "2022-blake3-aes-128-gcm", password: $ss_password
        },
        {
          type: "vless", tag: "vless-\($id)",
          server: $host, server_port: $vless_port,
          uuid: $vless_uuid, flow: "xtls-rprx-vision",
          tls: {
            enabled: true, server_name: $domain,
            utls: {enabled: true, fingerprint: "chrome"},
            reality: {enabled: true, public_key: $pubkey, short_id: $shortid}
          }
        },
        {
          type: "snell", tag: "snell-\($id)",
          server: $host, server_port: $snell_port,
          version: 6, psk: $snell_psk, userkey: $snell_userkey,
          mode: "default", reuse: true
        }
      ]
    }' > "$dir/sing-box.json"

  # Surge 配置（Surge 不支持 VLESS+Reality，只给 ss 和 snell）
  cat > "$dir/surge.conf" << SURGE_EOF
[Proxy]
$id-ss = ss, $host, $ss_port, encrypt-method=2022-blake3-aes-128-gcm, password=$ss_password, udp-relay=true, tfo=true
$id-snell = snell, $host, $snell_port, psk=$snell_psk, version=6, mode=default, reuse=true, tfo=true, userkey=$snell_userkey
SURGE_EOF

  # 分享链接
  local ss_b64 vless_url snell_url
  ss_b64="$(printf '2022-blake3-aes-128-gcm:%s' "$ss_password" | b64url)"
  vless_url="vless://$(url_encode "$vless_uuid")@$(url_encode "$host"):${vless_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(url_encode "$domain")&fp=chrome&pbk=$(url_encode "$pubkey")&sid=$(url_encode "$shortid")#$(url_encode "$id-vless")"
  snell_url="snell://$(url_encode "$snell_psk")@$(url_encode "$host"):${snell_port}?version=6&userkey=$(url_encode "$snell_userkey")&mode=default&tfo=true&reuse=true#$(url_encode "$id-snell")"
  {
    printf 'ss://%s@%s:%s#%s\n' "$ss_b64" "$host" "$ss_port" "$(url_encode "$id-ss")"
    printf '%s\n' "$vless_url"
    printf '%s\n' "$snell_url"
  } > "$dir/url.txt"

  local quota expires used
  quota="$(jq -r '.quota_bytes' <<<"$user_json")"
  expires="$(jq -r '.expires_at' <<<"$user_json")"
  used="$(jq -r --arg id "$id" '.[$id].used_bytes // 0' "$TRAFFIC_STATE" 2>/dev/null || echo 0)"
  cat > "$dir/info.txt" << INFO_EOF
用户：$id
服务器：$host
额度：$([ "$quota" = "0" ] && echo "不限" || echo "$(format_gb "$quota") GB / 30 天")
已用：$(format_bytes "$used")
到期：$(format_time "$expires")
协议：
  ss：$host:$ss_port（2022-blake3-aes-128-gcm）
  VLESS+Reality：$host:$vless_port（SNI $domain）
  Snell v6：$host:$snell_port
INFO_EOF
  chmod 600 "$dir"/* 2>/dev/null || true
}


# ---------- 用户管理 ----------
cmd_user_add() {
  local id="${1:-}" quota_gb="" expires="" tmp
  shift || true
  [[ -n "$id" ]] || die "用法：sbox-node user add <name> --quota 100G [--expires 2026-12-31]"
  init_state
  validate_id "$id" || die "用户名无效：$id（字母数字开头，可含 . _ -，最长 32 字符）"
  user_exists "$id" && die "用户已存在：$id"
  while (( $# )); do
    case "$1" in
      --quota) quota_gb="${2:-}"; shift 2 ;;
      --expires) expires="${2:-}"; shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [[ -n "$quota_gb" ]] || die "请用 --quota 指定额度（GB，0 = 不限），例如 --quota 100G"
  local quota_bytes expires_at now
  quota_bytes="$(gb_to_bytes "$quota_gb")" || die "额度格式无效：$quota_gb"
  expires_at="$(parse_expiry_epoch "$expires")"
  now="$(date +%s)"
  local ss_password vless_uuid snell_userkey
  ss_password="$("$SING_BOX_BIN" generate rand --base64 16 2>/dev/null)" \
    || ss_password="$(head -c 16 /dev/urandom | base64 | tr -d '\n')"
  vless_uuid="$("$SING_BOX_BIN" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
  snell_userkey="$(head -c 24 /dev/urandom | base64 | tr -d '=+/\n' | head -c 32)"
  [[ -n "$ss_password" && -n "$vless_uuid" && -n "$snell_userkey" ]] \
    || die "生成用户凭据失败"
  tmp="$(mktemp)"
  jq --arg id "$id" --argjson quota "$quota_bytes" --argjson exp "$expires_at" \
     --argjson now "$now" --arg ss "$ss_password" --arg uuid "$vless_uuid" \
     --arg key "$snell_userkey" '
    .users += [{
      id: $id, quota_bytes: $quota, cycle_start: $now, expires_at: $exp,
      paused: false, ss_password: $ss, vless_uuid: $uuid,
      snell_userkey: $key, created_at: $now
    }]' "$USERS_FILE" > "$tmp" && atomic_json_from_tmp "$tmp" "$USERS_FILE"
  tmp="$(mktemp)"
  jq --arg id "$id" --argjson now "$now" '
    .[$id] = {
      used_bytes: 0, last_counter_bytes: 0, last_check: null,
      cycle_start: $now, paused_reasons: [], notified: {}
    }' "$TRAFFIC_STATE" > "$tmp" && atomic_json_from_tmp "$tmp" "$TRAFFIC_STATE"
  write_client_files "$id"
  sync_config
  info "用户 $id 已添加：额度 $([ "$quota_bytes" = "0" ] && echo "不限" || echo "$(format_gb "$quota_bytes") GB / 30 天")，到期 $(format_time "$expires_at")"
  info "客户端配置：$CLIENTS_ROOT/$id/"
}

cmd_user_remove() {
  local id="${1:-}" tmp
  [[ -n "$id" ]] || die "用法：sbox-node user remove <name>"
  init_state
  user_exists "$id" || die "用户不存在：$id"
  tmp="$(mktemp)"
  jq --arg id "$id" '.users |= map(select(.id != $id))' "$USERS_FILE" > "$tmp" \
    && atomic_json_from_tmp "$tmp" "$USERS_FILE"
  tmp="$(mktemp)"
  jq --arg id "$id" 'del(.[$id])' "$TRAFFIC_STATE" > "$tmp" \
    && atomic_json_from_tmp "$tmp" "$TRAFFIC_STATE"
  rm -rf "${CLIENTS_ROOT:?}/$id"
  sync_config
  info "用户 $id 已删除"
}

cmd_user_list() {
  local now
  now="$(date +%s)"
  printf '%-16s %-12s %-12s %-20s %s\n' "用户" "已用/额度" "周期剩余" "到期" "状态"
  jq -c '.users[]' "$USERS_FILE" | while IFS= read -r u; do
    local id quota exp paused used cycle_start remain cycle_left reasons status
    id="$(jq -r '.id' <<<"$u")"
    quota="$(jq -r '.quota_bytes' <<<"$u")"
    exp="$(jq -r '.expires_at' <<<"$u")"
    paused="$(jq -r '.paused' <<<"$u")"
    used="$(jq -r --arg id "$id" '.[$id].used_bytes // 0' "$TRAFFIC_STATE")"
    cycle_start="$(jq -r --arg id "$id" '.[$id].cycle_start // 0' "$TRAFFIC_STATE")"
    reasons="$(jq -r --arg id "$id" '.[$id].paused_reasons // [] | join(",")' "$TRAFFIC_STATE")"
    if (( cycle_start > 0 )); then
      remain=$(( CYCLE_SECONDS - (now - cycle_start) ))
      (( remain < 0 )) && remain=0
      cycle_left="$(( remain / 86400 ))天"
    else
      cycle_left="-"
    fi
    if [[ "$paused" == "true" ]]; then status="手动暂停"
    elif [[ -n "$reasons" ]]; then status="已踢：$reasons"
    else status="正常"; fi
    printf '%-16s %-12s %-12s %-20s %s\n' "$id" \
      "$(format_bytes "$used")/$([ "$quota" = "0" ] && echo "不限" || echo "$(format_gb "$quota")G")" \
      "$cycle_left" "$(format_time "$exp")" "$status"
  done
}

cmd_user_clients() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "用法：sbox-node user clients <name>"
  user_exists "$id" || die "用户不存在：$id"
  write_client_files "$id"
  info "=== $id 的客户端配置 ==="
  cat "$CLIENTS_ROOT/$id/info.txt"
  echo
  info "--- sing-box outbounds（$CLIENTS_ROOT/$id/sing-box.json）---"
  cat "$CLIENTS_ROOT/$id/sing-box.json"
  echo
  info "--- Surge（$CLIENTS_ROOT/$id/surge.conf）---"
  cat "$CLIENTS_ROOT/$id/surge.conf"
  echo
  info "--- 分享链接（$CLIENTS_ROOT/$id/url.txt）---"
  cat "$CLIENTS_ROOT/$id/url.txt"
}

cmd_user_set() {
  local id="${1:-}" tmp quota_gb="" expires=""
  shift || true
  [[ -n "$id" ]] || die "用法：sbox-node user set <name> --quota 200G [--expires 2027-03-31]"
  init_state
  user_exists "$id" || die "用户不存在：$id"
  while (( $# )); do
    case "$1" in
      --quota) quota_gb="${2:-}"; shift 2 ;;
      --expires) expires="${2:-}"; shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  tmp="$(mktemp)"
  if [[ -n "$quota_gb" ]]; then
    local quota_bytes
    quota_bytes="$(gb_to_bytes "$quota_gb")" || die "额度格式无效：$quota_gb"
    jq --arg id "$id" --argjson q "$quota_bytes" '
      .users |= map(if .id == $id then .quota_bytes = $q else . end)' \
      "$USERS_FILE" > "$tmp" && atomic_json_from_tmp "$tmp" "$USERS_FILE"
    tmp="$(mktemp)"
    jq --arg id "$id" '.[$id].notified.quota100 = false | .[$id].notified.quota80 = false | .[$id].paused_reasons = []' \
      "$TRAFFIC_STATE" > "$tmp" && atomic_json_from_tmp "$tmp" "$TRAFFIC_STATE"
    info "用户 $id 额度改为 $([ "$quota_bytes" = "0" ] && echo "不限" || echo "$(format_gb "$quota_bytes") GB")"
  fi
  if [[ -n "$expires" ]]; then
    local expires_at
    expires_at="$(parse_expiry_epoch "$expires")"
    tmp="$(mktemp)"
    jq --arg id "$id" --argjson e "$expires_at" '
      .users |= map(if .id == $id then .expires_at = $e else . end)' \
      "$USERS_FILE" > "$tmp" && atomic_json_from_tmp "$tmp" "$USERS_FILE"
    info "用户 $id 到期改为 $(format_time "$expires_at")"
  fi
  write_client_files "$id"
  sync_config
}

# ---------- V2Ray API 流量查询 ----------
# 输出 JSON：{"alice": 12345, "bob": 67890}（各用户上行+下行总字节）
query_v2ray_stats() {
  local api_port output
  require_cmd "$GRPCURL_BIN"
  api_port="$(server_field v2ray_api_port)"
  output="$("$GRPCURL_BIN" -plaintext -d '{"pattern": "", "reset": false}' \
    "127.0.0.1:${api_port}" \
    v2ray.core.app.stats.command.StatsService/QueryStats 2>/dev/null)" \
    || return 1
  printf '%s' "$output" | jq -c '
    (.stat // [])
    | map(select(.name | test("^user>>>[^>]+>>>traffic>>>(uplink|downlink)$")))
    | group_by(.name | split(">>>")[1])
    | map({key: .[0].name | split(">>>")[1],
           value: (map(.value | tonumber) | add)})
    | from_entries'
}

init_traffic_entry() {
  local id="$1" now tmp cycle_start
  now="$(date +%s)"
  cycle_start="$(jq -r --arg id "$id" '.users[] | select(.id == $id) | .cycle_start' "$USERS_FILE")"
  [[ -s "$TRAFFIC_STATE" ]] || printf '{}\n' > "$TRAFFIC_STATE"
  tmp="$(mktemp)"
  jq --arg id "$id" --argjson now "$now" --argjson cs "${cycle_start:-$now}" '
    if .[$id] == null then
      .[$id] = {
        used_bytes: 0, last_counter_bytes: 0, last_check: null,
        cycle_start: $cs, paused_reasons: [], notified: {}
      }
    else . end
  ' "$TRAFFIC_STATE" > "$tmp"
  atomic_json_from_tmp "$tmp" "$TRAFFIC_STATE"
}

traffic_state_field() {
  local id="$1" field="$2"
  jq -r --arg id "$id" --arg field "$field" '.[$id][$field] // ""' "$TRAFFIC_STATE"
}

set_traffic_state() {
  local id="$1" field="$2" json_value="$3" tmp
  tmp="$(mktemp)"
  jq --arg id "$id" --arg field "$field" --argjson value "$json_value" \
    '.[$id][$field] = $value' "$TRAFFIC_STATE" > "$tmp"
  atomic_json_from_tmp "$tmp" "$TRAFFIC_STATE"
}

# 计算用户的暂停原因（JSON 数组）：quota / expired / manual
user_pause_reasons() {
  local user_json="$1" used="$2" now="$3"
  local quota expires paused
  quota="$(jq -r '.quota_bytes // 0' <<<"$user_json")"
  expires="$(jq -r '.expires_at // 0' <<<"$user_json")"
  paused="$(jq -r '.paused // false' <<<"$user_json")"
  jq -n --argjson quota "$quota" --argjson used "$used" \
    --argjson expires "$expires" --argjson now "$now" \
    --argjson paused "$paused" '
    []
    | if $quota > 0 and $used >= $quota then . + ["quota"] else . end
    | if $expires > 0 and $now >= $expires then . + ["expired"] else . end
    | if $paused then . + ["manual"] else . end'
}
# ---------- Telegram 通知 ----------
notify_setup() {
  local token="${1:-}" chats="${2:-}"
  [[ -n "$token" && -n "$chats" ]] || die "用法：sbox-node notify setup <BOT_TOKEN> <CHAT_ID_1,CHAT_ID_2>"
  mkdir -p "$STATE_DIR"
  cat > "$NOTIFY_ENV" << NOTIFY_EOF
TELEGRAM_BOT_TOKEN='$token'
TELEGRAM_CHAT_IDS='$chats'
NOTIFY_EOF
  chmod 600 "$NOTIFY_ENV"
  info "Telegram 通知已保存（$NOTIFY_ENV）"
}

notify_send() {
  local text="$1" token chats id ok=0
  [[ -s "$NOTIFY_ENV" ]] || return 1
  # shellcheck disable=SC1090
  . "$NOTIFY_ENV"
  token="${TELEGRAM_BOT_TOKEN:-}"
  chats="${TELEGRAM_CHAT_IDS:-}"
  [[ -n "$token" && -n "$chats" ]] || return 1
  IFS=',' read -ra id <<<"$chats"
  for id in "${id[@]}"; do
    id="$(printf '%s' "$id" | tr -d '[:space:]')"
    [[ -n "$id" ]] || continue
    if curl -fsSL --max-time 15 -X POST \
        "https://api.telegram.org/bot${token}/sendMessage" \
        -d "chat_id=${id}" --data-urlencode "text=${text}" >/dev/null 2>&1; then
      ok=1
    fi
  done
  (( ok == 1 ))
}

notify_user() {
  local user_json="$1" msg="$2" id
  id="$(jq -r '.id' <<<"$user_json")"
  notify_send "【sbox】用户 $id：$msg"
}

# ---------- 定时检查（核心） ----------
# 每 5 分钟跑一次：采样 V2Ray API → 累计 → 30 天周期重置 →
# 额度/到期判断 → TG 提醒 → 自动踢人/恢复。
cmd_traffic_check() {
  local now stats_json
  init_state
  now="$(date +%s)"
  stats_json="$(query_v2ray_stats)" || {
    warn "V2Ray API 查询失败（sing-box 未运行或 API 未监听），本次跳过"
    return 0
  }
  local config_dirty=0
  while IFS= read -r user_json; do
    [[ -n "$user_json" ]] || continue
    local id current last used delta quota expires
    local reason_json reason_string prior_string cycle_start
    id="$(jq -r '.id' <<<"$user_json")"
    init_traffic_entry "$id"
    current="$(jq -r --arg id "$id" '.[$id] // 0' <<<"$stats_json")"
    last="$(traffic_state_field "$id" last_counter_bytes)"; last="${last:-0}"
    used="$(traffic_state_field "$id" used_bytes)"; used="${used:-0}"
    cycle_start="$(traffic_state_field "$id" cycle_start)"
    [[ -n "$cycle_start" && "$cycle_start" != "null" ]] || cycle_start="$now"

    # 计数器回落（sing-box 重启）时，当前值即为重启后的新增量
    if (( current >= last )); then delta=$(( current - last )); else delta="$current"; fi
    used=$(( used + delta ))

    # 30 天周期：到点清零、重开周期、清掉本周期提醒标记
    if (( now - cycle_start >= CYCLE_SECONDS )); then
      used=0
      cycle_start="$now"
      set_traffic_state "$id" cycle_start "$(jq -n --argjson n "$now" '$n')"
      set_traffic_state "$id" notified \
        "$(jq -c '.["quota80"] = false | .["quota100"] = false' <<<"$(traffic_state_field "$id" notified)")"
    fi

    quota="$(jq -r '.quota_bytes // 0' <<<"$user_json")"
    expires="$(jq -r '.expires_at // 0' <<<"$user_json")"
    reason_json="$(user_pause_reasons "$user_json" "$used" "$now")"
    prior_string="$(jq -r --arg id "$id" '.[$id].paused_reasons // [] | join(",")' "$TRAFFIC_STATE")"
    reason_string="$(jq -r 'join(",")' <<<"$reason_json")"

    set_traffic_state "$id" last_counter_bytes "$current"
    set_traffic_state "$id" used_bytes "$used"
    set_traffic_state "$id" last_check "$(jq -n --argjson n "$now" '$n')"
    set_traffic_state "$id" paused_reasons "$reason_json"

    # 暂停原因变化 → 配置要重渲染（踢人/恢复）
    [[ "$prior_string" != "$reason_string" ]] && config_dirty=1

    # ---- Telegram 提醒：额度 80% / 用完 ----
    if (( quota > 0 )); then
      local warn80 warn100
      warn80="$(jq -r --arg id "$id" '.[$id].notified.quota80 // false' "$TRAFFIC_STATE")"
      warn100="$(jq -r --arg id "$id" '.[$id].notified.quota100 // false' "$TRAFFIC_STATE")"
      if (( used * 100 >= quota * 80 )) && [[ "$warn80" != "true" ]]; then
        if notify_user "$user_json" "流量已用 $(format_bytes "$used") / $(format_gb "$quota") GB，达到 80%。"; then
          set_traffic_state "$id" notified \
            "$(jq -c '.["quota80"] = true' <<<"$(traffic_state_field "$id" notified)")"
        fi
      fi
      if (( used >= quota )) && [[ "$warn100" != "true" ]]; then
        if notify_user "$user_json" "流量额度已用完：$(format_bytes "$used") / $(format_gb "$quota") GB。节点已暂停，续费/加额度后自动恢复。"; then
          set_traffic_state "$id" notified \
            "$(jq -c '.["quota100"] = true' <<<"$(traffic_state_field "$id" notified)")"
        fi
      fi
    fi

    # ---- Telegram 提醒：到期 7/3/1 天 / 已到期 ----
    if (( expires > 0 )); then
      local remaining local_days expiry_key
      remaining=$(( expires - now ))
      for local_days in 7 3 1; do
        expiry_key="expiry${local_days}d"
        if (( remaining > 0 && remaining <= local_days * 86400 )); then
          if [[ "$(jq -r --arg id "$id" --arg key "$expiry_key" '.[$id].notified[$key] // false' "$TRAFFIC_STATE")" != "true" ]]; then
            if notify_user "$user_json" "距离到期还有约 ${local_days} 天（$(format_time "$expires")）。"; then
              set_traffic_state "$id" notified \
                "$(jq -c --arg key "$expiry_key" '.[$key] = true' <<<"$(traffic_state_field "$id" notified)")"
            fi
          fi
        fi
      done
      if (( remaining <= 0 )) \
        && [[ "$(jq -r --arg id "$id" '.[$id].notified.expired // false' "$TRAFFIC_STATE")" != "true" ]]; then
        if notify_user "$user_json" "已到期（$(format_time "$expires")），节点已暂停。"; then
          set_traffic_state "$id" notified \
            "$(jq -c '.["expired"] = true' <<<"$(traffic_state_field "$id" notified)")"
        fi
      fi
    fi

    # 刚恢复：发一条恢复通知
    if [[ -n "$prior_string" && -z "$reason_string" && -s "$NOTIFY_ENV" ]]; then
      notify_user "$user_json" "限制已解除，节点恢复可用。" \
        || warn "用户 $id 的恢复通知发送失败"
    fi
  done < <(jq -c '.users[]' "$USERS_FILE")

  # 有用户被踢/恢复时才重渲染 + 重启（配置没变不重启）
  if (( config_dirty == 1 )); then
    sync_config
  fi
}

cmd_traffic_show() {
  local now stats_json
  now="$(date +%s)"
  init_state
  stats_json="$(query_v2ray_stats 2>/dev/null || echo '{}')"
  printf '%-16s %-14s %-14s %-12s %-20s %s\n' "用户" "已用" "额度" "周期剩余" "到期" "状态"
  jq -c '.users[]' "$USERS_FILE" | while IFS= read -r u; do
    local id quota exp paused used cycle_start remain reasons status
    id="$(jq -r '.id' <<<"$u")"
    quota="$(jq -r '.quota_bytes' <<<"$u")"
    exp="$(jq -r '.expires_at' <<<"$u")"
    paused="$(jq -r '.paused' <<<"$u")"
    used="$(jq -r --arg id "$id" '.[$id].used_bytes // 0' "$TRAFFIC_STATE")"
    cycle_start="$(jq -r --arg id "$id" '.[$id].cycle_start // 0' "$TRAFFIC_STATE")"
    reasons="$(jq -r --arg id "$id" '.[$id].paused_reasons // [] | join(",")' "$TRAFFIC_STATE")"
    if (( cycle_start > 0 )); then
      remain=$(( CYCLE_SECONDS - (now - cycle_start) ))
      (( remain < 0 )) && remain=0
      remain="$(( remain / 86400 ))天"
    else
      remain="-"
    fi
    if [[ "$paused" == "true" ]]; then status="手动暂停"
    elif [[ -n "$reasons" ]]; then status="已踢：$reasons"
    else status="正常"; fi
    printf '%-16s %-14s %-14s %-12s %-20s %s\n' "$id" "$(format_bytes "$used")" \
      "$([ "$quota" = "0" ] && echo "不限" || echo "$(format_gb "$quota") GB")" \
      "$remain" "$(format_time "$exp")" "$status"
  done
}

cmd_traffic_set() {
  local id="${1:-}" quota_gb=""
  shift || true
  [[ -n "$id" ]] || die "用法：sbox-node traffic set <name> --quota 200G"
  user_exists "$id" || die "用户不存在：$id"
  while (( $# )); do
    case "$1" in
      --quota) quota_gb="${2:-}"; shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [[ -n "$quota_gb" ]] || die "请用 --quota 指定额度（GB，0 = 不限）"
  cmd_user_set "$id" --quota "$quota_gb"
}

cmd_traffic_reset() {
  local id="${1:-}" tmp now
  [[ -n "$id" ]] || die "用法：sbox-node traffic reset <name>"
  init_state
  user_exists "$id" || die "用户不存在：$id"
  now="$(date +%s)"
  tmp="$(mktemp)"
  jq --arg id "$id" --argjson now "$now" '
    .[$id].used_bytes = 0
    | .[$id].cycle_start = $now
    | .[$id].paused_reasons = []
    | .[$id].notified = {}' "$TRAFFIC_STATE" > "$tmp" \
    && atomic_json_from_tmp "$tmp" "$TRAFFIC_STATE"
  tmp="$(mktemp)"
  jq --arg id "$id" --argjson now "$now" '
    .users |= map(if .id == $id then .cycle_start = $now else . end)' \
    "$USERS_FILE" > "$tmp" && atomic_json_from_tmp "$tmp" "$USERS_FILE"
  sync_config
  info "用户 $id 流量已重置，新 30 天周期从现在开始"
}

cmd_traffic_pause() {
  local id="${1:-}" tmp
  [[ -n "$id" ]] || die "用法：sbox-node traffic pause <name>"
  user_exists "$id" || die "用户不存在：$id"
  tmp="$(mktemp)"
  jq --arg id "$id" '.users |= map(if .id == $id then .paused = true else . end)' \
    "$USERS_FILE" > "$tmp" && atomic_json_from_tmp "$tmp" "$USERS_FILE"
  sync_config
  info "用户 $id 已手动暂停"
}

cmd_traffic_resume() {
  local id="${1:-}" tmp
  [[ -n "$id" ]] || die "用法：sbox-node traffic resume <name>"
  user_exists "$id" || die "用户不存在：$id"
  tmp="$(mktemp)"
  jq --arg id "$id" '.users |= map(if .id == $id then .paused = false else . end)' \
    "$USERS_FILE" > "$tmp" && atomic_json_from_tmp "$tmp" "$USERS_FILE"
  tmp="$(mktemp)"
  jq --arg id "$id" '.[$id].paused_reasons |= map(select(. != "manual"))' \
    "$TRAFFIC_STATE" > "$tmp" && atomic_json_from_tmp "$tmp" "$TRAFFIC_STATE"
  sync_config
  info "用户 $id 已恢复"
}
# ---------- 菜单 ----------
manager_menu() {
  while true; do
    echo
    echo "=== sbox-node（合租节点管理）==="
    echo " 1) 添加用户"
    echo " 2) 查看用户 / 客户端配置"
    echo " 3) 查看流量"
    echo " 4) 修改额度 / 续期"
    echo " 5) 重置流量（新 30 天周期）"
    echo " 6) 暂停 / 恢复用户"
    echo " 7) 删除用户"
    echo " 8) Telegram 通知设置 / 测试"
    echo " 0) 退出"
    printf '请选择：'
    read -r choice || break
    case "$choice" in
      1)
        printf '用户名：'; read -r name
        printf '额度（GB，0=不限，如 100G）：'; read -r quota
        printf '到期（YYYY-MM-DD，留空=不限）：'; read -r exp
        if [[ -n "$exp" ]]; then
          cmd_user_add "$name" --quota "$quota" --expires "$exp"
        else
          cmd_user_add "$name" --quota "$quota"
        fi
        ;;
      2) cmd_user_list; printf '输入用户名查看客户端配置（0 返回）：'; read -r name
         [[ "$name" == "0" || -z "$name" ]] || cmd_user_clients "$name" ;;
      3) cmd_traffic_show ;;
      4)
        printf '用户名：'; read -r name
        printf '新额度（GB，留空跳过）：'; read -r quota
        printf '新到期（YYYY-MM-DD，留空跳过）：'; read -r exp
        local args=()
        [[ -n "$quota" ]] && args+=(--quota "$quota")
        [[ -n "$exp" ]] && args+=(--expires "$exp")
        ((${#args[@]} > 0)) && cmd_user_set "$name" "${args[@]}" || info "未修改"
        ;;
      5) printf '用户名：'; read -r name; cmd_traffic_reset "$name" ;;
      6)
        printf '用户名：'; read -r name
        printf '暂停还是恢复？(p/r)：'; read -r pr
        case "$pr" in
          p|P) cmd_traffic_pause "$name" ;;
          r|R) cmd_traffic_resume "$name" ;;
          *) info "取消" ;;
        esac
        ;;
      7) printf '用户名：'; read -r name
         printf "确认删除 %s？(y/N)：" "$name"; read -r yn
         case "$yn" in y|Y) cmd_user_remove "$name" ;; *) info "取消" ;; esac ;;
      8)
        printf 'Bot Token（留空跳过）：'; read -r token
        if [[ -n "$token" ]]; then
          printf 'Chat ID（多个用英文逗号分隔）：'; read -r chats
          notify_setup "$token" "$chats"
        fi
        notify_send "【sbox】Telegram 通知测试：发送成功。" \
          && info "测试消息已发送" || warn "测试发送失败，请检查配置"
        ;;
      0) break ;;
      *) info "无效选择" ;;
    esac
  done
}
# ---------- 入口 ----------
usage() {
  cat << 'USAGE_EOF'
用法：sbox-node <命令> [参数]

用户管理：
  sbox-node user add <name> --quota 100G [--expires 2026-12-31]
  sbox-node user remove <name>
  sbox-node user list
  sbox-node user clients <name>      # 打印客户端配置（sing-box / Surge / 链接）
  sbox-node user set <name> --quota 200G [--expires 2027-03-31]

流量管理：
  sbox-node traffic show
  sbox-node traffic set <name> --quota 200G
  sbox-node traffic reset <name>     # 重置流量，开始新 30 天周期
  sbox-node traffic pause <name>
  sbox-node traffic resume <name>
  sbox-node traffic check            # 定时任务调用（每 5 分钟）

通知：
  sbox-node notify setup <BOT_TOKEN> <CHAT_ID_1,CHAT_ID_2>
  sbox-node notify test

其他：
  sbox-node internal render          # 仅重渲染 sing-box 配置
  sbox-node                        # 交互式菜单
USAGE_EOF
}

main() {
  # sbox-traffic 这个名字调用时，直接跑定时检查
  case "${0##*/}" in
    sbox-traffic) cmd_traffic_check; exit 0 ;;
  esac
  local cmd="${1:-}"
  case "$cmd" in
    user)
      local sub="${2:-}"
      shift 2 || true
      case "$sub" in
        add) cmd_user_add "$@" ;;
        remove) cmd_user_remove "$@" ;;
        list) cmd_user_list ;;
        clients) cmd_user_clients "$@" ;;
        set) cmd_user_set "$@" ;;
        *) usage; exit 1 ;;
      esac
      ;;
    traffic)
      local sub="${2:-}"
      shift 2 || true
      case "$sub" in
        show) cmd_traffic_show ;;
        set) cmd_traffic_set "$@" ;;
        reset) cmd_traffic_reset "$@" ;;
        pause) cmd_traffic_pause "$@" ;;
        resume) cmd_traffic_resume "$@" ;;
        check) cmd_traffic_check ;;
        *) usage; exit 1 ;;
      esac
      ;;
    notify)
      local sub="${2:-}"
      shift 2 || true
      case "$sub" in
        setup) notify_setup "$@" ;;
        test)
          notify_send "【sbox】Telegram 通知测试：发送成功。" \
            && info "测试消息已发送" || die "测试发送失败，请检查配置"
          ;;
        *) usage; exit 1 ;;
      esac
      ;;
    internal)
      local sub="${2:-}"
      case "$sub" in
        render) sync_config ;;
        *) usage; exit 1 ;;
      esac
      ;;
    help|--help|-h) usage ;;
    "") manager_menu ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
