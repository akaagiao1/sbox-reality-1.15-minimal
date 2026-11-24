#!/usr/bin/env bash
# sbox-reality-1.15-minimal — 多用户合租节点安装脚本（重构版）
#
# 架构（干净的三件套）：
#   1. sing-box 从源码编译，带 with_v2ray_api 标签，按用户统计流量；
#   2. config.json 里 ss / VLESS+Reality / Snell v6 三个入站，
#      每个合租人在 users 里有独立的 name，experimental 开本机 V2Ray API；
#   3. 本地定时脚本（systemd timer，每 5 分钟）管到期、算累计流量、
#      发 Telegram 提醒、自动踢人。
#
# 协议只有三个：shadowsocks、VLESS+Reality、Snell v6。
# 周期按 30 天算，流量按 GB，提醒走 Telegram。
#
# 用法：
#   bash install.sh --setup [--version 1.15.0-alpha.13]
#                     [--ss-port 8388] [--vless-port 443] [--snell-port 23456]
#                     [--reality-domain www.apple.com]
#   bash install.sh --uninstall
set -euo pipefail
umask 077

STATE_DIR="/etc/sbox-reality"
USERS_FILE="$STATE_DIR/users.json"
TRAFFIC_DIR="$STATE_DIR/traffic"
TRAFFIC_STATE="$TRAFFIC_DIR/state.json"
NOTIFY_ENV="$STATE_DIR/notify.env"
SERVER_CONF="/etc/sing-box/config.json"
SING_BOX_BIN="/usr/local/bin/sing-box"
GRPCURL_BIN="/usr/local/bin/grpcurl"
MANAGER_SRC="sbox-manager.sh"
MANAGER_NODE_BIN="/usr/local/sbin/sbox-node"
MANAGER_TRAFFIC_BIN="/usr/local/sbin/sbox-traffic"
SING_BOX_SERVICE="/etc/systemd/system/sing-box.service"
TRAFFIC_SERVICE="/etc/systemd/system/sbox-traffic.service"
TRAFFIC_TIMER="/etc/systemd/system/sbox-traffic.timer"
OPENRC_SING_BOX="/etc/init.d/sing-box"
OPENRC_TRAFFIC_SCRIPT="/etc/init.d/sbox-traffic"
BBR_SYSCTL_CONF="/etc/sysctl.d/99-sbox-bbr.conf"

SING_BOX_VERSION="${SING_BOX_VERSION:-}"
SS_PORT="${SS_PORT:-auto}"
VLESS_PORT="${VLESS_PORT:-auto}"
SNELL_PORT="${SNELL_PORT:-auto}"
REALITY_DOMAIN="${REALITY_DOMAIN:-${DOMAIN:-www.apple.com}}"
V2RAY_API_PORT="${V2RAY_API_PORT:-10000}"
GRPCURL_VERSION="${GRPCURL_VERSION:-1.9.3}"
GO_VERSION="${GO_VERSION:-1.27.4}"
SETUP=0
UNINSTALL=0
SERVICE_MANAGER=""

# 编译标签：只带实际用到的。
# with_v2ray_api 是核心（默认发行版没有，必须源码编译带上）；
# with_utls 是 Reality/TLS 用的；with_quic 是 QUIC 传输；
# with_grpc 是 V2Ray API 的 gRPC 服务端；
# badlinkname/tfogo_checklinkname0 配 -checklinkname=0 链接器参数。
BUILD_TAGS="with_v2ray_api with_utls with_quic with_grpc badlinkname tfogo_checklinkname0"

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
warn() { printf '警告：%s\n' "$*" >&2; }

require_root() {
  [[ ${EUID:-0} -eq 0 ]] || die "请使用 root 运行"
}

detect_platform() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      debian|ubuntu) SERVICE_MANAGER="systemd"; return 0 ;;
      alpine) SERVICE_MANAGER="openrc"; return 0 ;;
    esac
  fi
  if command -v systemctl >/dev/null 2>&1; then SERVICE_MANAGER="systemd"; return 0; fi
  if command -v rc-service >/dev/null 2>&1; then SERVICE_MANAGER="openrc"; return 0; fi
  die "不支持的系统：需要 Debian/Ubuntu（systemd）或 Alpine（OpenRC）"
}

