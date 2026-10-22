#!/usr/bin/env bash
# Fixture globals are consumed by dynamically sourced installer functions.
# shellcheck disable=SC2034
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SBOX_REALITY_TEST_MODE=1
fail() { echo "FAIL: $*" >&2; exit 1; }

# Alpine splits flock into its own package; util-linux alone can be empty.
(
  set --
  source "$ROOT/install.sh"
  PLATFORM=alpine
  apk() { printf '%s\n' "$@" > "$TMP/apk-args"; }
  install_base_dependencies
)
grep -Fxq flock "$TMP/apk-args" || fail 'Alpine dependencies omit the flock executable'

# A pinned version must reach the real install dispatcher without release discovery.
(
  set -- --version v1.15.0-alpha.19
  source "$ROOT/install.sh"
  PLATFORM=alpine
  SERVER_CONF="$TMP/version/config.json"
  begin_install_transaction() { :; }
  fetch_preferred_sing_box_version() { echo 'unexpected release discovery' >&2; return 1; }
  install_sing_box_alpine() { printf '%s' "$1" > "$TMP/selected"; }
  resolve_sing_box_binary() { return 0; }
  install_sing_box
)
[[ "$(cat "$TMP/selected")" == 1.15.0-alpha.19 ]] || fail 'pinned release not selected'
(
  set --
  source "$ROOT/install.sh"
  PLATFORM=alpine
  SERVER_CONF="$TMP/version/config.json"
  begin_install_transaction() { :; }
  fetch_preferred_sing_box_version() { printf '1.15.0-alpha.22'; }
  install_sing_box_alpine() { printf '%s' "$1" > "$TMP/default"; }
  resolve_sing_box_binary() { return 0; }
  install_sing_box
)
[[ "$(cat "$TMP/default")" == 1.15.0-alpha.22 ]] || fail 'default Alpha discovery changed'
for invalid in '' latest '../1.15.0' '1.15.0;id' '1.15'; do
  if (set -- --version "$invalid"; source "$ROOT/install.sh") >/dev/null 2>&1; then
    fail "invalid version accepted: $invalid"
  fi
done

# A failure after replacing the executable must restore its matching runtime,
# config and previously running service, including the keep-config entry point.
for failure in download config service; do
  case_dir="$TMP/$failure"
  mkdir -p "$case_dir/runtime" "$case_dir/output"
  printf old-binary > "$case_dir/sing-box"
  printf old-runtime > "$case_dir/runtime/libcronet.so"
  printf old-config > "$case_dir/config.json"
  printf old-service > "$case_dir/service"
  (
    set -- --version 1.15.0-alpha.19
    source "$ROOT/install.sh"
    PLATFORM=alpine
    SERVER_CONF="$case_dir/config.json"
    OUTPUT_DIR="$case_dir/output"
    SING_BOX_INSTALL_PATHS=("$case_dir/sing-box" "$case_dir/runtime" "$case_dir/service")
    PORT_ENV="$case_dir/ports.env"; PORT_HELPER="$case_dir/port-helper"
    SYSTEMD_DROPIN="$case_dir/dropin"; OPENRC_PORT_SERVICE="$case_dir/port-service"
    CERT_PATH="$case_dir/cert"; KEY_PATH="$case_dir/key"
    WARP_CREDENTIALS_FILE="$case_dir/credentials"
    service_is_active() { return 0; }
    service_is_enabled() { return 0; }
    service_reload() { :; }
    service_enable() { :; }
    service_stop() { :; }
    service_restart() {
      [[ "$(cat "$case_dir/sing-box")" == old-binary ]] || return 1
      printf restored > "$case_dir/restarted"
    }
    install_base_dependencies() { :; }
    install_sing_box_alpine() {
      printf new-binary > "$case_dir/sing-box"
      printf new-runtime > "$case_dir/runtime/libcronet.so"
      printf extra > "$case_dir/runtime/new.so"
      printf new-service > "$case_dir/service"
      [[ "$failure" != download ]]
    }
    resolve_sing_box_binary() { SING_BOX_BIN="$case_dir/sing-box"; return 0; }
    run_sing_box() { [[ "$failure" != config ]]; }
    sleep() { :; }
    reuse_existing_config
  ) > "$case_dir/log" 2>&1 &
  upgrade_pid=$!
  if wait "$upgrade_pid"; then
    fail "$failure failure unexpectedly succeeded"
  fi
  [[ "$(cat "$case_dir/sing-box")" == old-binary ]] || fail "$failure did not restore binary"
  [[ "$(cat "$case_dir/runtime/libcronet.so")" == old-runtime ]] || fail "$failure did not restore runtime"
  [[ ! -e "$case_dir/runtime/new.so" ]] || fail "$failure left new runtime behind"
  [[ "$(cat "$case_dir/service")" == old-service ]] || fail "$failure did not restore service definition"
  [[ "$(cat "$case_dir/config.json")" == old-config ]] || fail "$failure did not retain config"
  [[ -f "$case_dir/restarted" ]] || fail "$failure did not restart restored service"
