# 测试与调试

## 命令行开关（`App/main.swift`）

| 命令 | 用途 |
|---|---|
| `--dump-scripts <目录>` | 导出一组固定配置下的远端脚本（列表在 `App/ReferenceScripts.swift`），给 `SERVERISLAND_SCRIPT_REF=<目录> dotnet run -- --selftest` 做逐字比较 |
| `--check-update [版本]` | 读 GitHub 上最新的 Release 并和当前版本（或假装的版本）比较，打印下载地址和更新说明摘要。C# 版同名开关 |
| `--selftest` | 解析器和脚本自检（squeue、数组、sacct、df、scontrol 的 key=value、NEP/GPUMD/VASP/LAMMPS、自定义规则、曲线、排队原因、bash -n 语法、本机实跑直连脚本、认证方式 / 手动服务器 / 跳板机 / 私有 ssh 配置（用真的 `ssh -G` 解析）/ 弹窗提示语分类 / 跳板机报错归属）。PBS 转换脚本（PBS Pro / Torque 样例）/ 目录过滤 / VASP 最大力 / 日志清理）。目前 109 项 |
| `--render-preview <目录>` | 用演示数据把收起、弹窗、展开、详情、历史、分区、宠物表情、设置窗口（中英文、深浅色）渲染成 PNG |
| `--diagnose <别名或显示名称> [slurm\|direct\|slurm+]` | 对真实服务器跑一次完整采集：原始输出、解析结果、候选进程、第一个进程的详情、24 小时历史。`slurm+` 表示 Slurm 并同时显示直接运行的进程。名字对得上设置里已添加的服务器时，用它的全部连接设置（手动地址、跳板机、认证） |
| `--detail <别名> <pid>` | 只看某个进程的详情和日志末尾 |
| `--partitions <别名>` | 分区空闲资源 |
| `--final-state <别名> <目录>` | 读取某个目录的计算软件最终状态 |
| `--demo` | 演示模式。只有 `DemoData.aliases` 里的主机用假数据，界面上标着"演示"，设置不保存 |

注意：命令行诊断也会写同一份 DebugLog，看日志时要分清哪些行来自 App、哪些来自命令行。

开发用的环境变量（Swift 版和 C# 版都认）：

| 变量 | 用途 |
|---|---|
| `SERVERISLAND_CONFIG_DIR=<目录>` | 用另一份设置（`<目录>/config.json`），私有 ssh 配置也写到这个目录，不碰真实设置和正在运行的 App |
| `SERVERISLAND_SSH_EXTRA_CONFIG=<文件>` | 私有 ssh 配置（以及 C# 的内置 SSH）先读这份额外配置，比如测试用的 `UserKnownHostsFile`，不碰用户的 `~/.ssh` |
| `SERVERISLAND_SSH=managed\|openssh` | 只对 C# 版：`--diagnose` 用哪种 SSH |

## 本机测试登录方式和跳板机（不需要 root，不碰真实服务器）

在草稿目录里起几个用户级的 sshd（只监听 127.0.0.1），用测试专用的密钥：

```bash
ssh-keygen -q -t ed25519 -N '' -f hostkey; ssh-keygen -q -t ed25519 -N '' -f userkey; cp userkey.pub authorized_keys
# 每个 sshd 一份配置：Port 22201 / ListenAddress 127.0.0.1 / HostKey / PidFile / AuthorizedKeysFile 都指向草稿目录，
# StrictModes no、UsePAM no、PasswordAuthentication no、PerSourcePenalties no（OpenSSH 10 会惩罚反复失败的来源，测试时要关掉）
/usr/sbin/sshd -f sshd_jump.conf -E jump.log
```