install_deps() {
  if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || warn "apt update 失败，继续尝试安装依赖"
    apt-get install -y -qq curl jq tar ca-certificates procps iproute2 \
      || die "安装依赖失败"
  else
    apk add --no-cache curl jq tar ca-certificates procps iproute2 \
      || die "安装依赖失败"
  fi
}

# 安装 Go（编译 sing-box 用）。已有且 >= 1.23 就直接用。
install_go() {
  if command -v go >/dev/null 2>&1; then
    local v
    v="$(go version 2>/dev/null | awk '{print $3}' | sed 's/go//')"
    if [[ -n "$v" ]]; then
      local major minor
      major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
      if (( major > 1 || (major == 1 && minor >= 23) )); then
        info "Go 已安装：$(go version)"
        return 0
      fi
    fi
    warn "Go 版本过低（需要 >= 1.23），重新安装"
  fi
  local arch url tmp
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "不支持的架构：$(uname -m)，请手动安装 Go >= 1.23" ;;
  esac
  url="https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  info "下载 Go ${GO_VERSION} ..."
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 300 -o "$tmp/go.tar.gz" "$url" \
    || die "下载 Go 失败：$url"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tmp/go.tar.gz" || die "解压 Go 失败"
  export PATH="/usr/local/go/bin:$PATH"
  go version || die "Go 安装后无法运行"
  trap - EXIT
  rm -rf "$tmp"
}

