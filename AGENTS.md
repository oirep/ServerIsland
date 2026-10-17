# AGENTS.md — ServerIsland

> 给 AI 编码助手（以及新加入的开发者）看的项目说明。**新会话开始时先读这一份，再按需读 `references/` 里的专题文档。**
> 项目开源（GPL-3.0，版权人 Zihan Yan 和贡献者）。维护者用中文交流。界面文案是中英双语，用 `L("中文", "English")` 写。

## 这是什么

ServerIsland 是一个 macOS 菜单栏 / 刘海（灵动岛风格）App：通过 SSH 定时查看服务器上的任务和资源，主要场景有三类：
- **Slurm 集群**：作业、数组作业、排队原因、分区空闲资源；
- **直连服务器**：进程、GPU；
- **计算软件进度**：NEP / GPUMD / VASP / LAMMPS 自动识别，另可自定义规则。

刘海里住着一只像素小章鱼 **Tako**，它的心情随服务器状态变化。

设计原则：**轻量**（服务器端不装任何东西；每台机器每个周期只开一个 SSH 通道，并复用连接）、**不误报**、**危险操作要多重确认**。

## 技术栈

| 部分 | 技术 |
|---|---|
| App | Swift 5.10 + SwiftUI + AppKit。SwiftPM 可执行目标（`Package.swift`），最低支持 macOS 14 |
| 工具链 | **只有 Command Line Tools，没有 Xcode**（SDK 14.4）。不能用 Xcode 工程、Previews、`@Observable` 宏（用的是 `ObservableObject`） |
| SSH | 调用系统 `/usr/bin/ssh`，用 ControlMaster 复用连接。需要密码的机器通过 `SSH_ASKPASS` 弹原生对话框登录 |
| 远端 | 一段 bash 脚本经 stdin 传给 `bash -l -s`，输出用 `@@SI:` 标记分段 |
| 资源 | Python 脚本生成 logo（SVG）和提示音（WAV）；`scripts/render_svg.swift` 用 WebKit 渲染 SVG |
| 打包 | `scripts/build_app.sh` 打包 .app，`scripts/make_dmg.sh` 制作 DMG（通用二进制，ad-hoc 签名） |
| 宣传视频 | `promo/`：Canvas 2D + JS 时间轴，Python 合成配乐，puppeteer-core 驱动系统 Chrome 逐帧截图，FFmpeg 合成 |

## 目录

```
Sources/ServerIsland/
  App/        main.swift（命令行开关）、AppDelegate（菜单栏、通知）、SelfTest / SelfTestApps（自检、诊断）、PreviewRenderer（离屏渲染预览图）
  Models/     Config.swift（全部设置项，Codable，缺字段自动补默认值）、Snapshot.swift（运行时数据）、ProgressRule（自定义进度识别规则）
  SSH/        SSHRunner（ssh 调用、连接复用、错误归类、PATH 补全）、AskPass（密码弹窗）、SSHConfigParser
  Monitor/    MonitorEngine（轮询循环、事件识别）、+Actions（详情、取消、历史、监听、登录、检查命令）
              RemoteScript（远端脚本生成与解析）、Parsers、AppDetectors（NEP/GPUMD/VASP/LAMMPS/自定义规则）、AppCurves（详情页曲线，增量读取）、PendingReason、Partitions、HistoryStore、DemoData
  Notch/      IslandController（NSPanel、悬停、点击穿透）、IslandView（根视图、收起两翼、弹窗、展开面板）
              IslandLayout（确定性尺寸）、HostCard、IslandPages（详情、历史、监听、全部任务、分区、数组概览）、CurveChart、NotchGeometry
  Settings/   SettingsView（窗口、侧栏、通用页）、HostDetailView（单台服务器页）、ProgressRulesView（进度识别页、规则编辑与测试）、SettingsControls（间隔选择、开机启动、标题）
  Shared/     Localization（L()、HelpLabel）、Pet（Tako 精灵）、Theme、Components、Format、SoundPlayer、DebugLog
Resources/    Info.plist、AppIcon.icns、Sounds/*.wav
Branding/     logo.svg、menubar.svg（由 scripts/gen_branding.py 生成）及导出的 PNG
scripts/      build_app.sh、make_dmg.sh、site_shots.sh（官网截图）、readme_assets.sh（README 素材）、gen_branding.py、gen_sounds.py、render_svg.swift
remote/       si-progress（放到服务器上的进度上报小工具）
promo/        发布视频源码（见 references/promo-video.md）
site/         官网（纯静态，GitHub Pages；见 references/website.md）
docs/         README 用的动图、截图、原理图（architecture[.zh].svg 是源文件）
references/   专题文档（见下）
```

