# 界面、中英文与资源

> 总的设计风格和开发规范（两个版本共用）见 `design-guide.md`；本文件是 Mac 版界面的实现细节。Windows / Linux 版的界面实现见 `cross-platform.md`。

## 刘海（`Notch/`）

- **形状**：`NotchShape`（在 `NotchGeometry.swift` 里）。顶部是向外弯的"耳朵"（ear），底部是普通圆角，两种半径都可以做动画。
- **状态**（`IslandMode`）：
  - hidden：完全藏在硬件刘海里；
  - collapsed：两侧小翅膀，左边是 Tako 和运行中的数量，右边是进度环；
  - toast：事件弹窗；
  - expanded：展开面板。
- **尺寸**（`IslandLayout`）：
  - 宽度：collapsed = 刘海宽 + 2×62 + 2×耳朵宽；expanded = max(刘海宽 + 400, 640) + 28；toast ≥ 420 + 20；
  - **卡片高度用固定行高计算**（`cardHeader 20`、`metricsRow 16`、`jobRow 34`、`jobGap 6`、`sectionGap 10`、`cardPad 12` 等），每张卡最多显示 5 个任务，多出的显示"还有 N 个"入口，可以进入全部任务页；
  - 二级页面固定高 `pageHeight 420`；内容超过 540 时改为可滚动。
  - **改了 `HostCard` 的行布局，必须同步改 `IslandLayout.cardHeight` 和 `parts`。**
- **动画**：尺寸变化用弹簧（`response 0.44`、`damping 0.78`）。内容在形状展开时稍微延后淡入。
- **二级页面**（`IslandPage`）：
  - `.list`：卡片列表；
  - `.job`：任务详情 / 日志 / 取消；数组作业显示 `ArrayOverview`；
  - `.history`：最近 24 小时；
  - `.picker`：挑选要监听的进程；
  - `.jobs`：全部任务，带搜索和筛选；
  - `.partitions`：分区空闲资源。
- **卡片头部按钮**（从左到右）：👁（只有直连服务器）或 ▦（只有 Slurm）、历史、间隔菜单（显示 `1m` / `暂停`…）、⏸/▶、铃铛。
- **头部**：Tako、标题、⚡运行 / ⏳排队计数（放在左边，避免右侧挤）；右边是全局轮询菜单（⏱1m / 手动）、📌、↻、⚙。
- **危险操作**：先长按 1.5 秒（`HoldToConfirmButton`），再点一次确认，然后由引擎在服务器上核对后才执行。
- 任务行：右键菜单可以复制作业号、名称、完整命令；详情页里的工作目录、日志路径、`tail -f` 命令都有复制按钮。

## 小章鱼 Tako（`Shared/Pet.swift`）

- 16×14 的像素网格（头部 10 行 + 腿 4 行），配色用字母表示：`B` 身体、`S` 暗部、`H` 高光、`E` 眼睛、`W` 眼睛反光、`C` 腮红、`M` 嘴、`R` 汗滴。
- 6 种心情：
  - idle：偶尔眨眼；
  - working：腿交替摆动、身体上下弹；
  - waiting：半闭眼，冒出 z；
  - happy：^ ^ 笑眼，腿收拢蹦跳；
  - sad：x x 晕眼，身体变红，冒汗；
  - worried：冒汗。
- 帧率 2–3 fps（TimelineView），几乎不占资源。`MonitorEngine.petMood` 根据整体状态决定心情。
- **同一张网格还用在三个地方**，改造型时要一起改：
  - `scripts/gen_branding.py`（logo 和菜单栏图标）；
  - `promo/index.html`（宣传视频）；
  - 还有 `Components.swift` 里的 `LogoGlyph`（旧的，已不在刘海头部使用）。

## 设置窗口（`Settings/`）