# 取最新 alpha 版本（GitHub API 优先，失败则用 git ls-remote 兜底）
fetch_latest_alpha_version() {
  local version payload
  if payload="$(curl -fsSL --max-time 20 \
      "https://api.github.com/repos/SagerNet/sing-box/tags?per_page=100" 2>/dev/null)"; then
    version="$(printf '%s' "$payload" | jq -r '
      [.[] | .name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+-alpha\\.[0-9]+$")) | sub("^v"; "")]
      | sort_by(split(".") | map(tonumber)) | last // empty' 2>/dev/null)"
    [[ -n "$version" ]] && { printf '%s' "$version"; return 0; }
  fi
  if command -v git >/dev/null 2>&1; then
    version="$(git ls-remote --tags https://github.com/SagerNet/sing-box.git 'v*-alpha.*' 2>/dev/null \
      | awk '{ sub(/^refs\/tags\/v/, "", $2); print $2 }' \
      | sort -V | tail -n 1)"
    [[ -n "$version" ]] && { printf '%s' "$version"; return 0; }
  fi
  return 1
}

# 从源码编译 sing-box，带 with_v2ray_api 等标签，装到 /usr/local/bin/sing-box
build_sing_box() {
  local version="$1" src_dir build_dir
  build_dir="$(mktemp -d)"
  trap 'rm -rf "$build_dir"' EXIT
  info "下载 sing-box v${version} 源码 ..."
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 300 \
    -o "$build_dir/src.tar.gz" \
    "https://github.com/SagerNet/sing-box/archive/refs/tags/v${version}.tar.gz" \
    || die "下载 sing-box 源码失败"
  tar -xzf "$build_dir/src.tar.gz" -C "$build_dir" || die "解压源码失败"
  src_dir="$build_dir/sing-box-${version}"
  [[ -d "$src_dir" ]] || die "源码目录不存在：$src_dir"

  # 编译需要 1G 左右内存；内存太小会 OOM，提前提醒。
  local mem_mb
  mem_mb="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  if (( mem_mb > 0 && mem_mb < 1024 )); then
    warn "可用内存仅 ${mem_mb}MB，编译 sing-box 可能内存不足（建议 >= 1GB）；继续尝试，失败请换大内存机器编译后拷入"
  fi

  info "编译 sing-box v${version}（标签：${BUILD_TAGS}），需要几分钟 ..."
  (
    cd "$src_dir"
    export GOTOOLCHAIN=local
    export GOCACHE="${GOCACHE:-$build_dir/gocache}"
    export GOPATH="${GOPATH:-$build_dir/gopath}"
    # go build 的中间文件默认放 $TMPDIR（常为 /tmp 小 tmpfs，易满）；
    # 改放到 build_dir 内，避免 /tmp 空间不足导致编译失败。
    mkdir -p "$build_dir/tmp"
    export TMPDIR="$build_dir/tmp"
    export GOMAXPROCS="${GOMAXPROCS:-2}"
    # 国内 VPS 拉 Go 模块可能慢，先走默认代理，失败再试 goproxy.cn
    if ! go build -trimpath \
        -ldflags "-X github.com/sagernet/sing-box/constant.Version=v${version} -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid=" \
        -tags "$BUILD_TAGS" \
        -o "$build_dir/sing-box" ./cmd/sing-box; then
      warn "默认 Go 代理编译失败，改用 goproxy.cn 再试一次"
      export GOPROXY="https://goproxy.cn,direct"
      go build -trimpath \
        -ldflags "-X github.com/sagernet/sing-box/constant.Version=v${version} -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid=" \
        -tags "$BUILD_TAGS" \
        -o "$build_dir/sing-box" ./cmd/sing-box \
        || die "编译 sing-box 失败"
    fi
  )
  [[ -x "$build_dir/sing-box" ]] || die "编译产物不存在"
  install -m 0755 "$build_dir/sing-box" "$SING_BOX_BIN" || die "安装 sing-box 失败"
  trap - EXIT
  rm -rf "$build_dir"
  "$SING_BOX_BIN" version || die "sing-box 安装后无法运行"
}

# 验证编译出的 sing-box 确实带 V2Ray API：用含 v2ray_api 的配置做 check，
# 没带标签的二进制会在这里报错。
verify_v2ray_api() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" << 'EOF'
{
  "log": {"level": "error"},
  "inbounds": [
    {"type": "direct", "tag": "direct-in", "listen": "127.0.0.1", "listen_port": 0}
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "experimental": {
    "v2ray_api": {
      "listen": "127.0.0.1:10000",
      "stats": {"enabled": true, "users": ["__probe__"]}
    }
  }
}
EOF
  if "$SING_BOX_BIN" check -c "$tmp" >/dev/null 2>&1; then
    info "验证通过：该 sing-box 包含 V2Ray API"
  else
    rm -f "$tmp"
    die "验证失败：该 sing-box 不包含 V2Ray API（check 拒绝了 v2ray_api 配置）"
  fi
  rm -f "$tmp"
}

# 安装 grpcurl（查 V2Ray API 用）
install_grpcurl() {
  if command -v grpcurl >/dev/null 2>&1; then
    info "grpcurl 已安装：$(grpcurl -version 2>&1 | head -n 1)"
    return 0
  fi
  local arch asset tmp
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "不支持的架构：$(uname -m)，请手动安装 grpcurl" ;;
  esac
  asset="grpcurl_${GRPCURL_VERSION}_linux_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  info "下载 grpcurl ${GRPCURL_VERSION} ..."
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 \
    -o "$tmp/grpcurl.tar.gz" \
    "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/${asset}" \
    || die "下载 grpcurl 失败"
  tar -xzf "$tmp/grpcurl.tar.gz" -C "$tmp" || die "解压 grpcurl 失败"
  [[ -x "$tmp/grpcurl" ]] || die "grpcurl 解压后不存在"
  install -m 0755 "$tmp/grpcurl" "$GRPCURL_BIN" || die "安装 grpcurl 失败"
  trap - EXIT
  rm -rf "$tmp"
  "$GRPCURL_BIN" -version 2>&1 | head -n 1 || true
}

random_free_high_port() {
  local port tries=0
  while (( tries < 100 )); do
    port=$(( RANDOM % 20000 + 10000 ))
    if ! ss -tln 2>/dev/null | grep -q ":${port} " \
       && ! ss -uln 2>/dev/null | grep -q ":${port} "; then
      printf '%s' "$port"
      return 0
    fi
    tries=$(( tries + 1 ))
  done
  return 1
}

resolve_port() {
  # $1=变量名 $2=当前值 $3=协议名（用于提示）
  local name="$1" value="$2" proto="$3" port
  if [[ "$value" == "auto" || -z "$value" ]]; then
    port="$(random_free_high_port)" || die "无法找到空闲端口（$proto）"
    printf -v "$name" '%s' "$port"
  else
    [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )) \
      || die "$proto 端口无效：$value"
    if ss -tln 2>/dev/null | grep -q ":${value} " \
       || ss -uln 2>/dev/null | grep -q ":${value} "; then
      die "$proto 端口 $value 已被占用"
    fi
    printf -v "$name" '%s' "$value"
  fi
}

