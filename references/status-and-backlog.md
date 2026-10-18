# 进度与待办

> 最近更新：2026-10-17。每次完成一轮工作后更新这一份。

## 版本

- App：0.2.0（`Resources/Info.plist` 和 `cross/Directory.Build.props` 一起改；2026-10-18 从 0.1.0 升上来，见 CHANGELOG.md）。GitHub 上最新的 Release 还是 v0.1.0，0.2.0 的三个安装包已打好但还没上传。
- git：https://github.com/zhyan0603/ServerIsland 。2026-10-17 重建了干净的历史（旧历史备份在仓库外的 `serverisland-history-backup-2026-10-17.bundle`），本仓库的提交作者用 GitHub 隐私邮箱。
- 安装包（2026-10-18）：`build/ServerIsland-0.2.0.dmg`（通用二进制，ad-hoc 签名）、`build/ServerIsland-0.2.0-win-x64.zip`、`build/ServerIsland-0.2.0-linux-x64.tar.gz`。
- 宣传视频：`promo/out/ServerIsland-v0.1.mp4`。

## 已完成（按轮次）

1. 骨架：SSH 轮询 + ControlMaster、Slurm 和直连两种类型、刘海 UI、设置页、logo、`build_app.sh`。
2. 修复演示数据泄漏和弹窗刷屏；进程排除规则；像素小章鱼 Tako 和 6 种心情；新 logo。
3. 任务详情和日志末尾、防误触的取消、监听 PID、磁盘提醒、24 小时历史、静音、提示音（成功和失败区分开）。
4. 修复"任务结束没提醒"（加了 DebugLog）；Job Array；动态口令弹窗登录和保活；固定面板；全部任务页；复制；自定义间隔；登录时启动；UI 美化。
5. 新 logo（像素字）；暂停单台服务器；刘海里的轮询菜单；只手动刷新。
6. NEP / GPUMD 识别；排队原因翻译；分区空闲资源；结束时重读最终状态。
7. PATH 补全和"环境"分组；单机 Slurm + 直接运行的进程；用 environ 映射作业；设置页按 ID 绑定；中英文；ⓘ 提示；修复标题栏重叠。
8. DMG 方案 A；宣传视频。
9. 本文档、AGENTS.md。
10. 每台服务器卡片标题显示自己的运行 / 排队数（`JobCountChips`）；修复"演示"徽章折行、演示数据里数组行没有英文。
11. 数量胶囊悬停说明"数组按元素算"；数组状态文字分段上色（运行蓝、排队灰、失败红，和进度条一致），进度条悬停显示图例；展开面板里合并空闲服务器（`foldIdleHosts`，默认开，全部空闲时不合并，收起面板后自动折回）。
12. VASP（MD 百分比；优化 / 单点只显示离子步 / 电子步）和 LAMMPS（最后一段 run）识别，对不上就不显示；自定义进度识别规则（设置 → 进度识别，可在真实目录上测试）；结束标记参与完成 / 提前结束判断；默认进程名加上 vasp_* 和 lmp*。自检增加到 59 项。
13. 详情页小曲线：NEP / GNEP loss（对数坐标，多列）和 VASP 结构优化离子步能量；增量读取，打开详情页时才读。新增 `--curve` 调试开关。自检 65 项。
14. 官网第一版（`site/`，GitHub Pages 工作流）；演示数据换成计算材料场景并去掉隐私信息；宣传视频同步修改并重新渲染；`--render-preview` 支持指定语言；`scripts/site_shots.sh`。
15. 改为开源（GPL-3.0，版权 Zihan Yan 和贡献者；README 重写成热门开源项目的样子，顶部是真实界面拼成的动图 `docs/demo-{en,zh}.gif`，由 `scripts/readme_assets.sh` 生成）：放弃收费方案；README 改成英文 + `README.zh-CN.md`，加 LICENSE、CONTRIBUTING；官网加 GitHub 链接和开源分区；私有文档挪到被忽略的 `references/private/`，公开文档里的真实主机名、路径都改成通用说法。
16. README 改成 GPUMDkit 的版式（logo + 链接行 + 徽章 + 简介）；原理图改成自己画的 SVG（中英文、深浅两版）；截图改成只有面板本身、透明背景（`SI_BARE=1 --render-preview`），整宽显示。
17. 准备发布 v0.1.0：设置 → 通用加了"点个 Star / 反馈问题"按钮；DMG 安装说明补上 macOS 15 的步骤；CHANGELOG.md。
18. Windows / Linux 版（`cross/`，当时在 avalonia 分支，现在是 dev，C# + Avalonia）：逐文件移植核心逻辑（远端脚本和 Swift 版逐字一致），虚拟刘海 + 桌面小章鱼 + 托盘，内置 SSH（SSH.NET，Windows 默认）；自检 71 项、`--render-preview`、`--ui-smoke`；CI 工作流 `cross.yml` 在 GitHub 的 Windows / Linux 机器上跑自检和界面走查并打包。用户已在 Windows 真机上试用，修了"桌宠切回灵动岛位置不对"。还可以打包成 `ServerIsland Preview.app` 在 Mac 上试用（`cross/scripts/build_mac_preview.sh`）。详见 `references/cross-platform.md`。
19. 连接方式（两个版本都做了）：认证方式分成"密钥 / 密码 / 密钥 + 密码 / 动态口令"（旧配置的 `interactive` 读成"动态口令"）；不写 `~/.ssh/config` 也能手动填地址、用户名、端口、私钥；跳板机（选另一台 ServerIsland 服务器，可多级，每一跳分别询问、分别报错，已登录的跳板机直接复用）；"记住密码"（默认关，只存系统钥匙串 / Windows 凭据管理器 / Linux Secret Service，断线后自动重新登录，10 分钟内最多一次）。系统 ssh 用 App 私有的 ssh 配置（`ssh -F`，不改 `~/.ssh/config`）。修了内置 SSH"只要密码"重试时丢掉密钥的问题。自检 Swift 88 项、C# 94 项；本机用户级 sshd 测过多级跳板、密钥通过后还要密码的提示、每一跳的报错归属和弹窗归属。

