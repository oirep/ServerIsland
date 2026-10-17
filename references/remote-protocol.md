# 远端脚本协议

所有远端操作都是：`ssh <alias> <commands.shell>`（默认 `bash -l -s`），把脚本从 stdin 送过去。
`SSHRunner.run` 会自动在脚本最前面加上 **`pathPrelude`**（`importShellPath` 关闭时不加）。

## PATH 补全（`SSHRunner.pathPrelude`）

- **背景**：Ubuntu 默认的 `~/.bashrc` 开头写着"非交互 shell 直接 return"，非交互登录读不到后面加的 PATH。比如有的单机 Slurm 工作站，Slurm 装在 `~/software/slurm/install/bin`，就是在这一行之后加进 PATH 的。
- **做法**：用 grep 找出 `~/.bashrc`、`~/.bash_profile`、`~/.profile`、`~/.zshrc` 里的 `PATH=` 行，展开 `~`、`$HOME` 和 `${HOME}`，跳过含其它变量的条目，把实际存在的目录**追加**到 PATH 末尾（只追加，不覆盖）。另外固定追加 `/opt/slurm/bin` 和 `/usr/local/slurm/bin`。
- 这个过程不启动交互式 shell：交互式 shell 会触发 conda init、欢迎信息等，可能卡住，也会污染输出。
- 用户还可以在"连接后先执行"（`commands.preamble`）里写 `source …` 或 `module load …`。各脚本生成函数会把 preamble 放在脚本最前面。

## 输出标记

```
@@SI:BEGIN
@@SI:SEC <名字>      一段开始
...                 该段命令的输出（stderr 也并进来）
@@SI:RC <退出码>     一段结束
@@SI:END
```
段内还可能出现这些特殊行：

| 标记 | 含义 |
|---|---|
| `@@SI:NA` | 命令不存在（例如没有 nvidia-smi） |
| `@@SI:FILE <路径>` | 进度文件的开头 |
| `@@SI:DIR <任务ID>\|<目录>` | 计算软件识别的一个条目 |
| `@@SI:PATH <路径>` | 日志文件路径 |
| `@@SI:NOFILE <目标>` | 输出不是普通文件（tty、socket、pipe） |
| `@@SI:UNREADABLE` | 日志文件读不到 |
| `@@SI:ABORT <原因>` | 取消前的核对没通过，没有执行 |
| `@@SI:DONE` | 取消命令已执行 |

`BEGIN` 之前的内容（比如 `.bashrc` 打印的欢迎信息）一律忽略。退出码不为 0 的段会变成卡片上的一条 warning。

## 轮询脚本（`RemoteScript.build`）的各段

| 段 | 条件 | 命令 |
|---|---|---|
| `cpu` | showCPU | `head -n1 /proc/stat; nproc; cat /proc/loadavg` |
| `mem` | showMemory | `/proc/meminfo` 里的 MemTotal 和 MemAvailable |
| `gpu`、`gpuapps` | showGPU，或者需要列进程 | nvidia-smi（没有就输出 NA） |
| `squeue` | Slurm 且 watchJobs | `squeue -u $(id -un) -h -o '%i\|%j\|%T\|%M\|%l\|%D\|%R\|%P\|%F\|%K'` |
| `procs` | 直连；或 Slurm 且 slurmAlsoProcesses | `ps -u … -o pid=,etimes=,pcpu=,rss=,args= --sort=-pcpu \| head -300` |
| `slurmpids` | Slurm 且 slurmAlsoProcesses | 属于 Slurm 作业的进程（用 `si_jobid` 判断），这些进程不再单独列出 |
| `apps` | detectApps 且 watchJobs | 计算软件识别（见下文） |
| `watch` | 直连且有监听的 PID | `ps -p <pids>`（不加 `-u`） |
| `disk` | showDisk | `df -P -k ~` |
| `progress` | readProgressFiles | 逐个 `cat` 进度文件 `~/.serverisland/progress/*.json`（每个最多 4KB） |

squeue 的解析是**从两端按位置取列**，所以作业名里有 `|` 也能正确解析；也兼容没有 `%F|%K` 两列的老格式。数组作业从 `%F`/`%K` 识别，没有这两列时从编号 `123_5` 或 `123_[7-99%10]` 里拆出来。

