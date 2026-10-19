#!/usr/bin/env python3
"""仅由用户确认后的控制按钮调用；采集器不导入本文件，也不自动执行控制。"""
import http.client
import json
import os
import re
import socket


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=30)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def request(path, method, endpoint):
    connection = UnixHTTP(path)
    try:
        connection.request(method, endpoint, body=b"" if method == "POST" else None)
        response = connection.getresponse()
        data = response.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise ValueError("invalid_response")
        return response.status, data
    finally:
        connection.close()


def endpoint_path():
    endpoint = os.environ.get("DOCKER_HOST", "")
    if endpoint:
        if not endpoint.startswith("unix:///"):
            raise ValueError("unsupported_endpoint")
        return endpoint[7:]
    paths = ["/var/run/docker.sock"]
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        paths.append(os.path.join(runtime, "docker.sock"))
    paths.append("/run/user/{}/docker.sock".format(os.getuid()))
    return next((path for path in paths if os.path.exists(path)), paths[0])


def control(cid, action):
    result = {"ok": False}
    # 写操作必须是完整容器 ID，拒绝名称和不唯一的短 ID；仅允许有限的三个操作。
    if not re.fullmatch(r"[a-fA-F0-9]{64}", cid) or action not in ("start", "stop", "restart"):
        result["error"] = "invalid_control"
        return result
    try:
        path = endpoint_path()
        status, data = request(path, "GET", "/version")
        if status != 200:
            raise ValueError("daemon_unavailable")
        version = json.loads(data).get("ApiVersion", "")
        if not re.fullmatch(r"\d+\.\d+", str(version)):
            raise ValueError("invalid_response")
        prefix = "/v" + version + "/containers/" + cid
        status, data = request(path, "GET", prefix + "/json")
        if status == 404:
            raise ValueError("container_missing")
        if status != 200:
            raise ValueError("permission_denied" if status in (401, 403) else "invalid_response")
        actual = json.loads(data)
        if actual.get("Id", "").lower() != cid.lower():
            raise ValueError("identity_changed")
        state = actual.get("State", {}).get("Status", "")
        if state == "paused" or (action == "start" and state not in ("created", "exited")) or (action == "stop" and state not in ("running", "restarting")):
            raise ValueError("state_changed")
        endpoint = prefix + "/" + action + ("?t=10" if action != "start" else "")
        status, _ = request(path, "POST", endpoint)
        if status not in (204, 304):
            raise ValueError("permission_denied" if status in (401, 403) else "container_missing" if status == 404 else "state_changed" if status == 409 else "control_failed")
        result["ok"] = True
    except PermissionError:
        result["error"] = "permission_denied"
    except FileNotFoundError:
        result["error"] = "socket_missing"
    except (socket.timeout, TimeoutError):
        # 超时不能证明操作没有发生，调用方应刷新状态，禁止盲目重放重启。
        result["error"] = "control_unknown"
    except ValueError as error:
        result["error"] = str(error) if str(error) in ("unsupported_endpoint", "daemon_unavailable", "invalid_response", "container_missing", "permission_denied", "identity_changed", "state_changed", "control_failed") else "invalid_response"
    except Exception:
        result["error"] = "control_unknown"
    return result


if __name__ == "__main__":
    print(json.dumps(control(os.environ.get("SI_DOCKER_CONTROL_CONTAINER", ""), os.environ.get("SI_DOCKER_CONTROL_ACTION", "")), separators=(",", ":")))