20. 2026-10-18（两个版本都做了）：PBS 集群（PBS Pro / OpenPBS / Torque，远端把 `qstat -f` 转换成 squeue 格式，复用 Slurm 的全部逻辑；qdel 取消、qstat -x 查结束状态、PBS_JOBID 映射进程）；每台服务器"只看这些目录"（按作业工作目录 / 进程当前目录过滤）；VASP 结构优化详情页加"最大力"曲线（OUTCAR 的 TOTAL-FORCE，虚线是 |EDIFFG|），和能量曲线并排；诊断日志保留天数（默认 7 天，启动时和每 6 小时清理）和"清除日志"按钮。Swift 版加了 `--dump-scripts`，两边 22 个脚本逐字一致。自检 Swift 109 项、C# 137 项。

21. 官网三个页面的页脚加了访问量统计（不蒜子 busuanzi，和 GPUMDkit 网站一样；脚本被拦截时不显示）。

22. 2026-10-18 检查更新（两个版本）：设置 → 通用 有"检查更新"按钮和"自动检查更新"开关（默认开，启动 20 秒后和每 24 小时一次）。读 GitHub `releases/latest`，按数字比较版本号；有新版本时刘海提醒一次（同一版本只提醒一次），菜单栏 / 托盘菜单多一项"下载新版本"，下载按钮直接指向当前平台的安装包（.dmg / win-x64.zip / linux-x64.tar.gz）。只提示，不自动替换程序；真正的应用内更新见想法池（Sparkle / Velopack，最好先有 Developer ID 签名）。开发用 `--check-update [假装的版本]`。自检 Swift 113 项、C# 119 项（加上逐字比较 141 项）。
- 数据目录说明：发布版的设置和日志目录从 0.1.0 起没变过（Mac `~/Library/Application Support/ServerIsland`、`~/Library/Logs/ServerIsland`；Windows `%APPDATA%\ServerIsland`；Linux `~/.config/ServerIsland`），升级不会丢设置。带 `-Avalonia` 的目录只有"在 Mac 上试用的跨平台版"会用，是为了不覆盖 Swift 版的设置。

23. 2026-10-18 VASP 力和 NEB（两个版本）：最大力优先用 VTST 的 `FORCES: max atom, RMS` 行，没有时按 POSCAR 的 Selective dynamics 去掉固定方向再算；EDIFFG 先从 OUTCAR 读，≥ 0 时显示"按能量收敛"；加了淡色"最低"线（CG 的试探步会让力上下跳）；C# 版图例重叠修好，并加了 `--curve`。NEB 识别（INCAR 的 IMAGES + 01/OSZICAR）：能垒图（能量曲线 + 每个像点的力柱 + EDIFFG 虚线）和能垒随离子步的变化，在真实算例上和 nebef.pl 一致（算例放在本地 `test/`，不进仓库；`SI_NEB_CASE=<目录>` 让自检打印真实结果）。自检 Swift 122 项、C# 151 项（23 个脚本逐字一致）。

24. 2026-10-18（两个版本）：分区页认出曙光的 DCU（Gres 里的 `dcu`，以及 `npu` / `mlu`），按种类显示"空闲 DCU"；私钥文件权限太宽（ssh 报 `bad permissions` 后忽略密钥）时直接提示 `chmod 600 <文件>`（Windows 提示改文件属性 → 安全），不再误报成"密钥登录失败，服务器也接受密码"。直连服务器的 DCU（`hy-smi` / `rocm-smi`）还没做。自检 Swift 124 项、C# 153 项。