done
# A service that cannot restart after restoration must report incomplete rollback.
if (
  set --
  source "$ROOT/install.sh"
  INSTALL_SERVICE_WAS_ACTIVE=1; INSTALL_SERVICE_WAS_ENABLED=1
  service_enable() { :; }
  service_restart() { return 1; }
  restore_install_service_state
) > "$TMP/failed-service-restore.log" 2>&1; then
  fail 'failed service restoration was reported as successful'
fi

# Once the upgraded runtime is healthy, the manager owns its node transaction.
# A later notification failure must not undo only the manager's server config.
for manager_failure in notification node; do
  case_dir="$TMP/customer-$manager_failure"
  mkdir -p "$case_dir/output"
  printf old-config > "$case_dir/config.json"
  printf old-state > "$case_dir/nodes.json"
  printf old-binary > "$case_dir/sing-box"
  cat > "$case_dir/manager" <<'MANAGER'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  node)
    [[ "$MANAGER_FAILURE" != node ]] || exit 1
    printf managed-config > "$CASE_DIR/config.json"
    printf managed-state > "$CASE_DIR/nodes.json"
    ;;
  notify) exit 1 ;;
esac
MANAGER
  chmod +x "$case_dir/manager"
  (
    set --
    source "$ROOT/install.sh"
    export CASE_DIR="$case_dir" MANAGER_FAILURE="$manager_failure"
    INSTALL_MODE=snell5; CUSTOMER_ID=customer-a; TG_TOKEN=token; TG_CHAT_ID=chat
    SERVER_CONF="$case_dir/config.json"; OUTPUT_DIR="$case_dir/output"
    MANAGER_NODE_BIN="$case_dir/manager"
    SING_BOX_INSTALL_PATHS=("$case_dir/sing-box")
    WARP_CREDENTIALS_FILE="$case_dir/credentials"
    PORT_ENV="$case_dir/ports"; PORT_HELPER="$case_dir/helper"
    SYSTEMD_DROPIN="$case_dir/dropin"; OPENRC_PORT_SERVICE="$case_dir/port-service"
    CERT_PATH="$case_dir/cert"; KEY_PATH="$case_dir/key"
    detect_platform() { :; }; enable_bbr_and_fq() { :; }
    service_is_active() { return 0; }; service_is_enabled() { return 0; }
    service_enable() { :; }; service_stop() { :; }; service_reload() { :; }; service_restart() { :; }
    resolve_sing_box_binary() { return 0; }; run_sing_box() { return 0; }
    install_dependencies() { begin_install_transaction; printf new-binary > "$case_dir/sing-box"; }
    run_customer_install
  ) > "$case_dir/log" 2>&1 &
  customer_pid=$!
  if wait "$customer_pid"; then fail "customer $manager_failure failure unexpectedly succeeded"; fi
  if [[ "$manager_failure" == notification ]]; then
    [[ "$(cat "$case_dir/config.json")" == managed-config ]] || fail 'notification failure reversed committed node config'
    [[ "$(cat "$case_dir/nodes.json")" == managed-state ]] || fail 'notification failure reversed committed node state'
  else
    [[ "$(cat "$case_dir/config.json")" == old-config ]] || fail 'failed node creation altered old config'
    [[ "$(cat "$case_dir/nodes.json")" == old-state ]] || fail 'failed node creation altered old state'
  fi
  [[ "$(cat "$case_dir/sing-box")" == new-binary ]] || fail 'manager failure reversed completed runtime upgrade'
done

