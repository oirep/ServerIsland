# ServerIsland v0.1 发布视频

全部用代码生成：Canvas 2D 动画 + 代码合成的配乐。由无头 Chrome 逐帧渲染，再用 FFmpeg 合成视频。

| 文件 | 作用 |
|---|---|
| `timeline.js` | **共享时间轴**：BPM、各场景的起止拍、所有音效卡点。画面和音乐都读这一份，所以天然对齐 |
| `index.html` | 动画本体。整段画面是时间的纯函数 `renderFrame(t)`；在浏览器里打开 `index.html?play` 可以带音乐实时预览（点击播放，←→ 跳 2 秒） |
| `music.py` | 配乐：120 BPM、C 大调，chiptune 风格，叠加 App 自己的「叮咚 / 咚咚」提示音 |
| `render.mjs` | 逐帧截图，经管道送进 FFmpeg（H.264 1080p60，音频响度标准化到 -14 LUFS） |

## 重新生成

```bash
cd promo && npm install            # 只需第一次（puppeteer-core，使用系统里的 Chrome）
python3 music.py                   # → out/music.wav
node render.mjs                    # → out/ServerIsland-v0.1.mp4（约 3000 帧）
node render.mjs --stills 3,12.5    # 只导出这些秒数的静帧，用来检查画面
node render.mjs --from 10 --to 16  # 只渲染其中一段
```

## 修改

- **文案**：`index.html` 里的 `CAPTIONS`（字幕）和 `CHIPS`（功能卡）。
- **节奏或卡点**：改 `timeline.js` 的 `cues`。改完需要重新运行 `music.py`，再渲染视频。
- **镜头**：每个场景函数开头的 `camKeys([...])`，格式为 `[拍, {x, y, z}]` 的关键帧。
