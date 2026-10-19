#!/usr/bin/env python3
"""经 SSH stdin 临时执行；只用 Docker Unix socket 的 GET 接口，不写服务器。"""
import concurrent.futures
import datetime
import http.client
import json
import math
import os
import re
import socket
import time
import urllib.parse

MAX_CONTAINERS = 200
MAX_STATS = 16
TIMEOUT = 3


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path, timeout=TIMEOUT):
        super().__init__("localhost", timeout=timeout)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def get_payload(path, endpoint, limit=8 * 1024 * 1024, timeout=TIMEOUT):
    # 采集器的唯一请求入口固定 GET，避免未来 UI 操作意外改变容器状态。
    connection = UnixHTTP(path, timeout)
    try:
        connection.request("GET", endpoint, headers={"Connection": "close"})
        response = connection.getresponse()
        data = response.read(limit + 1)
        if response.status != 200:
            raise ValueError("http_" + str(response.status))
        return data[:limit], len(data) > limit
    finally:
        connection.close()


def get_json(path, endpoint, timeout=TIMEOUT):
    data, truncated = get_payload(path, endpoint, timeout=timeout)
    if truncated:
        raise ValueError("response_too_large")
    return json.loads(data)


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0 else None


def error_code(error):
    if isinstance(error, PermissionError):
        return "permission_denied"
    if isinstance(error, FileNotFoundError):
        return "socket_missing"
    if isinstance(error, (socket.timeout, TimeoutError)):
        return "timeout"
    if isinstance(error, ValueError):
        return "invalid_response"
    return "daemon_unavailable"


def socket_path():
    # 尊重明确的 Unix endpoint；不把无意配置的 TCP Docker API 暴露给监控。
    endpoint = os.environ.get("DOCKER_HOST", "")
    if endpoint:
        if not endpoint.startswith("unix://") or not endpoint[7:].startswith("/"):
            raise ValueError("unsupported_endpoint")
        return endpoint[7:]
    paths = ["/var/run/docker.sock"]
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        paths.append(os.path.join(runtime, "docker.sock"))
    paths.append("/run/user/{}/docker.sock".format(os.getuid()))
    return next((path for path in paths if os.path.exists(path)), paths[0])


def compact_container(raw):
    cid = raw.get("Id", "")
    if not isinstance(cid, str) or not re.fullmatch(r"[a-fA-F0-9]{12,64}", cid):
        return None
    labels = raw.get("Labels") or {}
    names = raw.get("Names") or []
    status = str(raw.get("Status", ""))[:300]
    health = next((value for value in ("unhealthy", "healthy", "starting") if "(" + ("health: " if value == "starting" else "") + value + ")" in status), "")
    ports = []
    for port in (raw.get("Ports") or [])[:32]:
        private = port.get("PrivatePort")
        if not isinstance(private, int):
            continue
        text = str(private) + "/" + str(port.get("Type", "tcp"))
        if isinstance(port.get("PublicPort"), int):
            text = str(port.get("IP", "")) + ":" + str(port["PublicPort"]) + " → " + text
        ports.append(text)
    # 不导出 Command、完整 Labels、环境变量或 inspect 配置，指标不需要这些字段。
    return {"id": cid, "name": str(names[0] if names else cid[:12]).lstrip("/")[:200],
            "image": str(raw.get("Image", ""))[:300], "state": str(raw.get("State", "unknown"))[:40],
            "status": status, "health": health, "ports": ports,
            "composeProject": str(labels.get("com.docker.compose.project", ""))[:200],
            "composeService": str(labels.get("com.docker.compose.service", ""))[:200],
            "createdAt": number(raw.get("Created")), "updatedAt": number(raw.get("Created"))}