其它脚本：
- `sacctScript`：`{jobs}` 替换成作业号列表；
- `detailScript`、`cancelScript`：作业号经过 `safeSlurmID`（只允许 `^\d+(_\d+)?$`），PID 必须是纯数字；
- `historyScript`、`topProcessesScript`、`detectScript`（另外检测本机是否在运行 slurmd）；
- `Partitions.script`：
  - `sinfo -h -o '%P|%a|%l'`：分区汇总；
  - `sinfo -N -h -O 'NodeList,Partition,StateCompact,CPUsState,Gres,GresUsed'`：逐个节点，按空白切分。

## 计算软件识别（`Monitor/AppDetectors.swift`）

参考的是 GPUMDkit Web Console（GPUMDkit 仓库里 `Scripts/utils/server/server.py` 的 `training_status` 和 `simulation_status`），但不做实时刷新，跟着普通轮询走。

1. **候选目录**：
   - Slurm：`squeue -t R -o '%i|%Z'`，也就是作业的提交目录；
   - 本机进程，满足任一条件：进程名匹配 `pgrep -x '<appProcessNames>'`（默认 `gpumd|nep|gnep`）、在 nvidia-smi 的计算进程里、CPU ≥ 50%、或者（Slurm 机器上）属于 Slurm 作业。取它们的 `readlink /proc/<pid>/cwd`；
   - 进程属于哪个 Slurm 作业：用 shell 函数 `si_jobid` 读 `/proc/<pid>/environ` 里的 `SLURM_JOB_ID`（数组元素则用 `SLURM_ARRAY_JOB_ID_SLURM_ARRAY_TASK_ID`）。**不要用 cgroup 判断**：有些 Slurm 安装不会把 job_N 写进 cgroup。
   - 用 `awk '!seen[$2]++'` 按目录去重，每个目录只算一个任务。
2. **由目录里的文件决定软件类型**（`dirBody`）：
   - `loss.out` + `nep.in` → NEP：目标是 `generation`（没写时默认 100000，并标记 `hasTarget=false`）；当前代数和各项 loss 取自 `tail -n 1 loss.out`；
   - `loss.out` + `gnep.in` → GNEP：目标是 `epoch`（默认 50）；
   - （VASP、LAMMPS、自定义规则见下一节）
   - `run.in` + (`neighbor.out` | `thermo.out`) → GPUMD：目标是所有 `run N` 之和；当前步数优先取 `neighbor.out` 最后一行（`Neighbor info at step N: radial(max=,actual=), angular(...)`），否则用 `thermo.out` 的有效行数 × `dump_thermo`；
   - 同时输出 `mtime=$(stat -c %Y …)`，用来判断输出是否停止更新。
3. loss.out 的列：`gen Total L1 L2 Energy Force Virial [E-test F-test V-test]`（7 列及以上），或者 `epoch Loss Energy Force Virial`。test 列全为 0 时不显示。
4. 速度由引擎在两次采样之间计算（`applyAppRate`：指数平滑；数字倒退时重置）。

### VASP / LAMMPS / 自定义规则（2026-10-17）

**总原则（用户定的）**：任何一处和预期不一致（文件缺失、格式对不上、数字矛盾），就当作没识别到，**不输出、不显示进度**。远端只负责把原始信息吐出来，判断都在 Swift 里（`parseVasp` / `parseLammps` / `ProgressRule.extract`），返回 nil 就丢弃。

- **VASP**（`INCAR` + `OSZICAR`）：
  - INCAR 用 awk 取 NSW / IBRION（去掉 `!` `#` 注释，支持 `;` 分隔，大小写不敏感）；写法不是整数就放弃；
  - `tail -n 3000 OSZICAR`：离子步是"第 1 列整数且第 2 列以 F= / T= 开头"的行；电子步是 `DAV:` `RMM:` `CG :` 这类行的第一个数字；
  - NSW ≤ 0 → 单点，显示电子步；IBRION=0 → MD，离子步 / NSW（超过 NSW 就放弃）；IBRION=1/2/3 → 结构优化，**只显示离子步，没有百分比**；其它 IBRION（声子等）放弃；
  - 结束标记：`tail -n 400 OUTCAR` 里有 `General timing and accounting` → `done=1`。没有 OUTCAR 时不输出 done。