enable_bbr() {
  cat > "$BBR_SYSCTL_CONF" << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl -p "$BBR_SYSCTL_CONF" >/dev/null 2>&1 || warn "BBR 启用失败（可忽略）"
}

install_manager() {
  local src="$1"
  [[ -f "$src" ]] || die "找不到管理脚本：$src（请在仓库目录运行 install.sh）"
  bash -n "$src" || die "管理脚本语法检查失败：$src"
  install -m 0755 "$src" "$MANAGER_NODE_BIN" || die "安装 sbox-node 失败"
  install -m 0755 "$src" "$MANAGER_TRAFFIC_BIN" || die "安装 sbox-traffic 失败"
}

init_state() {
  local ss_port="$1" vless_port="$2" snell_port="$3" reality_domain="$4"
  local reality_private reality_public short_id
  mkdir -p "$STATE_DIR" "$TRAFFIC_DIR" /etc/sing-box /root/sbox-reality/clients
  chmod 700 "$STATE_DIR" "$TRAFFIC_DIR" 2>/dev/null || true

  # Reality 密钥对（只生成一次；重装时沿用已有值）
  if [[ -s "$USERS_FILE" ]] && jq -e '.server.reality_private_key' "$USERS_FILE" >/dev/null 2>&1; then
    reality_private="$(jq -r '.server.reality_private_key' "$USERS_FILE")"
    reality_public="$(jq -r '.server.reality_public_key' "$USERS_FILE")"
    short_id="$(jq -r '.server.reality_short_id' "$USERS_FILE")"
  else
    local kp
    kp="$("$SING_BOX_BIN" generate reality-keypair 2>/dev/null)" \
      || die "生成 Reality 密钥对失败"
    reality_private="$(printf '%s' "$kp" | awk '/PrivateKey/ {print $2}')"
    reality_public="$(printf '%s' "$kp" | awk '/PublicKey/ {print $2}')"
    [[ -n "$reality_private" && -n "$reality_public" ]] \
      || die "解析 Reality 密钥对失败"
    short_id="$("$SING_BOX_BIN" generate rand --hex 8 2>/dev/null)" \
      || die "生成 Reality short_id 失败"
  fi

  # 已有 users.json 时保留已有用户，只更新服务端端口/域名；
  # 全新安装则建一个空用户表。
  if [[ -s "$USERS_FILE" ]]; then
    local tmp
    tmp="$(mktemp)"
    jq --argjson ss_port "$ss_port" --argjson vless_port "$vless_port" \
       --argjson snell_port "$snell_port" --arg domain "$reality_domain" \
       --argjson api_port "$V2RAY_API_PORT" \
       --arg priv "$reality_private" --arg pub "$reality_public" --arg sid "$short_id" '
      .server.ss_port = $ss_port
      | .server.vless_port = $vless_port
      | .server.snell_port = $snell_port
      | .server.reality_domain = $domain
      | .server.v2ray_api_port = $api_port
      | .server.reality_private_key = $priv
      | .server.reality_public_key = $pub
      | .server.reality_short_id = $sid
    ' "$USERS_FILE" > "$tmp" && mv "$tmp" "$USERS_FILE"
  else
    cat > "$USERS_FILE" << EOF
{
  "version": 1,
  "server": {
    "ss_port": $ss_port,
    "vless_port": $vless_port,
    "snell_port": $snell_port,
    "reality_domain": "$reality_domain",
    "reality_private_key": "$reality_private",
    "reality_public_key": "$reality_public",
    "reality_short_id": "$short_id",
    "v2ray_api_port": $V2RAY_API_PORT,
    "snell_psk": "$("$SING_BOX_BIN" generate rand --base64 24 2>/dev/null || head -c 24 /dev/urandom | base64 | tr -d '=+/\\n' | head -c 32)"
  },
  "users": []
}
EOF
  fi
  chmod 600 "$USERS_FILE"
  [[ -s "$TRAFFIC_STATE" ]] || printf '{}\n' > "$TRAFFIC_STATE"
  chmod 600 "$TRAFFIC_STATE" 2>/dev/null || true
  info "服务端端口：ss=${ss_port}  vless=${vless_port}  snell=${snell_port}  V2Ray API=127.0.0.1:${V2RAY_API_PORT}"
  info "Reality 域名：${reality_domain}，公钥：${reality_public}"
}