def update_activity(path, prefix, containers):
    # events 是有结束时刻的只读快照；只取生命周期时间，避免把每次指标采样当作更新。
    query = urllib.parse.urlencode({"since": "0", "until": str(int(time.time())), "filters": json.dumps({"type": ["container"]}, separators=(",", ":"))})
    try:
        data, _ = get_payload(path, prefix + "/events?" + query, 1024 * 1024)
        by_id = {item["id"]: item for item in containers}
        for line in data.splitlines():
            try:
                event = json.loads(line)
                action = event.get("Action", event.get("status", ""))
                if action not in ("create", "start", "stop", "die", "restart", "update", "rename", "pause", "unpause") and not str(action).startswith("health_status:"):
                    continue
                cid = event.get("Actor", {}).get("ID", event.get("id", ""))
                stamp = number(event.get("timeNano"))
                stamp = stamp / 1e9 if stamp else number(event.get("time"))
                if cid in by_id and stamp is not None:
                    by_id[cid]["updatedAt"] = max(by_id[cid].get("updatedAt") or 0, stamp)
            except (TypeError, ValueError, AttributeError):
                continue
    except Exception:
        # 旧 daemon / socket 代理可能禁用 events；此时保留确切的创建时间和上次已知变更。
        pass


def decode_logs(data):
    # Docker 非 TTY 日志带 8 字节多路复用头；TTY 日志直接返回文本。
    framed = len(data) >= 8 and data[0] in (0, 1, 2) and data[1:4] == b"\0\0\0"
    if not framed:
        return data.decode("utf-8", errors="replace"), False
    offset, parts, partial = 0, [], False
    while offset + 8 <= len(data):
        header = data[offset:offset + 8]
        if header[0] not in (0, 1, 2) or header[1:4] != b"\0\0\0":
            partial = True
            break
        size = int.from_bytes(header[4:8], "big")
        offset += 8
        parts.append(data[offset:min(len(data), offset + size)])
        if offset + size > len(data):
            partial = True
            break
        offset += size
    return b"".join(parts).decode("utf-8", errors="replace"), partial or offset < len(data)