- **LAMMPS**（`log.lammps`，只看常见的 MD）：
  - `grep -n` 找最后一个 `run` 命令行，从那一行开始 `tail -n +L` 交给 awk；
  - 第一行必须是 `run <整数>`（不能带 upto / every；变量没展开就放弃）；之后找含 `Step` 列的 thermo 表头，数据行要求列数一致且全是数字；
  - 当前 = 最后一行 Step − 这段 run 第一行 Step，目标 = run 的步数；
  - 遇到 minimize / rerun、多余的表头、`thermo_style multi` → `bad=1`；
  - 结束标记：`tail -n 30` 里有 `Total wall time` → `done=1`。
- **结束标记的作用**（`AppProgress.endMarker`）：有标记时 `finished` 以标记为准；`canJudge = endMarker != nil || hasTarget`，进程 / 作业结束时用它决定能否提醒"完成 / 提前结束"。
- **自定义规则**（`Models/ProgressRule.swift`，存在 `AppSettings.progressRules`，所有服务器通用，排在内置识别**之前**）：
  - 文件名只允许 `[A-Za-z0-9._-*?/+]`（会原样放进 shell 做通配，`si_pick` 取最新的匹配）；关键字、结束标记等一律 `shellQuote`；
  - 关键字模式：远端 `grep -aiF 关键字 | tail -n 5`；Swift 里用"关键字 + 可选的 :=# + 数字 + 可选的 /N 或 of N"匹配，不区分大小写；
  - 正则模式：远端 `tail -n 40`，Swift 里用 NSRegularExpression，第 1 组当前值，第 2 组目标值；
  - 目标值优先级：同一行里的 /N → 固定目标值 → 目标值文件里关键字后的数字；当前值超过目标值就放弃；
  - 规则匹配到了文件但取不到数字时，**不会再退回内置识别**（elif 链已经进了这个分支）。
- 设置页"测试"：`AppDetectors.ruleTestScript` 先报告目录 / 文件是否存在，再只跑这一条规则；`interpretTest` 给出结果或失败原因 + 文件最后几行。只读。
- 自检 `SelfTestApps` 在本机临时目录造假文件，用 `/bin/bash` 真正执行脚本；另外已在一台 Ubuntu 工作站上用 mawk 1.3.4 + GNU grep 3.11 验证过三段 awk（只通过 stdin 喂样例，没有写文件）。

### 详情页曲线（`Monitor/AppCurves.swift`，2026-10-17）

- 只有 NEP / GNEP 的 loss 和 VASP 结构优化每个离子步的 E0。**只在详情页打开时读**：第一次立即读，之后每 20 秒一次（日志末尾仍是 4 秒）。
- 增量：`MonitorEngine.curveCaches`（键是 主机 + 文件路径）记住已读行数和文件第一行。脚本把偏移量和第一行一起传过去，服务器上比较：第一行变了或文件变短 → `reset=1` 从头读；一次最多 5 万行。
- `head -n $((n-off))` 只取 `wc -l` 数到的完整行，正在写的半行下次再读。
- 输出：`n=`、`head=`、可选的 `reset=1`，再加上 `row=` 开头的数据行。loss.out 只保留第一列是整数的行；OSZICAR 只取"步号 + E0"两列。
- 画图：点数超过 400 时等间隔抽样；loss 用对数坐标。
- 实测：一台工作站上 579 行的 loss.out 第一次传 72 KB / 0.07 s，之后没有新行时只传 131 字节。

### 新增一种软件（比如 VASP、LAMMPS）
1. 在 `AppProgress.Kind` 里加一个 case，补上 `title`、`unit`、`summary`；
2. 在 `AppDetectors.dirBody` 里加一个 `elif` 分支：用特征文件判断，输出 `@@SI:DIR`、`kind=…`、`total=…`、`last=…`、`mtime=…` 等 key=value；
3. 在 `AppDetectors.parse` 的 `switch kind` 里解析这些字段；
4. 在 `SelfTest` 里加一条样例输出的解析测试，再用 `--final-state <alias> <目录>` 在真实目录上验证。
5. **只读文件末尾或小文件**（tail、awk、grep -c），不要整读大文件。