install_services() {
  if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
    cat > "$SING_BOX_SERVICE" << 'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org/
After=network.target network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    cat > "$TRAFFIC_SERVICE" << 'EOF'
[Unit]
Description=sbox traffic check (V2Ray API + Telegram + auto kick)
After=sing-box.service
Wants=sing-box.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sbox-traffic check
EOF
    cat > "$TRAFFIC_TIMER" << 'EOF'
[Unit]
Description=Run sbox traffic check every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now sing-box.service || die "启动 sing-box 失败"
    systemctl enable --now sbox-traffic.timer || die "启用流量定时器失败"
  else
    cat > "$OPENRC_SING_BOX" << 'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
depend() {
  need net
  after network
}
EOF
    chmod 0755 "$OPENRC_SING_BOX"
    cat > "$OPENRC_TRAFFIC_SCRIPT" << 'EOF'
#!/sbin/openrc-run
name="sbox-traffic"
description="sbox traffic check (V2Ray API + Telegram + auto kick)"
command="/usr/local/sbin/sbox-traffic"
command_args="check"
command_background="no"
depend() {
  need sing-box
}
EOF
    chmod 0755 "$OPENRC_TRAFFIC_SCRIPT"
    rc-update add sing-box default >/dev/null 2>&1 || true
    rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start \
      || die "启动 sing-box 失败"
    rc-update add sbox-traffic default >/dev/null 2>&1 || true
    # OpenRC 没有 systemd timer；用 crond 每 5 分钟跑一次。
    if command -v crond >/dev/null 2>&1; then
      (crontab -l 2>/dev/null | grep -v "sbox-traffic check"; \
       printf '*/5 * * * * /usr/local/sbin/sbox-traffic check\n') | crontab - \
        || warn "写入 crontab 失败，请手动加：*/5 * * * * /usr/local/sbin/sbox-traffic check"
      rc-service crond restart >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
    else
      warn "未找到 crond，OpenRC 下请手动把 /usr/local/sbin/sbox-traffic check 加进 cron（每 5 分钟）"
    fi
  fi
}

prompt_notify() {
  local token chats
  if [[ -s "$NOTIFY_ENV" ]]; then
    info "Telegram 通知已配置（$NOTIFY_ENV），跳过；改配置用 sbox-node notify setup"
    return 0
  fi
  printf '是否现在配置 Telegram 通知？(y/N) '
  read -r token || true
  case "$token" in
    y|Y|yes|YES) ;;
    *) info "跳过 Telegram 配置，之后用 sbox-node notify setup 配置"; return 0 ;;
  esac
  printf 'Bot Token：'
  read -r token || true
  printf 'Chat ID（多个用英文逗号分隔）：'
  read -r chats || true
  if [[ -n "$token" && -n "$chats" ]]; then
    "$MANAGER_NODE_BIN" notify setup "$token" "$chats" \
      && "$MANAGER_NODE_BIN" notify test \
      || warn "Telegram 测试发送失败，请检查 Token/Chat ID"
  else
    warn "Token 或 Chat ID 为空，跳过"
  fi
}

uninstall_all() {
  if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
    systemctl disable --now sbox-traffic.timer >/dev/null 2>&1 || true
    systemctl disable --now sing-box.service >/dev/null 2>&1 || true
    rm -f "$SING_BOX_SERVICE" "$TRAFFIC_SERVICE" "$TRAFFIC_TIMER"
    systemctl daemon-reload >/dev/null 2>&1 || true
  else
    rc-service sbox-traffic stop >/dev/null 2>&1 || true
    rc-service sing-box stop >/dev/null 2>&1 || true
    rc-update del sbox-traffic default >/dev/null 2>&1 || true
    rc-update del sing-box default >/dev/null 2>&1 || true
    rm -f "$OPENRC_SING_BOX" "$OPENRC_TRAFFIC_SCRIPT"
    (crontab -l 2>/dev/null | grep -v "sbox-traffic check") | crontab - 2>/dev/null || true
  fi
  pkill -x sing-box >/dev/null 2>&1 || true
  rm -f "$SING_BOX_BIN" "$GRPCURL_BIN" "$MANAGER_NODE_BIN" "$MANAGER_TRAFFIC_BIN"
  rm -f "$SERVER_CONF" "$BBR_SYSCTL_CONF"
  info "已卸载 sing-box、grpcurl 与管理脚本。"
  info "用户与流量状态保留在 $STATE_DIR（彻底删除请手动 rm -rf $STATE_DIR /root/sbox-reality）"
}