- 跳板机：一台 22201、一台 22202，在测试用的 `config.json` 里把 22202 的 `jumpHostID` 设成 22201；`LogLevel DEBUG1` 时跳板机日志里能看到 `direct-tcpip`，证明确实经过了跳板机。
- "密钥已通过、还要别的"：`AuthenticationMethods publickey,keyboard-interactive`，密钥模式应提示改成"密钥 + 密码"。
- 每一跳分别询问：给跳板机换一把有口令的密钥，`SSH_ASKPASS` 指向一个记录参数和 `SERVERISLAND_ASKPASS_HOSTID` 的小脚本，应看到口令提示带的是跳板机的 ID。
- 已知 known_hosts：写一份测试用的 known_hosts，用 `SERVERISLAND_SSH_EXTRA_CONFIG` 指向 `UserKnownHostsFile <它>`。
- **测不了**：非 root 的 sshd 不能做密码验证（macOS 上没有 PAM / bsdauth），密码、密钥 + 密码的真实登录要在真实服务器上由用户确认。
- 钥匙串：`security add-generic-password -s ServerIsland -a <UUID> -w <测试密码> -A` 加一条测试项，用 `SERVERISLAND_ASKPASS=1 SERVERISLAND_ASKPASS_SILENT=1 SERVERISLAND_ASKPASS_HOSTID=<UUID> SERVERISLAND_ASKPASS_SESSION=<目录> ServerIsland "Password: "` 直接调 askpass；测完删掉。

## 日志与文件

- 诊断日志：`~/Library/Logs/ServerIsland/serverisland.log`（超过 512KB 轮转成 `serverisland.1.log`；早于"日志保留"天数的行在启动时和每 6 小时删除；时间戳是 `yyyy-MM-dd HH:mm:ss`，旧版本是 `MM-dd HH:mm:ss`，清理时按今年算）。记录每次轮询的结果（任务 id、名称、已运行秒数）、任务结束、被忽略的短进程、每条提醒是否发出、暂停、睡眠、登录。
- 配置：`~/Library/Application Support/ServerIsland/config.json`；历史：同一目录下的 `history.json`。
- 主连接 socket：`/tmp/serverisland-501/<hash>`；手动填写 / 经跳板机的机器是 `<ID 前 8 位>-<hash>`。私有 ssh 配置：`/tmp/serverisland-501/ssh_config`。可以用 `ssh -o ControlPath=/tmp/serverisland-501/%C -O check <别名>` 检查。
  - socket 不存在，说明 App 至少 15 分钟没有连接过这台机器。以前就靠这一点发现过"轮询停了"。

## 看预览图

- 离屏渲染器（`ImageRenderer`）**画不出** `ScrollView` 的内容、`Menu`、`.link` 按钮。预览模式下 `IslandPreview.active = true`，`MaybeScroll` 和菜单会改用普通视图代替。
- 设置窗口不能用 ImageRenderer：做法是建一个离屏 `NSWindow`，循环一会儿 RunLoop，再用 `cacheDisplay` 截取（见 `PreviewRenderer.settingsShot`）。
- 多张图可以用 ffmpeg 拼成一张对照图，一次看完：
  ```bash
  ffmpeg -i a.png -i b.png -i c.png -filter_complex "[0]scale=640:360[a];[1]scale=640:360[b];[2]scale=640:360[c];[a][b][c]hstack=inputs=3" -frames:v 1 sheet.png
  ```
- `screencapture -x <文件>` 可以截整个屏幕（2026-10-17 实测可用），用来看刘海的静止状态；但没法移动鼠标，真实刘海的悬停、长按、菜单交互仍然要请用户自己试。

## Windows / Linux 版

命令和验证方法见 `cross-platform.md`。要点：`dotnet run -- --selftest`（137 项）、`--render-preview`、`--ui-smoke`（真实窗口走查，Windows / Linux 真机和 CI 上都能跑）、`SERVERISLAND_SSH=managed … --diagnose`（用内置 SSH 只读采集）。改了两边共用的远端脚本后，按 `cross-platform.md` 做一次逐字比对。

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
