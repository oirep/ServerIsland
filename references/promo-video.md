# 宣传视频（`promo/`）

成品：`promo/out/ServerIsland-v0.1.mp4`（横屏 1920×1080）、`promo/out/ServerIsland-v0.1-vertical.mp4`（竖屏 1080×1920，手机用）和 `promo/out/ServerIsland-v0.1-en.mp4`（英文横屏）。参数：60fps、50 秒（100 拍 @ 120 BPM）、H.264 CRF 15，AAC 256k / 48kHz，响度约 -12.6 LUFS。成品不进 git；官网用的网页版在 `site/assets/promo.mp4`。
`references/claudevedio.mp4` 是用户放进来的参考视频。

## 技术栈

| 环节 | 做法 |
|---|---|
| 画面 | `index.html` 里一张 1920×1080 的 Canvas 2D。整段画面是时间的纯函数 `renderFrame(t)`，没有任何实时状态，所以每一帧都能确定地重现 |
| 时间轴 | `timeline.js` 里的 `window.TIMELINE`：BPM、各场景的起止拍、音效卡点（cues）。`music.py` 用正则从 `TIMELINE_JSON_BEGIN/END` 之间解析同一份 JSON |
| 配乐 | `music.py`：numpy + scipy 合成，44.1kHz 立体声 WAV。没有任何外部素材 |
| 截帧 | `render.mjs`：用 puppeteer-core@23 启动**系统自带的** Chrome（`/Applications/Google Chrome.app`）无头模式，逐帧执行 `renderFrame(t)` 再截 PNG，经管道送进 FFmpeg |
| 合成 | FFmpeg：`libx264 -preset slow -crf 15 -pix_fmt yuv420p`，BT.709，音频 `loudnorm=I=-14`，`+faststart` |
| 预览 | 浏览器打开 `promo/index.html?play`：带音乐实时播放，点击播放 / 暂停，←→ 跳 2 秒 |

依赖：`cd promo && npm install`，只装 puppeteer-core。

## 命令

```bash
python3 promo/music.py                       # → promo/out/music.wav（约 2 秒）
node promo/render.mjs                        # 完整视频（约 7 分钟）
node promo/render.mjs --vertical             # 竖屏版（同样约 7 分钟），--stills / --from 也能和它一起用
node promo/render.mjs --en                   # 英文版（可以和 --vertical 组合）
node promo/render.mjs --stills 3,12.5,29     # 只导出这些秒数的静帧
node promo/render.mjs --from 10 --to 16      # 只渲染一段 → out/part-10-16.mp4
```
检查：
- 冻结检测：`ffmpeg -i out/ServerIsland-v0.1.mp4 -vf freezedetect=n=0.0005:d=0.35 -map 0:v -f null -`；
- 响度：`-af ebur128`；
- 在 cue 时刻抽帧，拼成对照图（见 testing-and-debugging.md）。

## 场景（拍 → 秒 = 拍 × 0.5）

