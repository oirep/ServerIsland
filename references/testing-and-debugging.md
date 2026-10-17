# 测试与调试

## 命令行开关（`App/main.swift`）

| 命令 | 用途 |
|---|---|
| `--selftest` | 解析器和脚本自检（squeue、数组、sacct、df、scontrol 的 key=value、NEP/GPUMD、排队原因、bash -n 语法、本机实跑直连脚本）。目前 37 项 |
| `--render-preview <目录>` | 用演示数据把收起、弹窗、展开、详情、历史、分区、宠物表情、设置窗口（中英文、深浅色）渲染成 PNG |
| `--diagnose <别名> [slurm\|direct\|slurm+]` | 对真实服务器跑一次完整采集：原始输出、解析结果、候选进程、第一个进程的详情、24 小时历史。`slurm+` 表示 Slurm 并同时显示直接运行的进程 |
| `--detail <别名> <pid>` | 只看某个进程的详情和日志末尾 |
| `--partitions <别名>` | 分区空闲资源 |
| `--final-state <别名> <目录>` | 读取某个目录的计算软件最终状态 |
| `--demo` | 演示模式。只有 `DemoData.aliases` 里的主机用假数据，界面上标着"演示"，设置不保存 |

注意：命令行诊断也会写同一份 DebugLog，看日志时要分清哪些行来自 App、哪些来自命令行。

## 日志与文件

- 诊断日志：`~/Library/Logs/ServerIsland/serverisland.log`（超过 512KB 轮转）。记录每次轮询的结果（任务 id、名称、已运行秒数）、任务结束、被忽略的短进程、每条提醒是否发出、暂停、睡眠、登录。
- 配置：`~/Library/Application Support/ServerIsland/config.json`；历史：同一目录下的 `history.json`。
- 主连接 socket：`/tmp/serverisland-501/<hash>`。可以用 `ssh -o ControlPath=/tmp/serverisland-501/%C -O check <别名>` 检查。
  - socket 不存在，说明 App 至少 15 分钟没有连接过这台机器。以前就靠这一点发现过"轮询停了"。

## 看预览图

- 离屏渲染器（`ImageRenderer`）**画不出** `ScrollView` 的内容、`Menu`、`.link` 按钮。预览模式下 `IslandPreview.active = true`，`MaybeScroll` 和菜单会改用普通视图代替。
- 设置窗口不能用 ImageRenderer：做法是建一个离屏 `NSWindow`，循环一会儿 RunLoop，再用 `cacheDisplay` 截取（见 `PreviewRenderer.settingsShot`）。
- 多张图可以用 ffmpeg 拼成一张对照图，一次看完：
  ```bash
  ffmpeg -i a.png -i b.png -i c.png -filter_complex "[0]scale=640:360[a];[1]scale=640:360[b];[2]scale=640:360[c];[a][b][c]hstack=inputs=3" -frames:v 1 sheet.png
  ```
- 没有屏幕录制权限，`screencapture` 不能用。真实刘海的悬停、长按、菜单交互，需要请用户自己试。

## 在用户真实服务器上测试的守则

1. 先用只读的方式：`--diagnose`、`--detail` 等。
2. 需要造一个测试任务时：先告诉用户；只占 CPU、时间短（≤ 2 分钟）、自己会结束；放在 `/tmp` 下；测完删除。
   - 例子：`sbatch -J si_test_nep -c 1 --mem=100M -t 5 --wrap "…"`，在 `run/` 子目录里写一个假的 `nep.in` 和 `loss.out`。
3. **不要**在用户的服务器上执行 scancel / kill。取消功能只做 `bash -n` 语法检查，加上"取消前核对"逻辑的单元测试。
4. 用 `pgrep -f` 检查测试进程时，小心匹配到检查命令自己。

## 排查过的典型问题

| 现象 | 原因 | 修复 |
|---|---|---|
| 演示数据出现在用户的服务器上，弹窗不停 | 用 `--demo` 启动后，所有主机都用了假数据 | 演示数据只给 `DemoData.aliases` 里的主机 |
| 任务结束了却没有提醒 | 曾经有一条"运行不到 2 分钟的进程不提醒"规则；另外轮询停了 | 阈值改为 30 秒；睡眠标记加 2 分钟超时；加了 DebugLog |
| NEP 训练完成却报"提前结束" | 最后一次采样还没到目标 | 任务结束时重读一次最终状态 |
| 单机 Slurm 工作站报 squeue 找不到 | squeue 在 `~/.bashrc` 非交互 return 之后才加进 PATH | 加了 pathPrelude；设置里有"环境"分组 |
| 服务器被存成了错误的类型 | 设置详情页按数组下标绑定，异步检测结果写错了位置 | 改成按 ID 绑定；`setKind` 按 ID 写回 |
| 识别不到 Slurm 作业所在的目录 | 这台机器的 Slurm 不把 job_N 写进 cgroup；作业脚本又 cd 进了子目录 | 改用 `/proc/<pid>/environ` 里的 SLURM_JOB_ID |
