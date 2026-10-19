#!/usr/bin/env python3
"""本机假 Unix socket 测试，不连接真实 Docker，不运行任何容器。"""
import contextlib
import http.server
import importlib.util
import json
import os
import pathlib
import socketserver
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
from unittest.mock import patch

SOURCE = pathlib.Path(__file__).with_name("docker-monitor.py")
SPEC = importlib.util.spec_from_file_location("docker_monitor", SOURCE)
monitor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(monitor)
CONTROL_SOURCE = SOURCE.with_name("docker-control.py")
CONTROL_SPEC = importlib.util.spec_from_file_location("docker_control", CONTROL_SOURCE)
control_module = importlib.util.module_from_spec(CONTROL_SPEC)
CONTROL_SPEC.loader.exec_module(control_module)
CID = "a" * 64
STOPPED = "b" * 64


def raw_container(cid=CID, name="/demo-web", state="running"):
    return {"Id": cid, "Names": [name], "Image": "demo/web:latest", "State": state, "Created": 100,
            "Status": "Up 5 minutes (healthy)" if state == "running" else "Exited (0) 1 minute ago",
            "Command": "sensitive-command", "Labels": {"com.docker.compose.project": "demo",
            "com.docker.compose.service": "web", "sensitive.label": "private-value"},
            "Ports": [{"IP": "127.0.0.1", "PrivatePort": 8080, "PublicPort": 18080, "Type": "tcp"}]}


def raw_stats():
    return {"cpu_stats": {"cpu_usage": {"total_usage": 150}, "system_cpu_usage": 1200, "online_cpus": 4},
            "precpu_stats": {"cpu_usage": {"total_usage": 100}, "system_cpu_usage": 1000},
            "memory_stats": {"usage": 300, "limit": 1000, "stats": {"inactive_file": 100}},
            "networks": {"eth0": {"rx_bytes": 1200, "tx_bytes": 100}, "eth1": {"rx_bytes": 800, "tx_bytes": 200}},
            "blkio_stats": {"io_service_bytes_recursive": [{"op": "Read", "value": 3000}, {"op": "Write", "value": 4000}, {"op": "Total", "value": 7000}]},
            "pids_stats": {"current": 5}, "read": "2026-10-18T00:00:00.000000000Z"}


@contextlib.contextmanager
def fake_daemon(containers=None, stats=None, stats_status=200, api_version="1.47", events=None, log_data=b"", log_status=200, limits=None, inspect_status=200, cmd=None, inspect_identity=None, control_status=204, entrypoint=None):
    requests = []
    containers = [raw_container(), raw_container(STOPPED, "/demo-old", "exited")] if containers is None else containers
    stats = raw_stats() if stats is None else stats

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append((self.command, self.path))
            status = 200
            if self.path == "/version":
                body = {"ApiVersion": api_version}
            elif self.path == "/v1.47/containers/json?all=1":
                body = containers
            elif self.path.startswith("/v1.47/containers/json?all=1&"):
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                ids = json.loads(query["filters"][0]).get("id", [])
                body = [item for item in containers if any(item["Id"].startswith(cid) for cid in ids)]
            elif self.path.startswith("/v1.47/containers/") and self.path.endswith("/stats?stream=false"):
                body, status = stats() if callable(stats) else stats, stats_status
            elif self.path.startswith("/v1.47/containers/") and self.path.endswith("/json"):
                cid = self.path.split("/")[3]
                item = next((item for item in containers if item["Id"] == cid), {"State": "running"})
                body, status = {"Id": inspect_identity or cid, "State": {"Status": item["State"]}, "HostConfig": limits or {},
                                "Config": {"Cmd": cmd, "Entrypoint": entrypoint, "Env": ["PASSWORD=private-inspect-value"]}}, inspect_status
            elif self.path.startswith("/v1.47/events?"):
                body = b"\n".join(json.dumps(event).encode() for event in (events or []))
            elif self.path.startswith("/v1.47/containers/") and "/logs?" in self.path:
                body, status = log_data() if callable(log_data) else log_data, log_status
            else:
                body, status = {"message": "unknown"}, 404
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

        def do_POST(self):
            requests.append((self.command, self.path))
            self.send_response(control_status)
            self.send_header("Content-Length", "0")
            self.end_headers()

    class Server(socketserver.ThreadingUnixStreamServer):
        daemon_threads = True

    with tempfile.TemporaryDirectory(prefix="si-docker-", dir="/private/tmp" if sys.platform == "darwin" else None) as root:
        path = os.path.join(root, "docker.sock")
        with Server(path, Handler) as server:
            worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
            worker.start()
            with patch.dict(os.environ, {"DOCKER_HOST": "unix://" + path}):
                try:
                    yield path, requests
                finally:
                    server.shutdown()
                    worker.join()