- `NavigationSplitView`：左侧栏是"通用"和服务器列表，每行有带状态点的图标；右侧是详情。
- 详情页**按服务器 ID 绑定**，而不是数组下标。原因是下标绑定出过 bug：页面切换后，异步的自动检测结果被写到了别的服务器上。
- 标题栏：`.toolbarBackground(.visible, for: .windowToolbar)`，避免内容滚动时和标题重叠。
- 每一项都用 `HelpLabel("标题", help: "说明")`：标题后面带一个 ⓘ，悬停显示说明。**不要在标题里加括号写说明。**
- 单台服务器页的分组顺序：概览 → 连接 → 环境 → 轮询 → 显示内容 → 计算软件 → 提醒 → 监听的进程 → 危险操作 → 高级（远程命令）→ 诊断。
- "连接"分组：类型 → 自动检测 → 连接方式（`~/.ssh/config 别名` / `手动填写`，手动时显示地址、用户名、端口、私钥文件）→ 跳板机 → 认证方式 → 记住密码（只有"密码""密钥 + 密码"有）→ 保持连接和登录按钮（需要登录的认证方式才有）。这几组控件在 `ConnectionFields.swift` / `ConnectionFields.cs` 里，服务器页和"添加服务器"共用。
- "显示内容"分组里有"只看这些目录"（多行文本框，每行一个目录）。
- 类型有三种：Slurm 集群 / PBS 集群 / 直连服务器。PBS 的卡片没有分区按钮；取消按钮的文案用 `HostKind.cancelCommand`（scancel / qdel / kill -TERM）。
- 详情页的曲线可以有多张（VASP 结构优化：能量 | 最大力），并排显示、总高度不变；并排时 `CurveChart(compact: true)` 省掉右上角的步数。`threshold` 画成琥珀色虚线并出现在图例里。
- 通用页"文件与诊断"：日志保留（1 / 3 / 7 / 14 / 30 天 / 永久）和"清除日志…"（先确认，显示当前大小）。
- "添加服务器"有两个页签：从 `~/.ssh/config` 选择 / 手动填写；`~/.ssh/config` 里没有条目时直接打开手动填写。
- 窗口打开时临时把激活策略切到 `.regular`，关闭后切回 `.accessory`。

## 中英文（`Shared/Localization.swift`）

- `L("中文", "English")`，根据 `Lang.isEnglish` 选择。`Lang.setting` 由 `ConfigStore` 同步，取值为 system / zh / en。
- "跟随系统"看的是 `Locale.preferredLanguages.first`。**用户这台 Mac 的首选语言是 `en-CN`**，所以用户的配置显式设成了 `zh`。
- 设置窗口用 `.id(store.settings.language)`，切换语言后整页重绘。刘海视图本来就订阅了 store，会自动刷新。
- 规则：
  - 所有界面文案都用 `L()`；
  - 用来匹配服务器输出的字符串不翻译；
  - 详情字段的 key（如 `L("工作目录", "Directory")`）会被用来查找，所以 `MonitorEngine+Actions` 和 `IslandPages` 两边要用同一对写法；
  - `SelfTest.run()` 开头固定 `Lang.setting = .zh`，因为断言比较的是中文。
- 嵌套引号的字面量（插值里还有字符串）没法用脚本批量替换，要手工拆成 `L(...) + ...`。

## 生成的资源

| 资源 | 生成方式 |
|---|---|
| `Branding/logo.svg`、`menubar.svg` | `python3 scripts/gen_branding.py`（Tako 网格 + 5×7 像素字体 "ServerIsland"） |
| `Branding/logo-1024.png` | `swift scripts/render_svg.swift Branding/logo.svg Branding/logo-1024.png 1024` |
| 菜单栏 PNG | 同上，尺寸 18 和 36（`menubar.png`、`menubar@2x.png`） |
| `Resources/AppIcon.icns` | 用 sips 生成 16/32/128/256/512 及其 @2x 的 iconset，再执行 `iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns` |
| `Resources/Sounds/*.wav` | `python3 scripts/gen_sounds.py`：success 是上行的 E6→B6"叮咚"，failure 是下行的 A4→E4，warning 是 D5 敲两下 |

logo 现在的构图：Tako（px=26，y0=226）下方是像素字 ServerIsland（每格 10px，ty0=650，薄荷绿→蓝渐变），背景是夜空、星点和像素海浪。**用户要求过去掉 Tako 上方的进度条和岛，并加上文字。**