| 场景 | 拍 | 内容 | 关键 cue |
|---|---|---|---|
| intro | 0–8 | 夜空、像素海浪；Tako 落地（冲击波、粒子）；像素字 ServerIsland 组装；标语"把服务器装进刘海里"；Tako 跳出画面 | 2 whoosh、3 boing、4 shimmer、7.5 whoosh、8 impact |
| notch | 8–20 | 闪白切到 MacBook；Tako 跳上菜单栏、钻进刘海；岛展开出两翼；下方气泡依次展示 4 种心情 | 9 boing、10.5 bloop、11 pop |
| expand | 20–32 | 光标点刘海，面板弹开：4090 工作站（nep、lmp）、HPC 集群（VASP MD、数组、两个排队），卡片标题有运行 / 排队数，底部是"2 台空闲"一行 | 20.75 click、21 whoosh |
| slurm | 32–44 | 数组作业的分段进度推进；排队原因气泡；滑入分区空闲页；Tako 在页上跳两下；镜头慢推 | 32 impact、36 pop、38 whoosh、40/42 boing |
| nep | 44–56 | 文件夹窗口里依次弹出 nep.in / train.xyz / loss.out / nep.txt，Tako 逐个跳上去；高亮出"nep.in + loss.out → NEP 训练"，再依次弹出 VASP / LAMMPS / 自定义规则三个识别标签；镜头移到岛的详情页：代数增长、loss 曲线 | 44–47 pop（音阶上行）、48 shimmer |
| alerts | 56–68 | 收起；"NEP 训练完成"弹窗配叮咚，菜单栏上的 Tako 开心地蹦；"LAMMPS MD 提前结束"配咚咚，Tako 变红；"已静音 HPC 集群"小提示 | 58 ding、62 dong、65 click |
| montage | 68–80 | 九张功能卡每拍弹出一张（VASP / LAMMPS、自定义规则、曲线、空闲合并、暂停 / 静音、动态口令、长按确认、24 小时、中英文），Tako 逐张跳；竖屏是单列 | 68 impact、69–77 pop（音阶上行） |
| outro | 80–100 | Tako 在桌面上大跳 4 次后钻回刘海；画面变暗；logo、像素字、"v0.1.0 · 免费开源"、特性行和 GitHub 地址；最后的 hit；淡出到黑 | 80 impact、81/83/85 boing、88 bloop、90 shimmer、96 impact |

字幕在 `CAPTIONS`（第 12、22、33、45、57 拍开始，编号 01–05）：左下角、逐字弹出，底部有渐暗衬底。

## 画面实现要点

- **Mac 世界坐标** = 14 寸 MBP 的屏幕点：1512×982，刘海 185×32，菜单栏高 32。岛的尺寸和 App 一致（`SPEC`：hidden / collapsed / toast / panel / detail），状态之间用 `spring()` 过渡。
- **摄像机**：`camKeys(B, [[拍, {x, y, z}], ...])`。相邻关键帧之间用 easeInOutCubic，**缩放在对数空间插值**。
- `hop(B, b0, b1, p0, p1, 高度)`：抛物线跳跃。起跳前蓄力，空中拉长，落地后压扁再回弹。
- Tako 用的是 App 同一张网格（`takoGrid`）；`drawTako(c, x, 脚底 y, 身高, 心情, tick, {squash, lift, ground, rot})`。
- 像素字用 5×7 字体（`PFONT`），`drawWord(…, k)`：k 从 0 到 1，像素从随机位置飞到目标位置。
- 粒子 `burst`、闪光 `flash` 都是确定性的，随机数来自 `rnd(i)` 种子。
- 壁纸预先渲染成 2.4 倍的离屏画布（`buildWallpaper`）。
- 场景切换：
  - 有 impact 的位置直接硬切，加闪白；
  - `XFADE` 里列出的场景（nep 0.5 拍、alerts 0.4 拍）做交叉淡化：**新场景先画到离屏画布，再整体按透明度叠上来**。

## 配乐结构（`music.py`）

- C 大调，I–V–vi–IV。每小节的和弦序列见 `PROG`（共 25 小节）；`section(bar)` 把小节分成 intro / A / B / break / drop / outro / end。
- 乐器：
  - pad：失谐锯齿波 + 低通；
  - 琶音：25% 占空比的脉冲波，16 分音符；
  - 贝斯：方波 + 正弦 sub；
  - 旋律：方波 + 正弦，带颤音；`MEL` 按和弦给出 8 分音符的旋律；outro 最后一小节是上行的 `RUN_G`；drop 段加三度和声。
