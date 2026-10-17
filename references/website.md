# 官网（`site/`）

纯静态页面，没有构建步骤、没有外部依赖，直接部署到 GitHub Pages。

## 文件

| 文件 | 内容 |
|---|---|
| `site/index.html` | 整页结构。中英文写在一起：`<span lang="zh">…</span><span lang="en">…</span>`，CSS 按 `html[data-lang]` 隐藏另一种 |
| `site/css/style.css` | 配色、圆角、卡片和 App / 宣传视频一致（`--mint #5BE6B5` 等）；900px、640px 两档窄屏 |
| `site/js/config.js` | **部署前只改这里**：版本号、GitHub 仓库地址 `repo`（GitHub / Issues / 下载按钮都由它生成）、可选的 DMG 直链 |
| `site/js/tako.js` | Tako 像素网格，和 `Pet.swift`、`promo/index.html` 同一张 |
| `site/js/main.js` | 语言切换（记在 localStorage，默认跟浏览器语言）、像素字组装动画、夜空星星、刘海演示状态机（收起 → 提示 → 收起 → 展开，鼠标悬停时一直展开）、滚动出现 |
| `site/assets/shots/{zh,en}/` | App 截图，由 `scripts/site_shots.sh` 生成 |
| `site/assets/promo.mp4`、`promo-poster.jpg` | 宣传视频的网页版（1280 宽、CRF 27，约几 MB） |
| `.github/workflows/pages.yml` | 推送到 main 且 `site/` 有变化时自动部署 |

## 常用操作

```bash
./scripts/site_shots.sh                 # 重新生成中英文截图（演示数据）
python3 -m http.server 8765 --directory site   # 本地预览（或用 .claude/launch.json 里的 "site"）
# 视频改动后：node promo/render.mjs，再压网页版
ffmpeg -i promo/out/ServerIsland-v0.1.mp4 -vf scale=1280:-2 -c:v libx264 -preset slow -crf 27 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart site/assets/promo.mp4
```

## 部署到 GitHub Pages

项目开源，官网和源码在同一个公开仓库里：

1. 在 GitHub 建公开仓库并推送；
2. 仓库 Settings → Pages → Source 选 **GitHub Actions**；之后每次推送 `site/` 的改动都会自动发布到 `https://<用户名>.github.io/<仓库>/`；
3. `site/js/config.js` 里填 `repo`；
4. 发版：`./scripts/make_dmg.sh` 生成 DMG，在 GitHub 上建 Release 并上传。下载按钮默认打开 Releases 最新版页面。

## 隐私守则（截图、视频、页面文字）

- 演示数据在 `Monitor/DemoData.swift`：用户名 `demo`，路径 `/home/demo/projects/...`，主机名"HPC 集群""4090 工作站"，作业号 88xxxxx，PID 41xxx。
- 宣传视频 `promo/index.html` 用同一套虚构信息。
- **不要写真实的用户名、主机别名、路径、分区名、作业号**。提交前可以用 `git grep` 检查一下自己的用户名和主机名。
