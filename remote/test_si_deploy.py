"""Integration tests run only local dummy commands, never SSH or Docker."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

TOOL = Path(__file__).with_name("si-deploy")


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="si-deploy-test-")
        self.root = Path(self.temp.name)
        self.processes = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=5)
        self.temp.cleanup()

    def launch(self, script, name="test-api", extra=()):
        process = subprocess.Popen(
            [sys.executable, str(TOOL), "run", "--name", name,
             "--state-dir", str(self.root), "--heartbeat", "0.1",
             "--quiet-after", "0.2", *extra, "--", "bash", "-c", script],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.processes.append(process)
        return process

    def payload(self, name="test-api"):
        return json.loads((self.root / "progress" / ("deploy-" + name + ".json")).read_text())

    def wait_for(self, predicate, timeout=4):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                result = predicate()
                if result:
                    return result
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(0.025)
        self.fail("Timed out waiting for deployment state")

    def test_output_exit_code_and_failure_stage(self):
        process = self.launch('echo "同步代码"; echo "构建后端镜像"; printf "原始错误\\n" >&2; exit 17')
        stdout, stderr = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 17)
        self.assertEqual(stdout.decode(), "同步代码\n构建后端镜像\n")
        self.assertEqual(stderr.decode(), "原始错误\n")
        state = self.payload()
        self.assertEqual(state["status"], "failed")
        self.assertIn("构建镜像", state["message"])
        self.assertEqual(state["deployment"]["exit_code"], 17)
        self.assertLess(state["progress"], 1)

    def test_idle_heartbeat_without_fabricated_percentage(self):
        process = self.launch("sleep 1.5")
        self.wait_for(lambda: self.payload()["deployment"]["elapsed"] > 0.3)
        first = self.payload()
        time.sleep(0.25)
        second = self.payload()
        self.assertEqual(second["status"], "running")
        self.assertIsNone(second["progress"])
        self.assertIn("无输出", second["message"])
        self.assertGreater(second["deployment"]["elapsed"], first["deployment"]["elapsed"])
        process.communicate(timeout=5)
        self.assertEqual(self.payload()["status"], "done")

    def test_success_message_does_not_finish_before_postprocessing(self):
        process = self.launch('echo "构建后端镜像"; echo "✅ 部署完成"; sleep 0.5; echo "清理历史镜像"; sleep 0.8')
        self.wait_for(lambda: self.payload()["deployment"]["elapsed"] > 0.2)
        self.assertEqual(self.payload()["status"], "running")
        self.assertLess(self.payload()["progress"], 1)
        self.wait_for(lambda: self.payload()["deployment"]["stage"] == 6)
        self.assertEqual(self.payload()["status"], "running")
        process.communicate(timeout=5)
        self.assertEqual(self.payload()["progress"], 1)
        history = list((self.root / "deployments").glob("*.json"))
        self.assertEqual(len(history), 1)
        saved = json.loads(history[0].read_text())
        self.assertEqual(saved["deployment"]["timeline"][-1]["name"], "清理与备份")

    def test_explicit_hooks_take_precedence_and_accept_real_subprogress(self):
        script = (
            '"$PYTHON" "$TOOL" stage 2 5 "安装依赖" --fraction 0.5; '
            '"$PYTHON" "$TOOL" detail "pip 安装中"; '
            'echo "清理历史镜像"; sleep 0.8'
        )
        env = os.environ.copy()
        env.update(PYTHON=sys.executable, TOOL=str(TOOL))
        process = subprocess.Popen(
            [sys.executable, str(TOOL), "run", "--name", "test-api",
             "--state-dir", str(self.root), "--heartbeat", "0.1",
             "--", "bash", "-c", script], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.processes.append(process)
        self.wait_for(lambda: self.payload()["deployment"]["source"] == "manual")
        state = self.payload()
        self.assertEqual(state["deployment"]["stage"], 2)
        self.assertEqual(state["progress"], 0.3)
        self.assertIn("安装依赖", state["message"])
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0)

    def test_buildkit_details_do_not_persist_raw_secrets(self):
        secret = "SAMPLE_PASSWORD_NOT_A_REAL_SECRET"
        process = self.launch(
            'echo "构建后端镜像"; '
            'printf "#7 [4/6] RUN pip install --index-url https://user:'
            + secret + '@example.invalid/simple\\r"; sleep 0.7'
        )
        self.wait_for(lambda: "安装 Python 依赖" in self.payload()["message"])
        progress = (self.root / "progress" / "deploy-test-api.json").read_text()
        self.assertNotIn(secret, progress)
        self.assertLess(len(progress.encode()), 4096)
        process.communicate(timeout=5)
        for history in (self.root / "deployments").glob("*.json"):
            self.assertNotIn(secret, history.read_text())

    def test_same_name_is_locked_and_different_names_are_independent(self):
        first = self.launch("sleep 1")
        self.wait_for(lambda: self.payload()["status"] == "running")
        second = self.launch("echo must-not-execute")
        stdout, _ = second.communicate(timeout=5)
        self.assertEqual(second.returncode, 2)
        self.assertNotIn(b"must-not-execute", stdout)
        other = self.launch("exit 0", name="other-api")
        other.communicate(timeout=5)
        self.assertEqual(self.payload("other-api")["status"], "done")
        self.assertEqual(self.payload()["status"], "running")
        first.communicate(timeout=5)

    def test_sigterm_reaches_child_and_reports_failure(self):
        process = self.launch("exec sleep 30")
        self.wait_for(lambda: self.payload()["status"] == "running")
        time.sleep(0.1)
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, 143)
        self.assertEqual(self.payload()["status"], "failed")

    def test_invalid_rules_do_not_execute_the_command(self):
        rules = self.root / "bad-rules.json"
        rules.write_text('{"stages":[{"name":"bad","pattern":"["}]}')
        process = self.launch("echo must-not-execute", extra=("--rules", str(rules)))
        stdout, _ = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 2)
        self.assertEqual(stdout, b"")

    def test_failure_to_publish_does_not_change_child_exit(self):
        script = (
            'while [ ! -f "$STATE/progress/deploy-test-api.json" ]; do sleep 0.01; done; '
            'mv "$STATE/progress" "$STATE/previous-progress"; '
            'printf block > "$STATE/progress"; sleep 0.3; exit 23'
        )
        env = os.environ.copy()
        env["STATE"] = str(self.root)
        process = subprocess.Popen(
            [sys.executable, str(TOOL), "run", "--name", "test-api",
             "--state-dir", str(self.root), "--heartbeat", "0.1",
             "--", "bash", "-c", script], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.processes.append(process)
        _, stderr = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 23)
        self.assertIn("无法保存进度", stderr.decode())
        history = list((self.root / "deployments").glob("*.json"))
        self.assertEqual(json.loads(history[0].read_text())["deployment"]["exit_code"], 23)

    def test_custom_rules_cover_non_docker_deployments(self):
        rules = self.root / "rules.json"
        rules.write_text(json.dumps({"stages": [
            {"name": "发布资源", "pattern": "^UPLOAD ASSETS$"},
            {"name": "验证发布", "pattern": "^VERIFY RELEASE$"},
        ]}))
        process = self.launch("echo UPLOAD ASSETS; echo VERIFY RELEASE; sleep 0.5",
                              extra=("--rules", str(rules)))
        self.wait_for(lambda: self.payload()["deployment"]["stage"] == 2)
        self.assertEqual(self.payload()["deployment"]["stages"], 2)
        self.assertEqual(self.payload()["progress"], 0.5)
        process.communicate(timeout=5)

    def test_missing_executable_preserves_shell_convention(self):
        process = subprocess.Popen(
            [sys.executable, str(TOOL), "run", "--name", "test-api",
             "--state-dir", str(self.root), "--", "/nonexistent/si-test-command"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.processes.append(process)
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, 127)
        self.assertEqual(self.payload()["status"], "failed")

    def test_background_log_descriptors_do_not_hang_completion(self):
        started = time.monotonic()
        process = self.launch('sleep 2 & printf "清理历史镜像"')
        process.communicate(timeout=5)
        self.assertLess(time.monotonic() - started, 1.5)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(self.payload()["deployment"]["stage"], 6)

    def test_last_phase_subprogress_cannot_report_early_success(self):
        env = os.environ.copy()
        env.update(PYTHON=sys.executable, TOOL=str(TOOL))
        process = subprocess.Popen(
            [sys.executable, str(TOOL), "run", "--name", "test-api",
             "--state-dir", str(self.root), "--heartbeat", "0.1", "--",
             "bash", "-c", '"$PYTHON" "$TOOL" stage 1 1 "后置处理" --fraction 1; sleep 0.5'],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.processes.append(process)
        self.wait_for(lambda: self.payload()["deployment"]["stage"] == 1)
        self.assertEqual(self.payload()["status"], "running")
        self.assertLess(self.payload()["progress"], 1)
        process.communicate(timeout=5)

    def test_local_runs_are_isolated_and_keep_server_attribution(self):
        for _ in range(2):
            process = self.launch("echo 构建后端镜像; exit 0",
                extra=("--local", "--host", "demo-host", "--action-id", "demo-action"))
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0)
        files = list((self.root / "local" / "progress").glob("*.json"))
        self.assertEqual(len(files), 2)
        values = [json.loads(p.read_text()) for p in files]
        self.assertNotEqual(values[0]["deployment"]["run_id"], values[1]["deployment"]["run_id"])
        self.assertTrue(all(v["deployment"]["host"] == "demo-host" for v in values))
        self.assertFalse((self.root / "progress").exists())

    def test_local_ssh_255_reports_uncertain_instead_of_failed(self):
        process = self.launch("exit 255", extra=("--local", "--host", "demo-host", "--ssh"))
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, 255)
        file = next((self.root / "local" / "progress").glob("*.json"))
        value = json.loads(file.read_text())
        self.assertEqual(value["status"], "unknown")
        self.assertIn("远端结果未知", value["message"])

    def test_local_mode_keeps_stdin_for_multiline_action_scripts(self):
        process = subprocess.Popen(
            [sys.executable, str(TOOL), "run", "--local", "--host", "demo-host",
             "--name", "deploy/frontend", "--state-dir", str(self.root), "--", "bash", "-s"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.processes.append(process)
        stdout, _ = process.communicate(b"echo stdin-script-ran\nexit 19\n", timeout=5)
        self.assertEqual(stdout, b"stdin-script-ran\n")
        self.assertEqual(process.returncode, 19)
        file = next((self.root / "local" / "progress").glob("*.json"))
        self.assertEqual(json.loads(file.read_text())["status"], "failed")

    def test_two_local_hosts_can_use_the_same_task_name_concurrently(self):
        first = self.launch("sleep 0.4", extra=("--local", "--host", "demo-host-a"))
        second = self.launch("sleep 0.4", extra=("--local", "--host", "demo-host-b"))
        first.communicate(timeout=5)
        second.communicate(timeout=5)
        self.assertEqual((first.returncode, second.returncode), (0, 0))
        files = list((self.root / "local" / "progress").glob("*.json"))
        self.assertEqual(len(files), 2)
        self.assertEqual({json.loads(f.read_text())["deployment"]["host"] for f in files},
                         {"demo-host-a", "demo-host-b"})

    def test_local_logs_and_stage_timeline_are_available_while_running(self):
        process = self.launch('echo "[1/3] 拉取代码"; echo "[2/3] 构建镜像"; echo "#7 [builder 2/5] RUN npm ci"; echo "npm output"; sleep 0.7',
                              extra=("--local",))
        folder = self.root / "local"
        self.wait_for(lambda: list((folder / "deployments").glob("*.json")))
        self.wait_for(lambda: "npm output" in next((folder / "logs").glob("*.log")).read_text())
        metadata = json.loads(next((folder / "deployments").glob("*.json")).read_text())
        self.assertEqual(metadata["deployment"]["stage"], 2)
        self.assertEqual(metadata["deployment"]["stages"], 3)
        self.assertEqual(metadata["deployment"]["timeline"][0]["name"], "拉取代码")
        process.communicate(timeout=5)
        metadata = json.loads(next((folder / "deployments").glob("*.json")).read_text())
        self.assertGreaterEqual(metadata["deployment"]["finished"], metadata["deployment"]["started"])

    def test_docker_steps_move_progress_before_whole_deployment_finishes(self):
        script = (
            'echo "#7 [builder 2/5] RUN npm ci"; sleep 0.4; '
            'echo "#7 DONE 1.2s"; echo "#8 [builder 3/5] RUN npm run build"; sleep 0.7'
        )
        process = self.launch(script, extra=("--local",))
        folder = self.root / "local" / "progress"
        def state():
            return json.loads(next(folder.glob("*.json")).read_text())
        self.wait_for(lambda: folder.exists() and list(folder.glob("*.json")))
        self.wait_for(lambda: state()["progress"] is not None)
        first = state()["progress"]
        self.wait_for(lambda: state()["progress"] > first)
        self.assertEqual(state()["status"], "running")
        self.assertLess(state()["progress"], 1)
        process.communicate(timeout=5)

    def test_nested_old_wrapper_is_merged_into_outer_action(self):
        env = os.environ.copy()
        env["TOOL"] = str(TOOL)
        env["PYTHON"] = sys.executable
        process = subprocess.Popen(
            [sys.executable, str(TOOL), "run", "--local", "--name", "outer",
             "--state-dir", str(self.root), "--", "bash", "-c",
             '"$PYTHON" "$TOOL" run --name inner --state-dir "$INNER" -- bash -c \'echo nested-output; exit 7\''],
            env=dict(env, INNER=str(self.root / "inner")), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(process)
        stdout, _ = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 7)
        self.assertIn(b"nested-output", stdout)
        self.assertFalse((self.root / "inner").exists())
        self.assertEqual(len(list((self.root / "local/progress").glob("*.json"))), 1)

    def test_chinese_progress_prefix_preserves_script_totals(self):
        process = self.launch('echo "[进度 5/12] 检查部署配置"; echo "#7 [builder 2/5] RUN npm ci"; sleep 0.5',
                              extra=("--local",))
        folder = self.root / "local/progress"
        self.wait_for(lambda: list(folder.glob("*.json")))
        def state():
            return json.loads(next(folder.glob("*.json")).read_text())
        self.wait_for(lambda: state()["deployment"]["stage"] == 5)
        self.assertEqual(state()["deployment"]["stages"], 12)
        self.assertIn("检查部署配置", state()["message"])
        self.assertLess(state()["progress"], 0.5)
        process.communicate(timeout=5)

    def test_existing_seven_step_frontend_script(self):
        script = 'echo "Demo Frontend 部署脚本（优化版）"; echo "4. 开始构建 Docker 镜像..."; sleep 0.5'
        presets = TOOL.parent.parent / "examples/deployment-progress-rules.json"
        process = self.launch(script, extra=("--local", "--rules", str(presets)))
        folder = self.root / "local/progress"
        self.wait_for(lambda: list(folder.glob("*.json")))
        def state():
            return json.loads(next(folder.glob("*.json")).read_text())
        self.wait_for(lambda: state()["deployment"]["stage"] == 4)
        self.assertEqual(state()["deployment"]["stages"], 7)
        self.assertAlmostEqual(state()["progress"], 3 / 7)
        process.communicate(timeout=5)

    def test_script_specific_steps_are_not_hardcoded_without_import(self):
        process = self.launch('echo "Demo Frontend 部署脚本（优化版）"; echo "3. 本次部署的版本："; sleep 0.3',
                              extra=("--local",))
        folder = self.root / "local/progress"
        self.wait_for(lambda: list(folder.glob("*.json")))
        state = json.loads(next(folder.glob("*.json")).read_text())
        self.assertIsNone(state["progress"])
        process.communicate(timeout=5)

    def test_imported_backend_rule_matches_dynamic_stage_list(self):
        presets = TOOL.parent.parent / "examples/deployment-progress-rules.json"
        process = self.launch('echo "Demo 后端智能部署"; echo "🔄 同步代码..."; echo "🔎 冒烟：KB 索引非空..."; sleep 0.5',
                              extra=("--local", "--rules", str(presets)))
        folder = self.root / "local/progress"
        self.wait_for(lambda: list(folder.glob("*.json")))
        def state():return json.loads(next(folder.glob("*.json")).read_text())
        self.wait_for(lambda: state()["deployment"]["stage"] == 5)
        self.assertEqual(state()["deployment"]["source"], "rule")
        self.assertIn("业务验证", state()["message"])
        process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