- 鼓：kick、snare、clap、闭镲 / 开镲。所有 kick 的位置用来生成 sidechain 包络，压 pad、贝斯和琶音（旋律只轻压），做出泵感。
- 琶音和旋律加了 3/8 拍的乒乓延迟。
- 音效（`fx_*`）按 `TL.cues` 叠加。ding / dong **直接读取 App 的 `Resources/Sounds/success.wav` 和 `failure.wav`**。
- 两个 riser：第 5–8 拍和第 64–68 拍。
- 母带：28Hz 高通 → tanh 软削波 → 峰值归一到 0.9 → 结尾 1.2 秒淡出。
- 各段能量（RMS）：intro -21、A -10.5、B -7.8、break -11.4、drop -7.8、outro -7.8、end -15.6 dBFS。

## 修改指南

- **改文案**：`CAPTIONS` 和 `CHIPS`；岛里的假数据在 `panelCards`、`sceneNep` 的 fields、`toastOf`。
- **改节奏**：先改 `timeline.js` 的 cues，然后重跑 `music.py`。画面里对应的拍子写在各个场景函数里（关键帧和 hop 的拍数），两边要一起改。
- **卡点原则**：画面要**比声音早约 0.15–0.2 拍**到位。比如岛在第 57.8 拍开始展开，第 58 拍叮咚响起时文字已经能看清。
- **加场景**：
  1. 在 `TL.scenes` 里加一项；
  2. 在 `SCENES` 里注册场景函数；
  3. 视情况加 `XFADE`；
  4. 在 `music.py` 的 `PROG` / `section` 里同步对应的小节。
- **竖屏版本**：改 `TIMELINE.width/height`，各场景的布局要重新排，尚未做。

## 踩坑记录

1. **场景内部直接给 `globalAlpha` 赋绝对值**，会破坏外层的淡入淡出。做法是：场景内一律用 `*=`，或者 save/restore；交叉淡化用离屏画布。
2. 静帧检查看不出"画面静止"的问题。要跑 `freezedetect`：分区页曾经静止了 1.8 秒，后来加了镜头慢推和 Tako 跳跃。
3. 岛的展开发生在 cue 那一刻时，弹出的文字会比声音晚出现。所以关键帧要提前。
4. ffmpeg 拼图时，单张输出要加 `-frames:v 1`；用 `color` 源时要加 `d=1`。

## 竖屏版（`?vertical`，2026-10-17）

- 同一份 `index.html`，地址带 `?vertical` 时 `W × H = 1080 × 1920`；时间轴、音乐、卡点完全一样。
- **Mac 场景的镜头自动换算**（`vertCam`）：横屏镜头能看到的世界宽度 `V = 1920 / z`，按分段线性表 `VKNOTS` 换算成竖屏要看到的宽度——特写（刘海两翼、提示）保持差不多的放大，看面板时让 668 宽的面板刚好占满，全景时整台电脑放得下；纵向让画面顶部贴着刘海。所以 Mac 场景不用为竖屏单独写镜头。
- 竖屏下 Mac 场景先画夜空（`drawNight`），电脑上下不是一片黑。
- 单独排版的地方：片头（Tako、像素字、标语的纵向位置）、字幕（标题 58px、衬底更高）、功能卡片（单列 880×150）、片尾（logo 更大，特性行拆成多行）、排队原因气泡的位置。
- 改画面时两个版本都要导静帧看一眼：`node promo/render.mjs --stills …` 和 `node promo/render.mjs --vertical --stills …`。

## 英文版（`?en`，2026-10-17）

- 画面上的所有文字都写成 `T("中文", "English")`，地址带 `?en` 时用英文；功能卡片 `CHIPS` 是整段二选一。
- 英文比中文长的地方要留意：菜单栏按实际宽度排、片尾版本胶囊加宽、排队原因气泡按文字宽度自适应。
- 新增画面文字时记得同时写英文；检查方法：`node promo/render.mjs --en --stills …`。

## 使用教程视频（`promo/tutorial/`，2026-10-19）

和宣传片分开的第二支视频：**中文、横屏 1920×1080、30fps、约 3 分 15 秒**，带中文配音（微软神经网络语音，edge-tts）和字幕，逐项演示 v0.3.0 的功能和用法。成品 `promo/out/tutorial/ServerIsland-教程-v0.3.0.mp4`（不进 git）。没有竖屏版和英文版。

