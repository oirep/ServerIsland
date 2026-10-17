# 架构

## 总体数据流

```
ConfigStore (config.json)
     │  settings.hosts[...]
     ▼
MonitorEngine ── 每台主机一个 Task 循环 ──► SSHRunner.run(host, script)
     │                                          │  /usr/bin/ssh + ControlMaster
     │                                          ▼
     │                                    远端 bash（stdin 读脚本）
     │                                          │  @@SI: 分段输出
     │◄──────── RemoteScript.parse → build() ◄──┘
     │  snapshots[hostID]: HostSnapshot（指标、GPU、磁盘、jobs）
     │  detectEvents() → IslandEvent → emit（弹窗 / 提示音 / 系统通知）
     ▼
SwiftUI（IslandRootView、SettingsView），通过 @ObservedObject 订阅 engine 和 store
```

- **启动**（`App/main.swift`）：先处理命令行开关（askpass、`--render-preview`、`--selftest`、`--diagnose`、`--detail`、`--partitions`、`--final-state`），然后才是普通 App 的启动流程。
- **`AppDelegate`**：
  - 创建 `ConfigStore`、`MonitorEngine`、`SettingsWindowController`、`IslandController`；
  - 菜单栏图标（`NSStatusItem`）；
  - 系统通知（`UNUserNotificationCenter`）。开启了提示音时，系统通知不再另外出声。

## 配置（`Models/Config.swift`）

- `AppSettings`：全局设置，包括 `hosts`、`defaultInterval`、`autoRefresh`、`collapsedStyle`、`islandAlerts`、`systemNotifications`、`soundEnabled`、`soundVolume`、`arrayFirstFailureAlert`、`diskWarnThreshold`、`language`。
- `HostConfig`：单台服务器。
  - 基本：`alias`（ssh 别名）、`displayName`、`kind`（slurm / direct）、`auth`（key / interactive）、`enabled`、`interval`（nil 表示跟随全局）。
  - 显示：`showCPU/Memory/GPU/Disk`、`watchJobs`、`readProgressFiles`、`processFilter/processExclude`、`watched`（监听的 PID）。
  - 提醒与操作：`muted`、`allowCancel`、`paused`。
  - 连接：`keepAlive`、`reuseConnection`、`importShellPath`、`commands`（`CommandSet`：shell、preamble、squeue、sacct、gpu、gpuApps、processes、progressGlob、disk）。
  - 计算软件：`detectApps`、`appProcessNames`、`slurmAlsoProcesses`（单机 Slurm 时同时显示直接运行的进程）。
- **每个 `init(from:)` 都用 `decodeIfPresent ?? 默认值`**，旧配置文件可以平滑升级。新增字段时照这个写法来。
  - 特例：旧版的默认 squeue 格式没有 `%F|%K` 两列，读取时会自动升级。
- `ConfigStore`：`settings` 改动后 0.5 秒防抖保存；同时更新 `Lang.setting`。

## 轮询引擎（`Monitor/MonitorEngine.swift`）

- `sync()`：1.2 秒防抖，随后进入 `syncNow()`，比较每台主机的新旧配置。
  - 只改了 `displayName / muted / allowCancel` 时，不重连；
  - 只改了 `paused` 时：暂停就停止循环，恢复就立刻刷一次；
  - 全局 `autoRefresh` 或 `defaultInterval` 变了：重新安排所有主机；
  - 其余改动：`restart(host, pollNow: true)`。
- `restart(host, pollNow:)`：取消旧循环。`autoPolls(host)`（全局自动刷新开启且未暂停）为 false 时，只刷一次（如果 `pollNow`）就停。
  - 首次启动时，暂停的主机**完全不连接**。
- 循环里：
  - 睡眠标记（`isAsleep`）最多保持 2 分钟，作为错过唤醒通知时的保险；
  - 失败退避：`base × 2^(n-1)`，最多 15 分钟。
- `pollOnce`：`SSHRunner.run` → `classify`（ssh 本身的错误：超时、拒绝、需要登录…）→ `RemoteScript.parse` → `build()` → 写入快照 → `detectEvents` → `initializeArrays`。
- `build()` 的顺序：
  1. CPU（两次 `/proc/stat` 采样做差）、内存、GPU、磁盘；
  2. 任务：Slurm 用 squeue；直连用 ps（加上计算软件识别到的 pid）；Slurm 且 `slurmAlsoProcesses` 时，再加上不属于任何作业的进程；
  3. 手动监听的 PID：用启动时间（`startedAt` 与 etimes 推算值相差 30 秒以内）识别 PID 被复用的情况；
  4. 计算软件进度合并到对应任务；用两次采样估算速度和剩余时间；输出长时间（≥ max(10 分钟, 5 × 轮询间隔)）不更新时标出"没有新输出"；
  5. 进度文件合并（`~/.serverisland/progress/*.json`）；
  6. Slurm 数组作业合并成一行（`Parsers.groupArrays`），再用 `arrayTracks` 补上已完成和失败的计数。

## 事件识别（`detectEvents`）