25. 2026-10-18（两个版本）：悬停说明加快到 0.25 秒（Mac 改 NSInitialToolTipDelay，跨平台版改 ToolTip.ShowDelay）；设置 → 通用加"显示在 / 灵动岛显示在"（`islandScreen`：自动 / 主屏幕 / 某块显示器，没连接时退回自动）。Mac 的"自动"最后一步从 NSScreen.main（跟着聚焦窗口变，没有内建屏幕的 Mac 接两台显示器时会来回跳）改成主屏幕。数组进度条本来就是"整个数组完成了多少"，但排队元素只认 %K 带方括号的写法，不带时一整段范围被算成 1 个，进度条偏满；改成以编号里的 `_[...]` 为准。sacct 不可用时，悬停说明里注明完成数可能偏少。

26. 2026-10-18（两个版本）：历史记录。本机记录保留 7 天（以前 24 小时），设置 → 通用 → 文件与诊断 有"清除历史记录…"（只删已结束任务的记录，运行中任务的记忆保留），每条带工作目录（主轮询总是带 `workdirs` 段；sacct 历史加 WorkDir 列），历史页每条下面有目录、复制和"在终端打开"。页面标题改成"历史记录"，Slurm 把 sacct 的最近 24 小时和本机记录合并。记住上次看到的运行中任务（`active-jobs.json`），ServerIsland 退出期间结束的任务下次启动时补记（"已结束 · ServerIsland 未运行时结束"）。在一台单机 Slurm 工作站上只读 `--diagnose` 过，workdirs 段正常、一次采集 1.7 秒。

## 尚未验证（需要用户确认或等真实任务）

- 刘海的真实交互：悬停、长按取消、原生菜单（间隔菜单）、全部任务页的搜索框（能否获得键盘焦点）、ⓘ 悬停提示、切换语言。这些都没法自动截图。
- 动态口令登录：askpass 弹窗、多步验证、保活。用户的动态口令集群还没有加进来。
- 密码、密钥 + 密码的真实登录（本机 sshd 不能做密码验证）；"记住密码"弹窗勾选框、钥匙串写入后的自动重新登录；Windows 凭据管理器（只在 Mac 上编译过）；Linux 的 secret-tool；有用户的"密钥 + 密码"集群和跳板机用户的环境里实测。
- PBS：没有真实集群，只用 PBS Pro / Torque 的样例文本测过转换脚本（Mac 的 BSD awk；Linux CI 上是 mawk）。真实集群上的数组、`qstat -x`、Output_Path、qdel 都需要用户确认。
- 历史记录的"退出期间结束的任务补记"：只用临时目录的自检测过存取，还没在真实的"退出 App → 作业结束 → 再打开"流程里看过。
- 最大力曲线：已在一个真实的 CG 优化上核对过；VTST 和 Selective dynamics 只用构造的文件测过。
- NEB：只在一个本地算例上测过（读文件），还没在服务器上的运行中 NEB 任务上看过刘海和详情页。
- 真实的 VASP、LAMMPS 任务（只用假文件和 mawk 管道测试过），以及设置页"测试"按钮在真实服务器上的表现。
- 真实的 GPUMD 模拟任务，以及通过 Slurm 提交的真实 NEP 作业（只用假文件测试过 environ 映射）。
- 大型集群上真实的数组作业，以及数组首个失败提醒、汇总提醒。
- 登录时启动（需要把 App 放进"应用程序"文件夹后再试）。
- DMG 在另一台 Mac 上第一次打开时的体验；Intel Mac 上能否运行。
- Windows / Linux 版尚未验证的部分见 `references/cross-platform.md` 末尾（Linux 由用户自己在真机上测）。
- 宣传视频的配乐好不好听（只做过响度和结构的客观检查）。

## 已知限制

- Slurm 登录节点上看不到计算节点的 GPU 和进程，计算软件识别只能用作业的提交目录（`%Z`）。作业脚本 cd 进子目录时就识别不到（单机 Slurm 没有这个问题）。
- 没有开启作业记录的 Slurm：作业结束的结果只能依靠计算软件的输出判断，否则显示"已离开队列"。
- 刘海只显示在带刘海的内建屏幕上；没有刘海的屏幕显示一个虚拟刘海。没有做多显示器的选择。

## 跨平台版待办

- 降低空闲 CPU（Mac 上试用版 3–4%），详见 `cross-platform.md` 的"已知问题"。
- Linux 真机测试（用户自己测）。
- 决定：长期保持 Swift（Mac）+ C#（Windows / Linux）两个版本，见 `cross-platform.md` 的"决策记录"。

## 想法池（用户尚未决定，参见 user-preferences.md）

关注某个 Slurm 作业 → 方案 B 签名公证和 Sparkle → 配置导入导出 → 竖屏或英文版宣传视频。