### 文件

| 文件 | 作用 |
|---|---|
| `tutorial/script.js` | **旁白脚本**：配音引擎和声音（`engine` / `voice` / `rate`）、章节、每句字幕（`text`）、配音读法（`tts`，比如 Tako 写成“塔可”）、每句至少占多少秒（`min`，给动画留时间）、音效 cues（锚在某一句开始后的若干秒） |
| `tutorial/audio.py` | 逐句调用 edge-tts 合成配音（默认 `zh-CN-XiaoxiaoNeural`，语速 +8%；按文本缓存在 `out/tutorial/tts/`），**按实际时长排出时间轴写进 `timing.js`**；再合成 92 BPM 的轻柔背景乐（配音出现时压低到 40%）、叠加音效（叮咚 / 咚咚用 App 的 `Resources/Sounds`），输出 `out/tutorial/audio.wav` |
| `tutorial/timing.js` | audio.py 生成，不要手改：每句的起止时间、各章范围、音效时刻 |
| `tutorial/kit.js` | 绘图工具。Tako、刘海形状、壁纸、光标、粒子从 `index.html`（宣传片）复制过来，时间单位改成秒；卡片、二级页面、设置窗口（侧栏、分组表单、分段控件、下拉菜单、开关）按 `--render-preview` 的截图重画 |
| `tutorial/index.html` | 各章的场景函数 + 字幕 + 章节标签。动画都写成 `S("a3") + 0.4`（第 a3 句开始后 0.4 秒），所以改了文案或语速、重跑 audio.py 后画面自动跟着对齐 |
| `tutorial/render.mjs` | 逐帧截图送进 FFmpeg（libx264 CRF 16，AAC 192k，响度 -16 LUFS）。puppeteer-core 用 `promo/node_modules` 里那份 |

### 命令

```bash
pip install edge-tts                                    # 第一次（或者装在任意 venv 里，再用 EDGE_TTS=<venv>/bin/edge-tts 指过去）
python3 promo/tutorial/audio.py                         # 配音 + timing.js + out/tutorial/audio.wav（需要联网，首次约 1 分钟，之后有缓存）
node promo/tutorial/render.mjs                          # 完整视频（约 6,000 帧，十几分钟）
node promo/tutorial/render.mjs --stills 13,42,90        # 只导出这些秒数的静帧 → out/tutorial/still-*.png
node promo/tutorial/render.mjs --from 60 --to 80        # 只渲染一段
open "promo/tutorial/index.html?play"                   # 浏览器里带声音预览（点击播放，←→ 跳 3 秒）
```
audio.py 会打印每句的开始时间、语音时长，以及哪些句子比 `min` 长（那一句的动画会被拉长，通常没问题）。

### 章节（时间是当前配音下的实际值）