第一次成功采样后才开始判断事件。比较上一次和这一次的快照：
- **普通 Slurm 作业消失**：用 sacct 查最终状态。如果查到的状态还是 RUNNING / COMPLETING，20 秒后再查一次。
  - 查不到 sacct，但识别到了计算软件：重新读一次输出文件的最终状态（`AppDetectors.finalStateScript`），据此判断"完成"还是"提前结束"；
  - 既没有 sacct、也没有计算软件信息：发 `info`"已离开队列"，**不报成功**。
- **数组作业**：
  - 排队范围的编号变化（如 `123_[7-99]` 变成 `123_[8-99]`）不算消失；
  - 运行中的元素消失：用一次 sacct 计入成功或失败；
  - 第一次出现失败元素时可提醒一次（`arrayFirstFailureAlert`）；
  - 整个数组都消失后，汇总提醒一次。
- **直连进程消失**：运行 ≥ 30 秒、或者是手动监听的，才算数。有计算软件信息的，先重读最终状态：到达目标是"完成"，否则是"提前结束"（failed）。
- 排队变运行：发 `started`（不响提示音）。
- 磁盘超过阈值时提醒一次，回落 3% 后才会重新提醒。
- 同一次轮询里超过 2 个事件时合并成一条（`flush`）。
- `emit`：静音的主机直接丢弃；之后依次是系统通知、提示音（节流 1.2 秒）、刘海弹窗队列（每条 5 秒）。
- 每个事件都写入 `DebugLog`（`~/Library/Logs/ServerIsland/serverisland.log`），用于排查"为什么没提醒"。

## 按需操作（`MonitorEngine+Actions.swift`）

这些都只在用户点开时才查，不参与轮询：
- `fetchDetail`：Slurm 用 `scontrol show job -o`，查不到时改用 sacct；进程读 `/proc/<pid>/{cmdline,cwd,fd/1,fd/2}`。日志取末尾 40 行，详情页打开期间每 4 秒刷新。
- `cancel`：执行前在服务器上再次核对，对不上就不执行，返回 ABORT：
  - Slurm：作业名一致、属于自己；
  - 进程：属于自己，且已运行时长与预期相差 20 秒以内。
- `fetchHistory`：Slurm 优先用 `sacct -S now-24hours`（数组元素合并成一条）；失败一次就记入 `sacctUnsupported`，之后改用本机的 `HistoryStore`（`history.json`，保留 24 小时）。
- `fetchPartitions`（`Partitions.swift`）：`sinfo` 按节点逐个汇总到分区，统计空闲 GPU 和 CPU；结果缓存 60 秒。
- `topProcesses`、`watch/unwatch`、`toggleMute`、`setPaused`、`setHostInterval`、`setGlobalInterval`、`setAutoRefresh`、`setKind`、`login`、`checkEnvironment`。

## 刘海窗口（`Notch/IslandController.swift`）

- 一个固定大小的 `NSPanel`（`IslandLayout.panelSize`，比最大展开状态还大），放在 `.statusBar + 8` 层，`canJoinAllSpaces`。
- 用全局 + 本地两个 `mouseMoved` 监听做悬停判断：
  - 收起状态下，鼠标进入形状区域 0.14 秒后展开；
  - 展开状态下，鼠标离开形状 + 12pt 的范围后收起：普通页面延迟 0.25 秒，二级页面延迟 0.7 秒；
  - 固定（📌）时不收起；菜单打开期间（`NSMenu` 的 tracking 通知）也不收起。
- **点击穿透**：只有鼠标在形状内时 `ignoresMouseEvents = false`，透明区域的点击会落到下面的窗口。
- `canBecomeKey` 只在"全部任务"页返回 true（那里有搜索框），平时不抢键盘焦点。
- 收起时页面回到 `.list`，并取消固定。

## SSH 与登录（`SSH/`）

- 连接复用：`ControlPath=/tmp/serverisland-<uid>/%C`（unix socket 路径有 104 字节上限，所以放在短路径下）。
  - `key` 认证：`ControlMaster=auto`，`ControlPersist=15m`；
  - `interactive` 认证：`ControlMaster=no`，只复用已有的主连接。
- `BatchMode=yes`：后台绝不等待密码输入。
- 密码 / 动态口令登录（`AskPass.swift`）：
  - 启动 `ssh -fN -o ControlMaster=yes`，环境变量设置 `SSH_ASKPASS=<App 自身可执行文件>`、`SSH_ASKPASS_REQUIRE=force`、`SERVERISLAND_ASKPASS=1`；
  - App 以 askpass 身份被调用时，弹出 NSAlert（密码框或主机指纹确认），把输入写到 stdout；
  - 后台主连接会继承 stderr，所以 stderr 写到临时文件而不是管道，否则永远读不到 EOF；
  - 保活参数：`ControlPersist` 来自 `keepAlive`，`ServerAliveInterval=30`，`ServerAliveCountMax=6`。
- 终端登录：生成一个 `.command` 脚本，用 `NSWorkspace.open` 打开。
- `classify`：把 ssh 退出码 255 的 stderr 翻译成 `needsLogin` 或 `error`。