# Package payload files outside the standard runtime directory are transactional too.
(
  set --
  source "$ROOT/install.sh"
  SERVER_CONF="$TMP/package/config.json"; OUTPUT_DIR="$TMP/package/output"
  WARP_CREDENTIALS_FILE="$TMP/package/credentials"
  PORT_ENV="$TMP/package/ports"; PORT_HELPER="$TMP/package/helper"
  SYSTEMD_DROPIN="$TMP/package/dropin"; OPENRC_PORT_SERVICE="$TMP/package/port-service"
  CERT_PATH="$TMP/package/cert"; KEY_PATH="$TMP/package/key"
  SING_BOX_INSTALL_PATHS=("$TMP/package/missing-binary")
  mkdir -p "$TMP/package"
  printf old-library > "$TMP/package/old-library.so"
  service_is_active() { return 1; }; service_is_enabled() { return 1; }
  service_stop() { :; }; service_reload() { :; }; service_disable() { :; }
  resolve_sing_box_binary() { return 1; }
  dpkg-query() { printf '%s\n' "$TMP/package/old-library.so"; }
  dpkg-deb() { cat "$TMP/payload.tar"; }
  mkdir -p "$TMP/payload${TMP}/package"
  printf new > "$TMP/payload${TMP}/package/new-library.so"
  tar -cf "$TMP/payload.tar" -C "$TMP/payload" ".${TMP}/package/new-library.so"
  dpkg() {
    if [[ "$1" == --print-architecture ]]; then printf amd64; return 0; fi
    rm -f "$TMP/package/old-library.so"
    printf new-library > "$TMP/package/new-library.so"
    return 1
  }
  download_verified_release_asset() { :; }
  begin_install_transaction
  if install_sing_box_debian 1.15.0-alpha.19; then fail 'failed package install accepted'; fi
  rollback_install_transaction
  [[ "$(cat "$TMP/package/old-library.so")" == old-library ]] || fail 'removed package runtime not restored'
  [[ ! -e "$TMP/package/new-library.so" ]] || fail 'new package runtime not removed'
)
# Non-interactive --setup must be able to skip Telegram instead of aborting:
# the prompt reports the skip and returns without exiting the caller.
(
  set --
  source "$ROOT/install.sh"
  TG_TOKEN=''; TG_CHAT_ID=''
  if prompt_telegram_setup; then fail 'empty Telegram prompt accepted'; fi
  echo survived > "$TMP/tg-skip"
) < /dev/null > "$TMP/tg-skip.log" 2>&1
[[ -f "$TMP/tg-skip" ]] || fail 'non-interactive Telegram skip aborted the installer'
grep -q '已跳过' "$TMP/tg-skip.log" || fail 'non-interactive Telegram skip not reported'

# Supplying only one of token/chat id remains a hard configuration error.
if (
  set --
  source "$ROOT/install.sh"
  TG_TOKEN='token-only'; TG_CHAT_ID=''
  prompt_telegram_setup
) >/dev/null 2>&1; then
  fail 'half-configured Telegram accepted'
fi

# --setup on a host whose sing-box was stopped by the package reinstall must
# bring an existing configuration back up instead of reporting success with
# the service down: setup historically only enabled the service.
setup_dir="$TMP/setup-service"
mkdir -p "$setup_dir"
printf '{"inbounds":[{"type":"mixed","tag":"in","listen_port":1080}]}' > "$setup_dir/config.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$setup_dir/manager"
chmod +x "$setup_dir/manager"
(
  set --
  source "$ROOT/install.sh"
  TG_TOKEN='token'; TG_CHAT_ID='123'
  SERVER_CONF="$setup_dir/config.json"
  MANAGER_NODE_BIN="$setup_dir/manager"
  detect_platform() { :; }
  install_dependencies() { :; }
  install_manager_tool() { :; }
  enable_bbr_and_fq() { :; }
  service_enable() { :; }
  service_is_active() { return 1; }
  service_restart() { printf restarted > "$setup_dir/restarted"; }
  run_sing_box() { return 0; }
  run_manager_setup
) < /dev/null > "$setup_dir/log" 2>&1 || fail 'manager setup with stopped service failed'
[[ -f "$setup_dir/restarted" ]] || fail 'manager setup left existing sing-box service stopped'

printf 'PASS: installer version selection and upgrade rollback\n'
