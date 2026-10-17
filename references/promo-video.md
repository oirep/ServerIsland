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