usage() {
  cat << 'EOF'
用法：
  bash install.sh --setup [--version 1.15.0-alpha.13]
                  [--ss-port 8388] [--vless-port 443] [--snell-port 23456]
                  [--reality-domain www.apple.com]
  bash install.sh --uninstall

环境变量也可指定：SS_PORT / VLESS_PORT / SNELL_PORT / REALITY_DOMAIN /
V2RAY_API_PORT / SING_BOX_VERSION / GRPCURL_VERSION / GO_VERSION。
端口填 auto（默认）自动选空闲高端口。
EOF
}

main() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  while (( $# )); do
    case "$1" in
      --setup) SETUP=1; shift ;;
      --uninstall) UNINSTALL=1; shift ;;
      --version) SING_BOX_VERSION="${2#v}"; shift 2 ;;
      --ss-port) SS_PORT="$2"; shift 2 ;;
      --vless-port) VLESS_PORT="$2"; shift 2 ;;
      --snell-port) SNELL_PORT="$2"; shift 2 ;;
      --reality-domain) REALITY_DOMAIN="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1（用 --help 查看用法）" ;;
    esac
  done
  require_root
  detect_platform
  if (( UNINSTALL )); then uninstall_all; exit 0; fi
  (( SETUP )) || { usage; die "请指定 --setup 或 --uninstall"; }

  [[ "$REALITY_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "Reality 域名无效：$REALITY_DOMAIN"
  (( V2RAY_API_PORT >= 1 && V2RAY_API_PORT <= 65535 )) || die "V2Ray API 端口无效"
  resolve_port SS_PORT "$SS_PORT" "ss"
  resolve_port VLESS_PORT "$VLESS_PORT" "vless"
  resolve_port SNELL_PORT "$SNELL_PORT" "snell"
  # 三个服务端口 + API 端口不能撞
  [[ "$SS_PORT" != "$VLESS_PORT" && "$SS_PORT" != "$SNELL_PORT" \
     && "$VLESS_PORT" != "$SNELL_PORT" \
     && "$SS_PORT" != "$V2RAY_API_PORT" && "$VLESS_PORT" != "$V2RAY_API_PORT" \
     && "$SNELL_PORT" != "$V2RAY_API_PORT" ]] \
    || die "端口冲突：ss/vless/snell/V2Ray API 必须各不相同"

  if [[ -z "$SING_BOX_VERSION" ]]; then
    SING_BOX_VERSION="$(fetch_latest_alpha_version)" \
      || die "无法获取最新 sing-box 版本，请用 --version 指定"
    info "最新 sing-box alpha：v${SING_BOX_VERSION}"
  fi
  [[ "$SING_BOX_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]] \
    || die "--version 格式无效：$SING_BOX_VERSION"

  install_deps
  install_go
  build_sing_box "$SING_BOX_VERSION"
  verify_v2ray_api
  install_grpcurl
  enable_bbr
  install_manager "$script_dir/$MANAGER_SRC"
  init_state "$SS_PORT" "$VLESS_PORT" "$SNELL_PORT" "$REALITY_DOMAIN"
  # 用管理脚本生成服务端配置并校验
  "$MANAGER_NODE_BIN" internal render \
    || die "生成服务端配置失败"
  install_services
  prompt_notify

  cat << EOF

安装完成。
  sing-box：$("$SING_BOX_BIN" version | head -n 1)（源码编译，带 V2Ray API）
  配置：/etc/sing-box/config.json
  状态：$USERS_FILE（用户与服务端端口）
  流量：$TRAFFIC_STATE（每 5 分钟由 sbox-traffic.timer 更新）
  管理：sbox-node（加用户、看流量、改额度、续期）
  提醒：Telegram（未配置可用 sbox-node notify setup 配置）

加第一个用户：
  sbox-node user add alice --quota 100G --expires 2026-12-31

  --quota 单位 GB（0 = 不限）；周期固定 30 天，到期按 --expires 的日期。
  客户端配置在 /root/sbox-reality/clients/alice/。
EOF
}

main "$@"