| 章 | 时间 | 内容 |
|---|---|---|
| 开场 | 0:00–0:19 | **先给看灵动岛本身**：收起的两翼 → "NEP 训练完成"弹窗 + 叮咚 → 光标悬停、面板展开；然后标题卡和 8 个章节 |
| 01 添加服务器 | 0:19–0:50 | 设置窗口 → "添加服务器"；从 ~/.ssh/config 勾选别名；切到"手动填写"逐字输入名称 / 地址 / 用户名 / 端口 / 私钥；认证方式下拉（4 种）、跳板机下拉；添加后"自动检测类型"→ 检测到 Slurm；"登录…"弹出动态口令对话框 → 在线 |
| 02 刘海与卡片 | 0:50–1:14 | 两翼的说明标签；四种心情卡片依次弹出（两翼的 Tako 跟着变）；悬停展开，高亮卡片标题 / CPU 内存 / GPU 格子；空闲服务器合并成一行 |
| 03 Slurm 集群 | 1:14–1:36 | 数组作业分段条推进并标注完成 / 失败 / 运行中；`DependencyNeverSatisfied` 的说明气泡；点网格图标 → 分区空闲资源（含 DCU）；返回 → 点时钟图标 → 历史记录（7 天） |
| 04 PBS 与直连 | 1:36–1:51 | PBS 卡片；直连服务器的进程和 GPU 格子；点眼睛图标 → 监听进程页，选中一个进程 |
| 05 计算软件进度 | 1:51–2:16 | 逐行高亮 VASP MD / 结构优化 / GPUMD / NEP / LAMMPS / 自定义规则；NEP 详情页（loss 曲线、日志末尾滚动）；VASP 结构优化（能量 + 最大力）→ NEB（能垒图 + 能垒收敛）；设置里的自定义规则编辑器，点"测试"出结果 |
| 06 提醒与安全 | 2:16–2:36 | 完成弹窗 + 叮咚、提前结束弹窗 + 咚咚；点铃铛静音、点暂停（卡片出现"自动刷新已暂停"）；详情页按住 1.5 秒 → 二次确认（最后点"不了"） |
| 07 v0.3.0 新功能 | 2:36–2:54 | 卡片上的终端按钮 → 终端窗口里 ssh 登录；设置侧栏拖动排序 + 右键"移到最上面"，旁边的小刘海同步换顺序；一键更新（下载核对 → SHA-256 一致 → 退出重开 → 已是最新）。轮询开销的优化属于内部改进，按维护者的意见不在视频里介绍 |
| 08 Windows / Linux | 2:54–3:05 | Windows 风格桌面：顶部虚拟灵动岛展开；切到桌面小章鱼（徽章、浮动面板）和托盘图标 |
| 结尾 | 3:05–3:15 | logo、像素字、v0.3.0 · 免费开源、GitHub 地址 |

### 修改指南

- **改旁白**：只改 `script.js` 的 `text` / `tts`，重跑 audio.py；如果某句比原来长很多，相应的动画会整体往后挪，不用手动改时间。
- **改动画**：在 `index.html` 对应的 `sceneXxx` 里改，时间一律写成相对某句开始的偏移。光标路线用 `cursorAt(t, [[秒, x, y], ...])`，点击用 `pressAt` + `ripple`，并在 `script.js` 的 cues 里加一个 `click`，声音才对得上。
- **界面要和真实 App 一致**：改之前先 `.build/debug/ServerIsland --render-preview <目录> zh` 看截图（卡片头部按钮顺序、详情页字段、设置页文案都照着它）。演示数据只用 `DemoData.swift` 里的虚构信息。
- **检查**：`--stills` 抽帧看有没有错字、遮挡、对不齐；字幕在底部 970–1034 px，镜头构图时把重要内容放在它上面。
- **配音**：最早用 macOS 自带的 `say -v Tingting`，维护者反馈"一个字一个字地蹦、没有语气"，改成了 edge-tts（微软 Edge "大声朗读"背后的神经网络语音，免费、需要联网，文本会发给微软的服务）。可选声音：`zh-CN-XiaoxiaoNeural`（女，温和，默认）、`YunxiNeural`（男，阳光）、`XiaoyiNeural`（女，活泼）、`YunyangNeural`（男，新闻播报），对比样音在 `out/tutorial/voices/`。换声音只改 `script.js` 的 `voice`，重跑 audio.py 和 render.mjs。没有网络时把 `engine` 改成 `"say"`（用 `sayVoice` / `sayRate`）。
- edge-tts 走的是 Edge 浏览器朗读功能的非公开接口，没有正式的商用授权条款。如果以后要更稳妥的授权或更有感情的配音，可以换成付费的正式服务（Azure 语音、火山引擎 / 豆包语音、阿里云 CosyVoice 等，同一批神经网络声音或更好），或者维护者自己录音：把每句录成 `out/tutorial/tts/` 里的 wav 再接入 `tts()` 即可。
