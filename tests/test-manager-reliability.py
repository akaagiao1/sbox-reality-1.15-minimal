#!/usr/bin/env python3
"""Exercise manager state transitions with isolated files and a fake host firewall."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")


class ManagerReliability(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.state = self.base / "state"
        (self.state / "traffic").mkdir(parents=True)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.nodes = self.state / "nodes.json"
        self.traffic = self.state / "traffic/state.json"
        self.config = self.base / "config.json"
        self.firewall = self.base / "firewall.json"
        self.counters = self.base / "counters.json"
        self.env = dict(os.environ, LC_ALL="C", SBOX_MANAGER_TEST_MODE="1",
                        SBOX_STATE_DIR_OVERRIDE=str(self.state),
                        SBOX_CLIENTS_ROOT_OVERRIDE=str(self.base / "clients"),
                        SBOX_SERVER_CONF_OVERRIDE=str(self.config),
                        SBOX_SERVER_HOST="127.0.0.1", SBOX_NO_RESTART="1",
                        SBOX_SKIP_SING_BOX_CHECK="1",
                        SBOX_COUNTER_OVERRIDE_FILE=str(self.counters),
                        FAKE_FIREWALL_STATE=str(self.firewall),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self.env.pop("SBOX_NOTIFY_DRY_RUN_FILE", None)
        self.write(self.counters, {"alice": 100, "bob": 0})
        self.write(self.firewall, [])
        self.write(self.nodes, {"schema": 1, "nodes": [self.node("alice", 25001)]})
        month = time.strftime("%Y-%m")
        self.write(self.traffic, {"alice": {"used_bytes": 50, "last_counter_bytes": 100,
                   "last_reset": month, "paused_reasons": ["disabled"], "notified": {}}})
        self.write(self.config, {"inbounds": [
            {"type": "mixed", "tag": "custom", "listen_port": 1080},
            {"type": "snell", "tag": "sbox-snell6-alice", "version": 6,
             "listen": "::", "listen_port": 25001, "psk": "test-only"}]})
        # Only the external kernel boundary is faked. Manager rendering,
        # accounting, transactions and CLI dispatch all run unchanged.
        firewall_tool = self.bin / "iptables"
        firewall_tool.write_text('''#!/usr/bin/env python3
import fcntl, json, os, sys
args = sys.argv[1:]
table = "filter"
if "-t" in args:
    pos = args.index("-t")
    table = args[pos + 1]
    del args[pos:pos + 2]
operation = args.pop(0)
if operation not in ("-C", "-A", "-I", "-D"):
    sys.exit(0)
if operation == "-I" and len(args) > 1 and args[1].isdigit():
    del args[1]
rule = [os.path.basename(sys.argv[0]), table] + args
if operation in ("-I", "-A") and "udp" in rule and "REJECT" in rule:
    if os.environ.get("FAIL_UDP_PORT") in rule:
        sys.exit(1)
with open(os.environ["FAKE_FIREWALL_STATE"], "r+") as stream:
    fcntl.flock(stream, fcntl.LOCK_EX)
    rules = json.load(stream)
    if operation == "-C":
        sys.exit(0 if rule in rules else 1)
    if operation == "-D":
        if rule not in rules:
            sys.exit(1)
        rules.remove(rule)
    else:
        rules.append(rule)
    stream.seek(0)
    json.dump(rules, stream)
    stream.truncate()
''')
        firewall_tool.chmod(0o755)
        (self.bin / "ip6tables").symlink_to(firewall_tool)
        for name in ("ss", "conntrack"):
            tool = self.bin / name
            tool.write_text("#!/bin/sh\nexit 0\n")
            tool.chmod(0o755)
        # macOS has no flock CLI. Use the same OS lock primitive there;
        # Linux CI exercises the real util-linux command.
        if not shutil.which("flock"):
            tool = self.bin / "flock"
            tool.write_text('''#!/usr/bin/env python3
import fcntl, sys
fcntl.flock(int(sys.argv[-1]), fcntl.LOCK_EX)
''')
            tool.chmod(0o755)
        self.run_manager("traffic", "check")

    @staticmethod
    def node(node_id, port, **extra):
        return dict(id=node_id, customer=node_id, tag="sbox-snell6-" + node_id,
                    protocol="snell6", port=port, transport="tcp", psk="test-only",
                    enabled=True, manual_pause=True, quota_bytes=0, reset_day=1,
                    expires_at=0, **extra)

    @staticmethod
    def write(path, value):
        path.write_text(json.dumps(value))

    @staticmethod
    def read(path):
        return json.loads(path.read_text())

    def command(self, body, *args):
        return [BASH, "-c", 'source "$1"; shift; ' + body,
                "_", str(ROOT / "sbox-manager.sh"), *args]

    def run_manager(self, *args, prefix="", success=True):
        result = subprocess.run(self.command(prefix + 'main "$@"', *args),
                                env=self.env, text=True, capture_output=True, timeout=20)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def paused(self, port):
        return any("REJECT" in rule and "--dport" in rule and
                   rule[rule.index("--dport") + 1] == str(port)
                   for rule in self.read(self.firewall))

    def test_delete_removes_listener_and_rules_but_preserves_custom_inbound(self):
        self.run_manager("node", "remove", "alice")
        self.assertEqual(self.read(self.nodes)["nodes"], [])
        self.assertEqual([x["tag"] for x in self.read(self.config)["inbounds"]], ["custom"])
        self.assertFalse(self.paused(25001))
        self.assertNotIn("alice", self.read(self.traffic))

    def test_rejected_port_change_preserves_old_pause_rules(self):
        self.run_manager("node", "port", "alice", "25011", success=False,
                         prefix='validate_candidate_config() { return 1; }; ')
        self.assertEqual(self.read(self.nodes)["nodes"][0]["port"], 25001)
        self.assertTrue(self.paused(25001))
        self.assertFalse(self.paused(25011))

    def test_failed_restart_restores_old_config_and_firewall(self):
        before = self.read(self.config)
        self.run_manager("node", "port", "alice", "25011", success=False,
                         prefix='service_restart() { return 1; }; ')
        self.assertEqual(self.read(self.config), before)
        self.assertTrue(self.paused(25001))
        self.assertFalse(self.paused(25011))

    def test_udp_guard_failure_cannot_commit_new_listener(self):
        node = self.node("alice", 25001)
        node.update(protocol="direct", transport="tcp udp",
                    target_address="1.1.1.1", target_port=443)
        self.write(self.nodes, {"schema": 1, "nodes": [node]})
        self.run_manager("traffic", "check")
        before = self.read(self.config)
        self.env["FAIL_UDP_PORT"] = "25011"
        self.run_manager("node", "port", "alice", "25011", success=False)
        self.assertEqual(self.read(self.config), before)
        self.assertTrue(self.paused(25001))
        self.assertFalse(self.paused(25011))

    def test_port_change_preserves_unsampled_bytes_and_blocks_before_restart(self):
        self.write(self.counters, {"alice": 150})
        self.run_manager("node", "port", "alice", "25011", prefix='''
traffic_current_bytes() {
  if [[ "$(node_json_by_id "$1" | jq -r .port)" == 25011 ]]; then
    printf 0
  else
    jq -r --arg id "$1" '.[$id] // 0' "$SBOX_COUNTER_OVERRIDE_FILE"
  fi
}
service_restart() {
  jq -e 'any(.[]; index("REJECT") != null and index("25011") != null)' "$FAKE_FIREWALL_STATE" >/dev/null || return 1
  printf '{"alice":200}' > "$SBOX_COUNTER_OVERRIDE_FILE"
}; ''')
        self.assertEqual(self.read(self.traffic)["alice"]["used_bytes"], 150)
        self.assertFalse(self.paused(25001))
        self.assertTrue(self.paused(25011))

    def test_missing_telegram_does_not_skip_later_expired_node(self):
        first = self.node("alice", 25001)
        first["manual_pause"] = False
        second = self.node("bob", 25002)
        second["manual_pause"] = False
        second["expires_at"] = 1
        self.write(self.nodes, {"schema": 1, "nodes": [first, second]})
        self.run_manager("traffic", "check")
        self.assertEqual(self.read(self.traffic)["bob"]["paused_reasons"], ["expiry"])
        self.assertTrue(self.paused(25002))

    def test_quota_units_and_safe_range(self):
        for value, expected in [("0", "0"), ("1.5G", "1610612736"),
                                ("1PiB", "1125899906842624"),
                                ("9007199254740991B", "9007199254740991")]:
            with self.subTest(value=value):
                result = subprocess.run(self.command('size_to_bytes "$1"', value),
                                        env=self.env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout.strip(), expected)
        for value in ("1E", "1EB", "1EiB", "8P", "999999999999999999999999999G", "0.1B"):
            with self.subTest(rejected=value):
                result = subprocess.run(self.command('size_to_bytes "$1"', value),
                                        env=self.env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)

    def test_accounting_ignores_other_ports_with_same_node_comment(self):
        tool = self.bin / "counter-listing"
        tool.write_text('''#!/bin/sh
cat <<'ROWS'
Chain SBOX_TRF (2 references)
 pkts bytes target prot opt in out source destination
 1 150 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:25001 /* sbox-in-alice */
 1 75 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp spt:25001 /* sbox-out-alice */
 1 200 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:25011 /* sbox-in-alice */
 1 300 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:250010 /* sbox-in-alice */
ROWS
''')
        tool.chmod(0o755)
        result = subprocess.run(self.command('''
unset SBOX_COUNTER_OVERRIDE_FILE
counter_tool=$1
iptables_cmd_for() { [[ "$1" == ipv4 ]] && printf '%s' "$counter_tool"; }
traffic_current_bytes alice
''', str(tool)), env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "225")

    def start(self, body, *args):
        process = subprocess.Popen(self.command(body, *args), env=self.env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        def stop():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=5)
        self.addCleanup(stop)
        return process

    def wait_for_file(self, path, process):
        deadline = time.monotonic() + 10
        while not path.exists() and time.monotonic() < deadline and process.poll() is None:
            time.sleep(0.02)
        self.assertTrue(path.exists(), "manager did not reach the expected wait")

    def assert_lock_free(self):
        with (self.state / ".lock").open("a") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self.fail("manager holds the state lock while waiting")

    def test_menu_input_does_not_hold_lock(self):
        marker = self.base / "waiting"
        process = self.start('marker=$1; read() { touch "$marker"; builtin read "$@"; }; main menu',
                             str(marker))
        self.wait_for_file(marker, process)
        self.assert_lock_free()
        self.run_manager("node", "list")

    def test_daemon_sleep_does_not_hold_lock(self):
        marker = self.base / "sleeping"
        process = self.start('marker=$1; sleep() { touch "$marker"; command sleep 60; }; '
                             'main traffic daemon', str(marker))
        self.wait_for_file(marker, process)
        self.assert_lock_free()
        self.run_manager("node", "list")

    def test_missing_flock_fails_instead_of_writing_without_lock(self):
        self.run_manager("node", "list", success=False, prefix='''
command() {
  if [[ "$1" == -v && "$2" == flock ]]; then return 1; fi
  builtin command "$@"
}; ''')


if __name__ == "__main__":
    unittest.main(verbosity=2)