class DockerMonitorTests(unittest.TestCase):
    def test_list_only_never_samples_resources_or_events(self):
        with fake_daemon(stats_status=500, inspect_status=500) as (_, requests):
            result = monitor.collect(list_only=True)
        self.assertNotIn("error", result)
        self.assertEqual((result["total"], result["running"]), (2, 1))
        self.assertTrue(result["listOnly"])
        self.assertGreater(result["listedAt"], 0)
        self.assertEqual(requests, [("GET", "/version"), ("GET", "/v1.47/containers/json?all=1")])
        self.assertTrue(all("sampledAt" not in item for item in result["containers"]))

    def test_socket_end_to_end_and_only_get(self):
        with fake_daemon() as (_, requests):
            result = monitor.collect()
        self.assertNotIn("error", result)
        self.assertEqual((result["total"], result["running"]), (2, 1))
        self.assertEqual(result["containers"][0]["cpuPercent"], 100)
        self.assertEqual(result["containers"][0]["memoryUsed"], 200)
        self.assertEqual(result["containers"][0]["memoryLimit"], 1000)
        self.assertTrue(all(method == "GET" for method, _ in requests))
        self.assertEqual(len(requests), 5)
        self.assertFalse(any(STOPPED in path for _, path in requests))
        self.assertNotIn("cpuPercent", result["containers"][1])

    def test_network_block_io_health_ports_and_privacy(self):
        with fake_daemon():
            result = monitor.collect()
        item = result["containers"][0]
        self.assertEqual((item["networkRx"], item["networkTx"]), (2000, 300))
        self.assertEqual((item["blockRead"], item["blockWrite"]), (3000, 4000))
        self.assertEqual((item["pids"], item["health"], item["composeService"]), (5, "healthy", "web"))
        self.assertEqual(item["ports"], ["127.0.0.1:18080 → 8080/tcp"])
        text = json.dumps(result)
        self.assertNotIn("sensitive-command", text)
        self.assertNotIn("private-value", text)

    def test_stdin_execution_is_single_line_json(self):
        with fake_daemon() as (_, requests):
            output = subprocess.run([sys.executable, "-"], input=SOURCE.read_text(), text=True, capture_output=True, check=True)
        self.assertEqual(len(output.stdout.splitlines()), 1)
        self.assertEqual(json.loads(output.stdout)["total"], 2)
        self.assertEqual(output.stderr, "")
        self.assertTrue(all(method == "GET" for method, _ in requests))

    def test_cgroup_v1_prefers_total_inactive_file(self):
        stats = raw_stats()
        stats["memory_stats"]["stats"] = {"total_inactive_file": 50, "inactive_file": 100, "cache": 200}
        with fake_daemon(stats=stats):
            self.assertEqual(monitor.collect()["containers"][0]["memoryUsed"], 250)

    def test_cache_fallback_and_missing_cpu_sample(self):
        stats = raw_stats()
        stats["memory_stats"]["stats"] = {"cache": 20}
        stats["precpu_stats"] = {}
        with fake_daemon(stats=stats):
            item = monitor.collect()["containers"][0]
        self.assertEqual(item["memoryUsed"], 280)
        self.assertNotIn("cpuPercent", item)

    def test_stats_error_keeps_container_metadata(self):
        with fake_daemon(stats_status=404):
            result = monitor.collect()
        self.assertNotIn("error", result)
        self.assertEqual(result["containers"][0]["statsError"], "invalid_response")
        self.assertEqual(result["containers"][0]["name"], "demo-web")

    def test_missing_and_permission_errors(self):
        with patch.dict(os.environ, {"DOCKER_HOST": "unix:///nonexistent/si-test/docker.sock"}):
            self.assertEqual(monitor.collect()["error"], "socket_missing")
        with patch.object(monitor, "get_json", side_effect=PermissionError()):
            self.assertEqual(monitor.collect()["error"], "permission_denied")
        with patch.object(monitor, "get_json", side_effect=TimeoutError()):
            self.assertEqual(monitor.collect()["error"], "timeout")

    def test_tcp_endpoint_is_not_contacted(self):
        with patch.dict(os.environ, {"DOCKER_HOST": "tcp://localhost:2375"}), patch.object(monitor, "get_json") as request:
            self.assertEqual(monitor.collect()["error"], "unsupported_endpoint")
            request.assert_not_called()

    def test_rootless_socket_discovery(self):
        with patch.dict(os.environ, {"DOCKER_HOST": "", "XDG_RUNTIME_DIR": "/run/demo"}), patch.object(monitor.os.path, "exists", side_effect=lambda path: path == "/run/demo/docker.sock"):
            self.assertEqual(monitor.socket_path(), "/run/demo/docker.sock")

    def test_sample_limit_and_empty_list(self):
        with fake_daemon(containers=[raw_container(), raw_container("c" * 64, "/demo-worker")]), patch.object(monitor, "MAX_STATS", 1):
            result = monitor.collect()
        self.assertTrue(result["sampleLimited"])
        self.assertEqual(sum("cpuPercent" in item for item in result["containers"]), 1)
        with fake_daemon(containers=[]):
            empty = monitor.collect()
        self.assertEqual(empty["containers"], [])
        self.assertEqual(empty["total"], 0)
        self.assertNotIn("error", empty)

    def test_invalid_version_and_ids_never_enter_urls(self):
        with fake_daemon(api_version="bad/version") as (_, requests):
            self.assertEqual(monitor.collect()["error"], "invalid_response")
        self.assertEqual(requests, [("GET", "/version")])
        with fake_daemon(containers=[raw_container("../../other")]) as (_, requests):
            self.assertEqual(monitor.collect()["total"], 0)
        self.assertEqual(len(requests), 3)

    def test_no_nan_or_negative_working_set(self):
        stats = raw_stats()
        stats["memory_stats"]["stats"]["inactive_file"] = 500
        stats["cpu_stats"]["cpu_usage"]["total_usage"] = float("nan")
        with fake_daemon(stats=stats):
            item = monitor.collect()["containers"][0]
        self.assertEqual(item["memoryUsed"], 0)
        self.assertNotIn("cpuPercent", item)
        json.dumps(item, allow_nan=False)

    def test_update_uses_lifecycle_events_not_stats_read_time(self):
        events = [{"Action": "start", "Actor": {"ID": CID}, "timeNano": 250_000_000_000},
                  {"Action": "exec_create", "Actor": {"ID": CID}, "time": 999},
                  {"Action": "update", "Actor": {"ID": STOPPED}, "time": 300}]
        with fake_daemon(events=events) as (_, requests):
            result = monitor.collect()
        self.assertEqual(result["containers"][0]["updatedAt"], 250)
        self.assertEqual(result["containers"][1]["updatedAt"], 300)
        self.assertEqual(result["containers"][0]["createdAt"], 100)
        endpoint = next(path for _, path in requests if "/events?" in path)
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(endpoint).query)
        self.assertIn("until", query)

    def test_logs_multiplexed_and_tty(self):
        def frame(stream, text):
            data = text.encode()
            return bytes([stream, 0, 0, 0]) + len(data).to_bytes(4, "big") + data
        data = frame(1, "2026-10-18T00:00:00Z ready\n") + frame(2, "warning\n")
        with fake_daemon(log_data=data) as (_, requests):
            logs = monitor.collect_logs(CID, 500)
        self.assertEqual(logs["text"], "2026-10-18T00:00:00Z ready\nwarning\n")
        self.assertFalse(logs["truncated"])
        self.assertTrue(all(method == "GET" for method, _ in requests))
        self.assertTrue(any("follow=0" in path and "tail=500" in path for _, path in requests))
        with fake_daemon(log_data=b"plain tty output\n"):
            self.assertEqual(monitor.collect_logs(CID)["text"], "plain tty output\n")

    def test_logs_preserve_colors_but_strip_terminal_commands(self):
        payload = b"\x1b[31mred\x1b[0m \x1b[38;5;196m256\x1b[39m \x1b[38;2;50;150;250mrgb\x1b[0m\x1b[2K\x1b]0;title\x07\n"
        with fake_daemon(log_data=payload):
            text = monitor.collect_logs(CID)["text"]
        self.assertIn("\x1b[31mred\x1b[0m", text)
        self.assertIn("\x1b[38;5;196m256", text)
        self.assertIn("\x1b[38;2;50;150;250mrgb", text)
        self.assertNotIn("\x1b[2K", text)
        self.assertNotIn("title", text)

    def test_logs_control_codes_secrets_limits_and_driver_error(self):
        with fake_daemon(log_data=b"\x1b[31mtoken=private-value password=demo-password Bearer abc.def\x1b[0m\n"):
            text = monitor.collect_logs(CID)["text"]
        self.assertNotIn("private-value", text)
        self.assertNotIn("demo-password", text)
        self.assertNotIn("abc.def", text)
        self.assertIn("\x1b[31m", text)
        with fake_daemon(log_data=b"x" * 140_000):
            logs = monitor.collect_logs(CID)
        self.assertTrue(logs["truncated"])
        self.assertLessEqual(len(logs["text"].encode()), 128 * 1024)
        with fake_daemon(log_status=500):
            self.assertEqual(monitor.collect_logs(CID)["error"], "logs_unavailable")
        with fake_daemon(log_status=404):
            self.assertEqual(monitor.collect_logs(CID)["error"], "container_missing")

    def test_log_id_injection_rejected_before_socket_access(self):
        with patch.object(monitor, "get_payload") as request:
            self.assertEqual(monitor.collect_logs("../../other;echo secret")["error"], "invalid_container")
            request.assert_not_called()

    def test_container_nanocpus_and_memory_limits(self):
        with fake_daemon(limits={"NanoCpus": 2_000_000_000, "Memory": 512}):
            result = monitor.collect()
        item = result["containers"][0]
        self.assertTrue(item["limitsRead"])
        self.assertEqual(item["cpuLimitCores"], 2)
        self.assertEqual(item["memoryConfiguredLimit"], 512)
        self.assertNotIn("private-inspect-value", json.dumps(result))

    def test_cfs_quota_and_cpuset_choose_effective_capacity(self):
        with fake_daemon(limits={"CpuQuota": 150000, "CpuPeriod": 100000, "CpusetCpus": "0-1"}):
            self.assertEqual(monitor.collect()["containers"][0]["cpuLimitCores"], 1.5)
        with fake_daemon(limits={"NanoCpus": 4_000_000_000, "CpusetCpus": "2-3"}):
            self.assertEqual(monitor.collect()["containers"][0]["cpuLimitCores"], 2)
        with fake_daemon(limits={"NanoCpus": 500_000_000}):
            self.assertEqual(monitor.collect()["containers"][0]["cpuLimitCores"], 0.5)

    def test_cpuset_overlap_and_cpu_shares_are_not_a_hard_limit(self):
        self.assertEqual(monitor.cpuset_count("2-3"), 2)
        self.assertEqual(monitor.cpuset_count("0-2,1-3,6"), 5)
        self.assertIsNone(monitor.cpuset_count("3-1"))
        self.assertIsNone(monitor.cpuset_count(""))
        with fake_daemon(limits={"CpuShares": 1024, "CpuQuota": -1, "Memory": 0}):
            item = monitor.collect()["containers"][0]
        self.assertTrue(item["limitsRead"])
        self.assertNotIn("cpuLimitCores", item)
        self.assertNotIn("memoryConfiguredLimit", item)

    def test_inspect_failure_keeps_metrics_and_unknown_limit(self):
        with fake_daemon(inspect_status=403):
            item = monitor.collect()["containers"][0]
        self.assertFalse(item["limitsRead"])
        self.assertIn("limitsError", item)
        self.assertEqual(item["cpuPercent"], 100)
        self.assertNotIn("cpuLimitCores", item)

    def test_live_detail_reads_only_selected_container_and_advances(self):
        count = [0]

        def changing_stats():
            count[0] += 1
            stats = raw_stats()
            stats["read"] = "2026-10-18T00:00:{:02d}Z".format(count[0])
            stats["pids_stats"]["current"] = 5 + count[0]
            return stats

        with fake_daemon(stats=changing_stats) as (_, requests):
            first = monitor.collect_detail(CID)
            second = monitor.collect_detail(CID)
        self.assertEqual(len(first["containers"]), 1)
        self.assertEqual(first["containers"][0]["id"], CID)
        self.assertGreater(second["containers"][0]["sampledAt"], first["containers"][0]["sampledAt"])
        self.assertEqual(second["containers"][0]["pids"], 7)
        self.assertFalse(any("/events?" in path or STOPPED in path for _, path in requests))
        self.assertTrue(all(method == "GET" for method, _ in requests))

    def test_live_detail_stdin_mode_and_stopped_container(self):
        with fake_daemon() as (_, requests), patch.dict(os.environ, {"SI_DOCKER_DETAIL_CONTAINER": CID}):
            output = subprocess.run([sys.executable, "-"], input=SOURCE.read_text(), text=True, capture_output=True, check=True)
        self.assertEqual(json.loads(output.stdout)["containers"][0]["id"], CID)
        self.assertEqual(len(requests), 4)
        with fake_daemon() as (_, requests):
            stopped = monitor.collect_detail(STOPPED)
        self.assertEqual(stopped["containers"][0]["state"], "exited")
        self.assertIn("sampledAt", stopped["containers"][0])
        self.assertNotIn("cpuPercent", stopped["containers"][0])
        self.assertFalse(any("/stats?" in path for _, path in requests))

    def test_live_detail_missing_and_invalid_ids(self):
        with fake_daemon():
            self.assertEqual(monitor.collect_detail("c" * 64)["error"], "container_missing")
        with patch.object(monitor, "get_payload") as request:
            self.assertEqual(monitor.collect_detail("../../other")["error"], "invalid_container")
            request.assert_not_called()

    def test_live_logs_fetch_new_output_without_manual_trigger(self):
        count = [0]

        def changing_logs():
            count[0] += 1
            return ("log generation {}\n".format(count[0])).encode()

        with fake_daemon(log_data=changing_logs):
            first = monitor.collect_logs(CID)
            second = monitor.collect_logs(CID)
        self.assertEqual(first["text"], "log generation 1\n")
        self.assertEqual(second["text"], "log generation 2\n")

    def test_cmd_is_preserved_for_running_and_stopped_details(self):
        cmd = ["python", "-m", "demo", "--label=a b"]
        with fake_daemon(cmd=cmd):
            running = monitor.collect_detail(CID)
            stopped = monitor.collect_detail(STOPPED)
        self.assertEqual(running["containers"][0]["cmd"], cmd)
        self.assertEqual(stopped["containers"][0]["cmd"], cmd)
        self.assertNotIn("private-inspect-value", json.dumps(running))

    def test_control_only_whitelisted_post_after_identity_check(self):
        for action, state, suffix in (("start", "exited", "start"), ("stop", "running", "stop?t=10"), ("restart", "running", "restart?t=10")):
            with self.subTest(action=action), fake_daemon(containers=[raw_container(state=state)]) as (_, requests):
                result = control_module.control(CID, action)
            self.assertTrue(result["ok"])
            self.assertEqual(requests, [("GET", "/version"), ("GET", "/v1.47/containers/" + CID + "/json"),
                                        ("POST", "/v1.47/containers/" + CID + "/" + suffix)])

    def test_entrypoint_is_read_when_cmd_is_unset_or_empty(self):
        for cmd in (None, []):
            with self.subTest(cmd=cmd), fake_daemon(cmd=cmd, entrypoint=["/docker-entrypoint.sh", "--serve"]):
                item = monitor.collect_detail(CID)["containers"][0]
            self.assertEqual(item["entrypoint"], ["/docker-entrypoint.sh", "--serve"])
            self.assertFalse(item.get("cmd"))
        with fake_daemon(entrypoint="/entrypoint"):
            self.assertEqual(monitor.collect_detail(STOPPED)["containers"][0]["entrypoint"], ["/entrypoint"])

    def test_control_rejects_short_ids_bad_actions_and_changed_identity(self):
        with patch.object(control_module, "request") as request:
            for cid, action in ((CID[:12], "stop"), ("../../other", "restart"), (CID, "kill"), (CID, "remove")):
                self.assertEqual(control_module.control(cid, action)["error"], "invalid_control")
            request.assert_not_called()
        with fake_daemon(inspect_identity="c" * 64) as (_, requests):
            self.assertEqual(control_module.control(CID, "restart")["error"], "identity_changed")
        self.assertFalse(any(method == "POST" for method, _ in requests))

    def test_control_refuses_state_change_and_permission_denied(self):
        with fake_daemon(containers=[raw_container(state="exited")]) as (_, requests):
            self.assertEqual(control_module.control(CID, "stop")["error"], "state_changed")
        self.assertFalse(any(method == "POST" for method, _ in requests))
        with fake_daemon(inspect_status=403) as (_, requests):
            self.assertEqual(control_module.control(CID, "restart")["error"], "permission_denied")
        self.assertFalse(any(method == "POST" for method, _ in requests))

    def test_control_timeout_is_unknown_and_never_replayed(self):
        responses = [(200, b'{"ApiVersion":"1.47"}'),
                     (200, json.dumps({"Id": CID, "State": {"Status": "running"}}).encode()), TimeoutError()]
        with patch.object(control_module, "request", side_effect=responses) as request:
            self.assertEqual(control_module.control(CID, "restart")["error"], "control_unknown")
        self.assertEqual(request.call_count, 3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