## 常用命令

```bash
swift build                                          # 调试构建（会打印 "xcrun: error: PlatformPath" 两行，属于无害噪音）
.build/debug/ServerIsland --selftest                 # 解析 / 脚本自检（目前 65 项，应全部 ✓；其中计算软件识别会用本机 bash 跑假文件）
./scripts/build_app.sh --run                         # release 构建 + 打包 + 重启 App
./scripts/make_dmg.sh                                # → build/ServerIsland-<版本>.dmg
.build/debug/ServerIsland --render-preview <目录> [zh|en]  # 把刘海 / 页面 / 设置窗口渲染成 PNG（演示数据）
./scripts/site_shots.sh                              # 重新生成官网截图
./scripts/readme_assets.sh                           # 重新生成 README 的动图、截图和原理图（docs/）
.build/debug/ServerIsland --diagnose <别名> slurm+    # 对真实服务器跑一次完整采集并打印（slurm | direct | slurm+）
.build/debug/ServerIsland --curve <别名> <目录> [gnep|vasp]  # 只读：读两次详情页曲线，检查增量读取
open build/ServerIsland.app --args --demo            # 演示模式
```

完整的调试和验证方法见 `references/testing-and-debugging.md`。

## 铁律（踩过的坑）

1. **改 UI 后必须渲染预览图看一眼**（`--render-preview`）。离屏渲染器画不出 `ScrollView`、`Menu`、`.link` 按钮，预览时有替代：`IslandPreview.active` / `MaybeScroll`。真机交互（悬停、长按、菜单）没法自动截图，要请用户确认。
2. **刘海里的尺寸是确定性的**：`IslandLayout` 的行高要和 `HostCard` 的实际绘制一致，否则展开动画会跳。
3. **用于匹配服务器输出的字符串不能翻译**（如 `"未找到"`、`"not found"`、`squeue` 前缀判断）。界面文案一律 `L(zh, en)`。
4. **用 Python 改 Swift 源码时，小心 `\0`、`\n` 被转义成真字符**，出过 NUL 字节事故。优先用 Edit 工具，或者用 raw string。
5. **远端命令一律经过 `SSHRunner.run`**：它会自动在脚本前加上 PATH 补全（`pathPrelude`）；"连接后先执行"（`commands.preamble`）由各脚本自己加。
6. **会写到服务器上、或改变服务器状态的操作，先征得用户同意**。测试用的作业要短、只占 CPU、跑完自己清理。不能在用户的服务器上执行取消 / kill。
7. **不要擅自 git commit / push**，等维护者确认。
8. **仓库是公开的：代码、文档、截图、视频、官网里都不能出现真实的用户名、主机别名、路径、分区名**，演示数据一律用 `DemoData.swift` 里的虚构信息（例外：README 等处维护者主动公开的联系邮箱）（见 `references/website.md`）。维护者自己的环境信息只写在 `references/private/`（被 git 忽略）。
9. **用户的真实配置在 `~/Library/Application Support/ServerIsland/config.json`**。改它之前先退出 App，否则会被 App 覆盖。

## 文档索引（`references/`）

| 文件 | 内容 |
|---|---|
| `architecture.md` | 模块划分、数据流、轮询循环、事件识别、岛的窗口机制 |
| `remote-protocol.md` | 远端脚本格式、各段输出、PATH 补全、Slurm 作业映射、计算软件识别、怎样新增一种软件 |
| `ui-and-i18n.md` | 刘海尺寸与动画、设置页结构、中英文规则、Tako 精灵、图标 / 声音生成 |
| `testing-and-debugging.md` | 自检、诊断命令、日志、预览渲染、真实服务器测试守则 |
| `build-and-release.md` | 打包 .app / DMG、通用二进制、以后的签名公证（方案 B） |
| `website.md` | 官网结构、部署到 GitHub Pages、截图和视频的隐私守则 |
| `promo-video.md` | 宣传视频的技术栈、时间轴、场景、配乐、渲染流程、修改方法、踩坑记录 |
| `status-and-backlog.md` | 当前进度、未验证事项、待办和想法 |

**本机私有文档**（`references/private/`，不进仓库；维护者的机器上才有）：`user-preferences.md`（维护者的偏好和已做的决定，**改需求前先看**）、`environment.md`（维护者的机器和服务器环境）。