def collect_logs(cid, tail=200):
    result = {"text": "", "truncated": False, "fetchedAt": time.time()}
    if not re.fullmatch(r"[a-fA-F0-9]{12,64}", cid):
        result["error"] = "invalid_container"
        return result
    try:
        path = socket_path()
        version = get_json(path, "/version").get("ApiVersion", "")
        if not re.fullmatch(r"\d+\.\d+", str(version)):
            raise ValueError("invalid_api_version")
        tail = 500 if tail == 500 else 200
        endpoint = "/v" + version + "/containers/" + cid + "/logs?stdout=1&stderr=1&timestamps=1&follow=0&tail=" + str(tail)
        payload, truncated = get_payload(path, endpoint, 2 * 1024 * 1024)
        text, partial = decode_logs(payload)
        # 仅保留 SGR 文字样式供客户端渲染；其余终端指令不能进入日志正文。
        text = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", text)
        text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]",
                      lambda match: match[0] if re.fullmatch(r"\x1b\[[0-9;]*m", match[0]) else "", text)
        text = re.sub(r"\x1b(?!\[[0-9;]*m)", "", text).replace("\r", "\n")
        text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1a\x1c-\x1f\x7f]", "", text)
        # 常见凭据只在内存中做掩码，不把容器运行日志落盘。
        text = re.sub(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+", r"\1[REDACTED]", text)
        text = re.sub(r'''(?i)((?:password|passwd|token|secret|api[_-]?key)\s*[=:]\s*["']?)[^\s,"'&}]+''', r"\1[REDACTED]", text)
        encoded = text.encode("utf-8")
        result["truncated"] = truncated or partial or len(encoded) > 128 * 1024
        result["text"] = encoded[-128 * 1024:].decode("utf-8", errors="replace")
    except Exception as error:
        result["error"] = "container_missing" if str(error) == "http_404" else "logs_unavailable" if str(error) in ("http_400", "http_500", "http_501") else "unsupported_endpoint" if str(error) == "unsupported_endpoint" else error_code(error)
    return result


def cpuset_count(value):
    # 合并区间计数，避免重复 CPU 被重复计算，也不按范围展开大数组。
    if not isinstance(value, str) or not value.strip():
        return None
    ranges = []
    for part in value.split(","):
        match = re.fullmatch(r"\s*(\d+)(?:-(\d+))?\s*", part)
        if not match:
            return None
        start, end = int(match[1]), int(match[2] or match[1])
        if end < start:
            return None
        ranges.append((start, end))
    ranges.sort()
    total = 0
    left, right = ranges[0]
    for start, end in ranges[1:]:
        if start > right + 1:
            total += right - left + 1
            left, right = start, end
        else:
            right = max(right, end)
    return total + right - left + 1


def container_limits(path, prefix, container):
    try:
        # 仅提取资源限额和启动参数白名单；Env 与完整配置不传回 App。
        raw = get_json(path, prefix + "/containers/" + container["id"] + "/json", timeout=1)
        config = raw.get("HostConfig")
        command = raw.get("Config", {}).get("Cmd")
        entrypoint = raw.get("Config", {}).get("Entrypoint")
        if isinstance(command, list) and all(isinstance(arg, str) for arg in command):
            # CMD 仅供详情展示，不导出 Env，也不把它当作后续执行命令。
            container["cmd"] = [arg[:4096] for arg in command[:128]]
        if isinstance(entrypoint, str):
            entrypoint = [entrypoint] if entrypoint else []
        if isinstance(entrypoint, list) and all(isinstance(arg, str) for arg in entrypoint):
            container["entrypoint"] = [arg[:4096] for arg in entrypoint[:128]]
        if not isinstance(config, dict):
            raise ValueError("missing_host_config")
        capacities = []
        nano = number(config.get("NanoCpus"))
        quota = number(config.get("CpuQuota"))
        period = number(config.get("CpuPeriod")) or 100000
        if nano:
            capacities.append(nano / 1e9)
        if quota:
            capacities.append(quota / period)
        cpuset = cpuset_count(config.get("CpusetCpus"))
        if cpuset:
            capacities.append(cpuset)
        if capacities:
            container["cpuLimitCores"] = min(capacities)
        memory = number(config.get("Memory"))
        if memory:
            container["memoryConfiguredLimit"] = memory
        container["limitsRead"] = True
    except Exception as error:
        container["limitsRead"] = False
        container["limitsError"] = error_code(error)


def container_stats(path, prefix, container):
    container_limits(path, prefix, container)
    try:
        stats = get_json(path, prefix + "/containers/" + container["id"] + "/stats?stream=false")
        current, previous = stats.get("cpu_stats", {}), stats.get("precpu_stats", {})
        usage = current.get("cpu_usage", {})
        old_usage = previous.get("cpu_usage", {})
        cpus = number(current.get("online_cpus")) or len(usage.get("percpu_usage", []))
        total, old_total = number(usage.get("total_usage")), number(old_usage.get("total_usage"))
        system, old_system = number(current.get("system_cpu_usage")), number(previous.get("system_cpu_usage"))
        if all(value is not None for value in (total, old_total, system, old_system)) and system > old_system and total >= old_total and cpus:
            container["cpuPercent"] = (total - old_total) / (system - old_system) * cpus * 100
        container["onlineCPUs"] = cpus or None
        if container.get("cpuLimitCores") and cpus:
            container["cpuLimitCores"] = min(container["cpuLimitCores"], cpus)
        memory = stats.get("memory_stats", {})
        used, limit = number(memory.get("usage")), number(memory.get("limit"))
        cache = memory.get("stats", {})
        # 与 docker stats 的 Linux 工作集口径一致：优先按 cgroup 版本扣除 inactive_file。
        inactive = next((number(cache[key]) for key in ("total_inactive_file", "inactive_file", "cache") if number(cache.get(key)) is not None), 0)
        if used is not None:
            container["memoryUsed"] = max(0, used - inactive)
        container["memoryLimit"] = limit
        networks = stats.get("networks")
        if isinstance(networks, dict):
            for dest, source in (("networkRx", "rx_bytes"), ("networkTx", "tx_bytes")):
                values = [number(item.get(source)) for item in networks.values()]
                if all(value is not None for value in values):
                    container[dest] = sum(values)
        io = stats.get("blkio_stats", {}).get("io_service_bytes_recursive")
        if isinstance(io, list):
            for dest, operation in (("blockRead", "read"), ("blockWrite", "write")):
                container[dest] = sum(number(item.get("value")) or 0 for item in io if str(item.get("op", "")).lower() == operation)
        container["pids"] = number(stats.get("pids_stats", {}).get("current"))
        container["sampledAt"] = time.time()
        # daemon 的 read 时刻可避免跨次轮询等待时间影响速率；异常时使用采集完成时刻。
        try:
            container["sampledAt"] = datetime.datetime.fromisoformat(stats["read"].replace("Z", "+00:00")).timestamp()
        except (KeyError, ValueError, TypeError):
            pass
    except Exception as error:
        container["statsError"] = error_code(error)


def collect_detail(cid):
    result = {"containers": [], "total": 0, "running": 0, "truncated": False, "sampleLimited": False}
    if not re.fullmatch(r"[a-fA-F0-9]{12,64}", cid):
        result["error"] = "invalid_container"
        return result
    try:
        path = socket_path()
        result["socket"] = path
        version = get_json(path, "/version").get("ApiVersion", "")
        if not re.fullmatch(r"\d+\.\d+", str(version)):
            raise ValueError("invalid_api_version")
        result["version"] = version
        prefix = "/v" + version
        # 详情只查所选容器，避免每秒重跑全服务器的容器、任务、GPU 和事件采集。
        filters = urllib.parse.urlencode({"filters": json.dumps({"id": [cid]}, separators=(",", ":"))})
        rows = get_json(path, prefix + "/containers/json?all=1&" + filters)
        selected = next((item for raw in rows if isinstance(raw, dict) for item in [compact_container(raw)]
                         if item and item["id"].startswith(cid)), None)
        if selected is None:
            result["error"] = "container_missing"
            return result
        if selected["state"] == "running":
            container_stats(path, prefix, selected)
        else:
            container_limits(path, prefix, selected)
            selected["sampledAt"] = time.time()
        result["containers"] = [selected]
        result["total"] = 1
        result["running"] = int(selected["state"] == "running")
    except Exception as error:
        result["error"] = "unsupported_endpoint" if str(error) == "unsupported_endpoint" else error_code(error)
    return result


def collect(list_only=False):
    result = {"containers": [], "total": 0, "running": 0, "truncated": False, "sampleLimited": False}
    try:
        path = socket_path()
        result["socket"] = path
        version = get_json(path, "/version").get("ApiVersion", "")
        if not re.fullmatch(r"\d+\.\d+", str(version)):
            raise ValueError("invalid_api_version")
        result["version"] = version
        prefix = "/v" + version
        result["listedAt"] = time.time()
        containers = get_json(path, prefix + "/containers/json?all=1")
        if not isinstance(containers, list):
            raise ValueError("invalid_container_list")
        containers = [item for raw in containers if isinstance(raw, dict) for item in [compact_container(raw)] if item]
        containers.sort(key=lambda item: (item["state"] != "running", -(item["createdAt"] or 0), item["name"].casefold(), item["id"]))
        result["total"] = len(containers)
        result["running"] = sum(item["state"] == "running" for item in containers)
        result["truncated"] = len(containers) > MAX_CONTAINERS
        result["containers"] = containers[:MAX_CONTAINERS]
        if list_only:
            result["listOnly"] = True
            return result
        running = [item for item in result["containers"] if item["state"] == "running"]
        result["sampleLimited"] = len(running) > MAX_STATS
        # 限制并发和采样量，避免容器多时挤占同一 SSH 通道里的其它监控。
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda item: container_stats(path, prefix, item), running[:MAX_STATS]))
        update_activity(path, prefix, result["containers"])
    except Exception as error:
        result["error"] = "unsupported_endpoint" if str(error) == "unsupported_endpoint" else error_code(error)
    return result


if __name__ == "__main__":
    cid = os.environ.get("SI_DOCKER_LOG_CONTAINER")
    detail = os.environ.get("SI_DOCKER_DETAIL_CONTAINER")
    result = collect_logs(cid, 500 if os.environ.get("SI_DOCKER_LOG_TAIL") == "500" else 200) if cid is not None else collect_detail(detail) if detail is not None else collect(os.environ.get("SI_DOCKER_LIST_ONLY") == "1")
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":"), allow_nan=False))
